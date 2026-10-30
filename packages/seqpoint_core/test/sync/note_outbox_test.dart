import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteRepository notes;
  late NoteService service;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    final clock = FakeClock(DateTime.utc(2026, 10, 25));
    notes = NoteRepository(db, clock: clock);
    service = NoteService(db: db, notes: notes, items: ItemRepository(db, clock: clock),
        activities: ActivityRepository(db, clock: clock), clock: clock);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('真实capture/edit入口保留原文，事务只记录业务字段实际变化', () {
    final note = service.capture('第一版');
    final ops = db.raw.select('SELECT * FROM sync_operations');
    expect(ops, isNotEmpty);
    expect(ops.every((r) => r['object_type'] == 'note' && r['object_id'] == note.id), isTrue);
    expect(ops.map((r) => r['field']), contains('raw_content'));
    db.raw.execute('DELETE FROM sync_operations');
    service.editContent(note.id, '第二版');
    final change = db.raw.select('SELECT * FROM sync_operations').single;
    expect(change['field'], 'raw_content');
    expect(jsonDecode(change['value_json'] as String), '第二版');
    expect(notes.byId(note.id)!.rawContent, '第二版');
    expect(db.raw.select('SELECT * FROM activities'), hasLength(2));
  });
  test('操作写失败回滚真实业务及活动，无半条操作', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_note_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => service.capture('不会半写'), throwsA(isA<SqliteException>()));
    expect(notes.active(), isEmpty);
    expect(db.raw.select('SELECT * FROM activities'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  test('外层活动失败也撤销已捕获的便签和HLC', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_activity BEFORE INSERT ON activities '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => service.capture('活动失败'), throwsA(isA<SqliteException>()));
    expect(notes.active(), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
  test('无服务外层事务时更新失败仍保留原文', () {
    final note = service.capture('原文');
    db.raw.execute('DELETE FROM sync_operations');
    db.raw.execute('CREATE TEMP TRIGGER reject_update_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => notes.update(note.copyWith(rawContent: '不能留下')),
        throwsA(isA<SqliteException>()));
    expect(notes.byId(note.id)!.rawContent, '原文');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  test('真实回收站/恢复入口产生明确意图，普通编辑不恢复', () {
    final note = service.capture('保留正文');
    db.raw.execute('DELETE FROM sync_operations');
    service.trash(note.id);
    expect(db.raw.select('SELECT field FROM sync_operations').map((r) => r['field']),
        contains(Operation.tombstoneField));
    db.raw.execute('DELETE FROM sync_operations');
    service.editContent(note.id, '回收站内编辑');
    expect(db.raw.select('SELECT field FROM sync_operations').map((r) => r['field']),
        isNot(contains(Operation.restoreField)));
    expect(notes.byId(note.id)!.deletedAt, isNotNull);
    db.raw.execute('DELETE FROM sync_operations');
    service.restore(note.id);
    expect(db.raw.select('SELECT field FROM sync_operations').map((r) => r['field']),
        contains(Operation.restoreField));
    expect(notes.byId(note.id)!.deletedAt, isNull);
    expect(notes.byId(note.id)!.rawContent, '回收站内编辑');
  });
}
