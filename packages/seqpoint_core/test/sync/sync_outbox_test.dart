import 'dart:convert';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late FakeClock clock;
  late SyncOutbox outbox;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.utc(2026, 10, 25));
    outbox = SyncOutbox(db, clock: clock);
  });
  tearDown(() => db.close());
  Map<String, Object?>? read() {
    final rows = db.raw.select('SELECT * FROM notes WHERE id = ?', ['n1']);
    return rows.isEmpty ? null : Map<String, Object?>.of(rows.single);
  }
  String create() => outbox.capture('note', 'n1', read: read, write: () {
    db.raw.execute('INSERT INTO notes '
        '(id,kind,raw_content,status,created_at,updated_at) VALUES (?,?,?,?,?,?)',
        ['n1', 'text', '正文', 'active', '2026-10-25T08:00:00+08:00', '2026-10-25T08:00:00+08:00']);
    return 'result';
  });
  void enable() => db.raw.execute(
      'UPDATE sync_local SET enabled = 1, device_id = ?', ['pc']);

  test('默认关闭保留业务返回值且不读取或记录快照', () {
    final value = outbox.capture('note', 'n1', read: () => throw StateError('read'),
        write: () => 7);
    expect(value, 7);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  test('公开字段分配独立持久时钟，排除窗体/旧HLC并规范时间', () {
    enable();
    expect(create(), 'result');
    final rows = db.raw.select('SELECT * FROM sync_operations ORDER BY hlc_counter');
    final fields = rows.map((r) => r['field']).toSet();
    expect(fields, containsAll(['raw_content', 'created_at', '__restore__']));
    expect(fields.intersection({'id', 'hlc', 'window_json'}), isEmpty);
    expect(rows.map((r) => r['hlc_counter']).toSet(), hasLength(rows.length));
    final time = rows.singleWhere((r) => r['field'] == 'created_at');
    expect(jsonDecode(time['value_json'] as String), '2026-10-25T00:00:00.000Z');
    expect(db.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'], rows.last['hlc_counter']);
  });
  test('只记录实际字段差异，未变与仅窗口变化不发操作', () {
    enable(); create();
    db.raw.execute('DELETE FROM sync_operations');
    void update(String value) => outbox.capture('note', 'n1', read: read,
        write: () => db.raw.execute('UPDATE notes SET raw_content = ? WHERE id = ?', [value, 'n1']));
    update('正文');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    update('新正文');
    final op = db.raw.select('SELECT * FROM sync_operations').single;
    expect(op['field'], 'raw_content');
    expect(jsonDecode(op['value_json'] as String), '新正文');
    outbox.capture('note', 'n1', read: read,
        write: () => db.raw.execute('UPDATE notes SET window_json = ?', ['{}']));
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(1));
  });
  test('导入抑制连接级嵌套且异常后恢复，不读取差异快照', () {
    enable();
    db.withoutSyncCapture(() => db.withoutSyncCapture(create));
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(() => db.withoutSyncCapture(() => throw StateError('import')), throwsStateError);
    outbox.capture('note', 'n1', read: read,
        write: () => db.raw.execute('UPDATE notes SET raw_content = ?', ['已恢复捕获']));
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(1));
  });
  test('操作写入失败同时回滚业务/HLC，修复后可重试', () {
    enable();
    db.raw.execute('CREATE TEMP TRIGGER reject_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(create, throwsA(isA<SqliteException>()));
    expect(read(), isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
    db.raw.execute('DROP TRIGGER reject_op');
    expect(create(), 'result');
    expect(read(), isNotNull);
  });
  test('外层失败不留下内层业务/操作或时钟', () {
    enable();
    expect(() => db.transaction(() { create(); throw StateError('outer'); }),
        throwsStateError);
    expect(read(), isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
  test('两个连接共用持久时钟，回拨/抑制其他连接/重开不重复', () {
    final dir = Directory.systemTemp.createTempSync('seqpoint_hlc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/shared.db';
    final first = SeqDatabase.open(path)..migrate();
    final second = SeqDatabase.open(path)..migrate();
    first.raw.execute('CREATE TABLE probe(value TEXT)');
    first.raw.execute("INSERT INTO probe(value) VALUES ('0')");
    first.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
    void change(SeqDatabase connection, int value) {
      SyncOutbox(connection, clock: FakeClock(DateTime.fromMillisecondsSinceEpoch(
          identical(connection, first) ? 2000 : 1000))).capture('note', 'n1',
          read: () => {'raw_content': connection.raw.select('SELECT value FROM probe').single['value']},
          write: () => connection.raw.execute('UPDATE probe SET value = ?', ['$value']));
    }
    try {
      for (var value = 1; value <= 4; value++) {
        change(value.isOdd ? first : second, value);
      }
      first.withoutSyncCapture(() => change(second, 5));
      final ops = second.raw.select('SELECT hlc_millis,hlc_counter FROM sync_operations ORDER BY hlc_counter');
      expect(ops, hasLength(5));
      expect(ops.map((r) => r['hlc_millis']).toSet(), {2000});
      expect(ops.map((r) => r['hlc_counter']), [0, 1, 2, 3, 4]);
    } finally {
      first.close(); second.close();
    }
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      change(reopened, 6);
      expect(reopened.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'], 5);
    } finally { reopened.close(); }
  });
  test('删除保留墓碑，普通编辑不复活，明确恢复和物理删除可区分', () {
    enable(); create();
    void clear() => db.raw.execute('DELETE FROM sync_operations');
    Set<String> fields() => db.raw.select('SELECT field FROM sync_operations')
        .map((r) => r['field'] as String).toSet();
    void update(String sql, List<Object?> values) => outbox.capture('note', 'n1',
        read: read, write: () => db.raw.execute(sql, values));
    clear();
    update('UPDATE notes SET deleted_at = ?', ['2026-10-25T00:00:00Z']);
    expect(fields(), {'deleted_at', Operation.tombstoneField});
    clear();
    update('UPDATE notes SET raw_content = ?', ['仍在回收站']);
    expect(fields(), {'raw_content'});
    clear();
    update('UPDATE notes SET deleted_at = ?', [null]);
    expect(fields(), {'deleted_at', Operation.restoreField});
    clear();
    update('DELETE FROM notes WHERE id = ?', ['n1']);
    expect(fields(), {Operation.tombstoneField});
    clear();
    update('DELETE FROM notes WHERE id = ?', ['n1']);
    expect(fields(), isEmpty);
  });
  test('嵌套捕获不同对象时外层读取内层最新时钟，不能复用计数器', () {
    enable(); create();
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('t1','old','project')");
    final before = db.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'] as int;
    outbox.capture('tag', 't1',
        read: () => db.raw.select("SELECT * FROM tags WHERE id = 't1'").single,
        write: () {
      outbox.capture('note', 'n1', read: read,
          write: () => db.raw.execute('UPDATE notes SET raw_content = ?', ['inner']));
      db.raw.execute("UPDATE tags SET name = 'outer' WHERE id = 't1'");
    });
    final ops = db.raw.select('SELECT * FROM sync_operations WHERE hlc_counter > ?', [before]);
    expect(ops.map((r) => r['field']).toSet(), {'raw_content', 'name'});
    expect(db.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'], before + 2);
  });
}
