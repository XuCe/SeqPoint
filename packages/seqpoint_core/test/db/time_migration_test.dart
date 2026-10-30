import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

SeqDatabase legacy() {
  final db = SeqDatabase.inMemory();
  for (var version = 1; version <= 6; version++) {
    for (final sql in migrations[version]!) { db.raw.execute(sql); }
  }
  db.raw.execute('PRAGMA user_version = 6');
  addTearDown(db.close);
  return db;
}

void note(SeqDatabase db, String id, String created, String updated) =>
    db.raw.execute('INSERT INTO notes '
        '(id,kind,status,created_at,updated_at) VALUES (?,?,?,?,?)',
        [id, 'text', 'active', created, updated]);

void main() {
  test('v7旧本地/偏移/UTC日期统一六位，空值保留，重复迁移无变化', () {
    final db = legacy();
    const naive = '2026-10-25T10:30:00.001';
    note(db, 'n', naive, '2026-10-25T10:30:00.000001-07:00');
    db.raw.execute('INSERT INTO notification_plans '
        '(plan_key,item_id,fire_at,state) VALUES (?,?,?,?)',
        ['p', 'i', '2026-10-25T17:30:00.000Z', 'scheduled']);
    db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    final row = db.raw.select('SELECT * FROM notes').single;
    expect(row['created_at'], encodeTime(DateTime.parse(naive)));
    expect(row['updated_at'], '2026-10-25T17:30:00.000001Z');
    expect(row['deleted_at'], isNull);
    expect(db.raw.select('SELECT fire_at FROM notification_plans').single['fire_at'],
        '2026-10-25T17:30:00.000000Z');
    db.migrate();
    expect(db.raw.select('SELECT * FROM notes').single, row);
  });

  test('无效旧日期使v7整体回滚，版本与先前行保持原值', () {
    final db = legacy();
    note(db, 'n', '2026-10-25', 'invalid');
    expect(db.migrate, throwsFormatException);
    expect(db.schemaVersion, 6);
    expect(db.raw.select('SELECT created_at FROM notes').single['created_at'], '2026-10-25');
  });
  test('所有日期列均迁移，密文和操作JSON及封装字节不变', () {
    final db = legacy();
    const old = '2026-10-25T17:30:00.001Z';
    const expected = '2026-10-25T17:30:00.001000Z';
    final fixtures = <String, List<String>>{
      'notes': ['id,kind,status,created_at,updated_at,closed_at,deleted_at',
        "'n','text','active',?,?,?,?"],
      'items': ['id,title,status,created_at,updated_at,due_at,completed_at,deleted_at',
        "'i','测试','todo',?,?,?,?,?"],
      'reminders': ['id,item_id,mode,trigger_at,last_fired_at', "'r','i','smart',?,?"],
      'activities': ['id,object_type,object_id,action,created_at', "'a','note','n','edit',?"],
      'attachments': ['id,created_at,deleted_at', "'f',?,?"],
      'devices': ['id,name,signing_public_key,exchange_public_key,added_at,revoked_at',
        "'d','test','fake','fake',?,?"],
      'sync_state': ['device_id,last_synced_at', "'d',?"],
      'secrets': ['id,kind,provider,ciphertext,updated_at',
        "'s','aiApiKey','fake','opaque',?"],
      'notification_plans': ['plan_key,item_id,fire_at,state', "'p','i',?,'pending'"],
    };
    for (final fixture in fixtures.entries) {
      db.raw.execute('INSERT INTO ${fixture.key} (${fixture.value[0]}) '
          'VALUES (${fixture.value[1]})',
          List.filled('?'.allMatches(fixture.value[1]).length, old));
    }
    db.raw.execute('INSERT INTO sync_operations VALUES '
        "('op','d',1,0,'note','n','raw_content',?,'remote',NULL)", ['"$old"']);
    db.raw.execute('INSERT INTO sync_publications VALUES (1,?,1,?,1,0)',
        ['202610-0001.log', [1, 2, 3]]);
    db.migrate();
    for (final fixture in fixtures.entries) {
      final fields = fixture.value[0].split(',').where((f) => f.endsWith('_at'));
      final row = db.raw.select('SELECT ${fields.join(',')} FROM ${fixture.key}').single;
      for (final value in row.values) { expect(value, expected); }
    }
    expect(db.raw.select('SELECT ciphertext FROM secrets').single['ciphertext'], 'opaque');
    expect(db.raw.select('SELECT value_json FROM sync_operations').single['value_json'], '"$old"');
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], [1, 2, 3]);
  });
}
