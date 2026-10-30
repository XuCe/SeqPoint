import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('重启后删除仍隐藏，恢复再重启后事项和搜索恢复且数据完整', () async {
    final dir = Directory.systemTemp.createTempSync('seqpoint-trash-');
    var db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    final clock = FakeClock(DateTime(2026, 10, 23, 12));
    NoteService service() => NoteService(db: db, clock: clock,
      notes: NoteRepository(db, clock: clock), items: ItemRepository(db, clock: clock),
      activities: ActivityRepository(db, clock: clock));
    addTearDown(() { db.close(); dir.deleteSync(recursive: true); });
    final note = service().capture('重启恢复待办\n重启恢复完成\n重启恢复删除');
    final todo = service().lineToItem(note.id, 0);
    final done = service().toggleItem(service().lineToItem(note.id, 1).id);
    final removed = service().lineToItem(note.id, 2);
    ItemRepository(db).update(todo.copyWith(dueAt: clock.now(), priority: Priority.p1));
    ItemRepository(db).update(removed.copyWith(deletedAt: clock.now()));
    final tag = TagRepository(db).upsert(name: '重启保留标签', kind: TagKind.project);
    ItemRepository(db).setTags(todo.id, [tag.id]);
    SearchService(db).rebuild();
    final rows = db.raw.select('SELECT * FROM items ORDER BY id')
      .map((r) => r.values.toList()).toList();
    service().trash(note.id);
    db.close(); db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    expect(ItemRepository(db).openAll(), isEmpty);
    expect(ItemRepository(db).dueOn(clock.now()), isEmpty);
    expect(ItemRepository(db).completedOn(clock.now()), isEmpty);
    expect(await SearchService(db).query('重启恢复'), isEmpty);
    service().restore(note.id);
    db.close(); db = SeqDatabase.open('${dir.path}/test.db')..migrate();
    expect(ItemRepository(db).openAll().single.id, todo.id);
    expect(ItemRepository(db).dueOn(clock.now()).single.id, todo.id);
    expect(ItemRepository(db).completedOn(clock.now()).single.id, done.id);
    expect((await SearchService(db).query('重启恢复')).map((h) => h.objectId).toSet(),
      {note.id, todo.id, done.id});
    expect(ItemRepository(db).tagIdsOf(todo.id), [tag.id]);
    expect(db.raw.select('SELECT * FROM items ORDER BY id')
      .map((r) => r.values.toList()).toList(), rows);
  });
}
