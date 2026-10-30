import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService service;
  late ItemRepository items;
  late String noteId;
  final now = DateTime(2026, 10, 23, 12);
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    final clock = FakeClock(now);
    items = ItemRepository(db, clock: clock);
    service = NoteService(db: db, notes: NoteRepository(db, clock: clock),
      items: items, activities: ActivityRepository(db, clock: clock), clock: clock);
    noteId = service.capture('待办\n已完成\n单独删除').id;
    final todo = service.lineToItem(noteId, 0);
    items.update(todo.copyWith(dueAt: now.subtract(const Duration(hours: 1)),
      priority: Priority.p1));
    service.toggleItem(service.lineToItem(noteId, 1).id);
    final removed = service.lineToItem(noteId, 2);
    items.update(removed.copyWith(deletedAt: now));
  });
  tearDown(() => db.close());

  test('删除不影响独立事项和其他便签，恢复保留标签且不复活单独删除事项', () {
    final standalone = items.insert(Item(id: '', title: '独立事项',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      dueAt: now.subtract(const Duration(hours: 1)), createdAt: now, updatedAt: now));
    final other = service.lineToItem(service.capture('其他便签事项').id, 0);
    items.update(other.copyWith(dueAt: standalone.dueAt));
    final todo = items.byNote(noteId).firstWhere((i) => i.isOpen);
    final tag = TagRepository(db).upsert(name: '保留项目', kind: TagKind.project);
    items.setTags(todo.id, [tag.id]);
    items.setTags(standalone.id, [tag.id]);
    expect(items.byTag(tag.id).map((i) => i.id).toSet(), {standalone.id, todo.id});
    expect(TagRepository(db).usageCount(tag.id), 2);
    final visible = {standalone.id, other.id};
    service.trash(noteId);
    expect(items.byTag(tag.id).map((i) => i.id), [standalone.id]);
    expect(TagRepository(db).usageCount(tag.id), 1);
    expect(items.openAll().map((i) => i.id).toSet(), visible);
    expect(items.dueOn(now).map((i) => i.id).toSet(), visible);
    expect(items.overdue(now).map((i) => i.id).toSet(), visible);
    expect(items.openAll(limit: 1).single.id, isIn(visible));
    service.restore(noteId);
    expect(items.byTag(tag.id).map((i) => i.id).toSet(), {standalone.id, todo.id});
    expect(TagRepository(db).usageCount(tag.id), 2);
    expect(items.openAll().map((i) => i.id).toSet(), {...visible, todo.id});
    expect(items.tagIdsOf(todo.id), [tag.id]);
    expect(items.byId(todo.id)!.priority, Priority.p1);
    expect(items.byNote(noteId).where((i) => i.isDone), hasLength(1));
    expect(db.raw.select('SELECT deleted_at FROM items WHERE title = ?',
      ['单独删除']).single['deleted_at'], isNotNull);
  });

  for (final view in ['今日', '逾期', '今日已完成', '全部事项']) {
    test('$view删除便签后隐藏事项，恢复后显示且事项数据不变', () {
      List<Item> query() => switch (view) {
        '今日' => items.dueOn(now),
        '逾期' => items.overdue(now),
        '今日已完成' => items.completedOn(now),
        _ => items.openAll(),
      };
      final before = query().map((i) => i.id).toList();
      expect(before, isNotEmpty);
      final rows = db.raw.select('SELECT * FROM items ORDER BY id')
        .map((r) => r.values.toList()).toList();
      service.trash(noteId);
      expect(query(), isEmpty);
      service.restore(noteId);
      expect(query().map((i) => i.id).toList(), before);
      expect(db.raw.select('SELECT * FROM items ORDER BY id')
        .map((r) => r.values.toList()).toList(), rows);
    });
  }
}
