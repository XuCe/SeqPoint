import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('提醒查询不限500条且忽略完成、删除和父便签回收站', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final repo = ItemRepository(db);
    final now = DateTime.utc(2026, 10, 26);
    Item make(String id) => Item(
      id: id, title: id, status: ItemStatus.todo, priority: Priority.p4,
      source: ItemSource.manual, createdAt: now, updatedAt: now, dueAt: now,
    );
    for (var i = 0; i < 501; i++) {
      repo.insert(make('item-$i'));
    }
    repo.insert(make('done').copyWith(status: ItemStatus.done));
    repo.insert(make('deleted').copyWith(deletedAt: now));
    db.raw.execute(
      'INSERT INTO notes (id,kind,raw_content,status,created_at,updated_at,'
      'deleted_at) VALUES (?,?,?,?,?,?,?)',
      ['trash', 'text', '', 'active', now.toIso8601String(),
        now.toIso8601String(), now.toIso8601String()],
    );
    repo.insert(make('hidden').copyWith(noteId: 'trash'));
    expect(repo.remindable().length, 501);
    expect(repo.remindable().map((i) => i.id),
      isNot(anyOf(contains('done'), contains('deleted'), contains('hidden'))));
  });
}
