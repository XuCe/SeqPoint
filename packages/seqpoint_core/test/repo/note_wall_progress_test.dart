import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('墙上的卡片保留顺序，只统计未删除事项，取消不算完成', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final notes = NoteRepository(db);
    final items = ItemRepository(db);
    final service = NoteService(db: db, notes: notes, items: items,
        activities: ActivityRepository(db));
    final note = service.capture('完成\n取消\n删除');
    final empty = service.capture('没有事项');
    notes.update(empty.copyWith(pinned: true));
    final children = [for (var i = 0; i < 3; i++) service.lineToItem(note.id, i)];
    service.toggleItem(children[0].id);
    items.update(children[1].copyWith(status: ItemStatus.canceled));
    items.update(children[2].copyWith(deletedAt: DateTime.now()));
    service.trash(service.capture('回收站').id);
    service.close(service.capture('归档').id);

    final wall = notes.activeWithProgress();
    expect([for (var i = 0; i < wall.length; i++)
      (wall[i].note.id, wall[i].done, wall[i].total)],
        [(empty.id, 0, 0), (note.id, 1, 2)]);
  });
  test('滚动到后续卡片时加载进度，刷新读取最新状态', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final notes = NoteRepository(db);
    final items = ItemRepository(db);
    final service = NoteService(db: db, notes: notes, items: items,
        activities: ActivityRepository(db));
    for (var i = 0; i < 40; i++) {
      service.capture('便签 $i');
    }
    final wall = notes.activeWithProgress();
    expect(wall[0].total, 0);
    final last = notes.active().last;
    service.lineToItem(last.id, 0);
    expect(wall[wall.length - 1].total, 1);
    final first = wall[0].note;
    service.lineToItem(first.id, 0);
    expect(wall[0].total, 0);
    final refreshed = notes.activeWithProgress();
    expect(refreshed[0].note.id, first.id);
    expect(refreshed[0].total, 1);
  });
}
