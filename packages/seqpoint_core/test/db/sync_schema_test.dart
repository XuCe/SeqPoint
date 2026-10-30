import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('v5迁移保留业务和通知，v6同步默认关闭且无私钥列', () {
    final db = SeqDatabase.inMemory();
    addTearDown(db.close);
    for (var version = 1; version <= 5; version++) {
      for (final sql in migrations[version]!) { db.raw.execute(sql); }
    }
    db.raw.execute('PRAGMA user_version = 5');
    db.raw.execute('INSERT INTO notes '
        '(id,kind,raw_content,status,created_at,updated_at) VALUES (?,?,?,?,?,?)',
        ['n1', 'text', '原有便签', 'active', '2026-10-25', '2026-10-25']);
    db.raw.execute('INSERT INTO notification_plans '
        '(plan_key,item_id,fire_at,state) VALUES (?,?,?,?)',
        ['p1', 'i1', '2026-10-25', 'scheduled']);
    db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    expect(db.raw.select('SELECT raw_content FROM notes').single['raw_content'], '原有便签');
    expect(db.raw.select('SELECT state FROM notification_plans').single['state'], 'scheduled');
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['enabled'], 0);
    expect(state['device_id'], isNull);
    expect(state['hlc_millis'], 0);
    expect(state['hlc_counter'], 0);
    expect(state['requires_new_identity'], 0);
    for (final table in ['sync_local', 'sync_operations', 'sync_publications']) {
      final columns = db.raw.select('PRAGMA table_info($table)');
      expect(columns.map((r) => r['name']), isNot(contains('private_key')));
      expect(columns.map((r) => r['name']), isNot(contains('epoch_key')));
    }
    db.migrate();
    expect(db.raw.select('SELECT * FROM sync_local'), hasLength(1));
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
  });
  test('操作ID与writer时钟唯一，范围约束有效且不级联丢历史', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    void insert(String id, int counter, {String type = 'note', String source = 'local'}) {
      db.raw.execute('INSERT INTO sync_operations '
          '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
          'VALUES (?,?,?,?,?,?,?,?,?)', [id, 'pc', 1, counter, type, 'n1', 'raw_content', '"x"', source]);
    }
    insert('op1', 0);
    final rejected = throwsA(isA<SqliteException>());
    expect(() => insert('op1', 1), rejected);
    expect(() => insert('op2', 0), rejected);
    expect(() => insert('op2', 1, type: 'secret'), rejected);
    expect(() => insert('op2', 1, source: 'unknown'), rejected);
    expect(() => insert('op2', -1), rejected);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(1));
    expect(db.raw.select('PRAGMA foreign_key_list(sync_operations)'), isEmpty);
    expect(() => db.raw.execute('UPDATE sync_local SET enabled = 1'), rejected);
    db.raw.execute('UPDATE sync_local SET device_id = ?, enabled = 1', ['pc']);
    expect(() => db.raw.execute('UPDATE sync_local SET requires_new_identity = 1'), rejected);
    db.raw.execute('UPDATE sync_local SET enabled = 0, requires_new_identity = 1');
  });
  test('发布记录限制正序号/Epoch、文件名唯一且默认未发布', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    void insert(int seq, String name, int epoch) => db.raw.execute(
        'INSERT INTO sync_publications(seq,file_name,key_epoch,segment_bytes,sealed) VALUES (?,?,?,?,?)',
        [seq, name, epoch, [1, 2], 0]);
    final rejected = throwsA(isA<SqliteException>());
    expect(() => insert(0, 'bad', 1), rejected);
    expect(() => insert(1, 'bad', 0), rejected);
    insert(1, '202610-0001.log', 1);
    expect(() => insert(2, '202610-0001.log', 1), rejected);
    expect(db.raw.select('SELECT published FROM sync_publications').single['published'], 0);
  });
}
