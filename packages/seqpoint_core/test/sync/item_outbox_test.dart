import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late ItemRepository items;
  late NoteService service;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    final clock = FakeClock(DateTime.utc(2026, 10, 25));
    items = ItemRepository(db, clock: clock);
    service = NoteService(db: db, notes: NoteRepository(db, clock: clock),
        items: items, activities: ActivityRepository(db, clock: clock), clock: clock);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('真实行转事项/勾选/合并编辑只捕获实际变化，便签原文不变', () {
    final note = service.capture('原始待办');
    db.raw.execute('DELETE FROM sync_operations');
    final item = service.lineToItem(note.id, 0);
    final created = db.raw.select('SELECT * FROM sync_operations');
    expect(created, isNotEmpty);
    expect(created.every((r) => r['object_type'] == 'item'), isTrue);
    expect(created.map((r) => r['field']), isNot(contains('source_ref_json')));
    db.raw.execute('DELETE FROM sync_operations');
    service.toggleItem(item.id);
    expect(db.raw.select('SELECT field FROM sync_operations').map((r) => r['field']).toSet(),
        {'status', 'completed_at'});
    db.raw.execute('DELETE FROM sync_operations');
    expect(items.saveEdits(item, title: '改名', priority: Priority.p0,
        dueAt: DateTime.utc(2026, 10, 26)), isTrue);
    expect(items.byId(item.id)!.status, ItemStatus.done);
    expect(db.raw.select('SELECT field FROM sync_operations').map((r) => r['field']).toSet(),
        {'title', 'priority', 'due_at'});
    expect(NoteRepository(db).byId(note.id)!.rawContent, '原始待办');
  });
  test('事项操作写失败时仓储直接更新也回滚', () {
    final item = service.lineToItem(service.capture('旧标题').id, 0);
    db.raw.execute('DELETE FROM sync_operations');
    db.raw.execute('CREATE TEMP TRIGGER reject_item_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => items.update(item.copyWith(title: '不能半写')), throwsA(isA<SqliteException>()));
    expect(items.byId(item.id)!.title, '旧标题');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  test('勾选后活动失败，事项/完成时间/操作/HLC共同回滚', () {
    final item = service.lineToItem(service.capture('待办').id, 0);
    db.raw.execute('DELETE FROM sync_operations');
    final before = db.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'];
    db.raw.execute('CREATE TEMP TRIGGER reject_toggle_activity BEFORE INSERT ON activities '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => service.toggleItem(item.id), throwsA(isA<SqliteException>()));
    expect(items.byId(item.id)!.status, ItemStatus.todo);
    expect(items.byId(item.id)!.completedAt, isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'], before);
  });
  test('新增事项操作失败不留下事项或新增活动', () {
    final note = service.capture('尚未转事项');
    db.raw.execute('DELETE FROM sync_operations');
    db.raw.execute('CREATE TEMP TRIGGER reject_insert_item_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => service.lineToItem(note.id, 0), throwsA(isA<SqliteException>()));
    expect(db.raw.select('SELECT * FROM items'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM activities'), hasLength(1));
    expect(NoteRepository(db).byId(note.id)!.rawContent, '尚未转事项');
  });
  test('合并编辑冲突拒绝时不产生额外操作', () {
    final original = service.lineToItem(service.capture('旧标题').id, 0);
    items.update(original.copyWith(title: '其他窗口已改'));
    db.raw.execute('DELETE FROM sync_operations');
    expect(items.saveEdits(original, title: '我的标题', priority: original.priority,
        dueAt: original.dueAt), isFalse);
    expect(items.byId(original.id)!.title, '其他窗口已改');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
}
