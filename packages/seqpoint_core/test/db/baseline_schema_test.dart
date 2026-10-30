import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('v10基线默认未完成，取值约束且恢复候选重置ready', () {
    final db = SeqDatabase.inMemory(); addTearDown(db.close);
    for (var version = 1; version <= 9; version++) {
      for (final sql in migrations[version]!) { db.raw.execute(sql); }
    }
    db.raw.execute('PRAGMA user_version=9'); db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    expect(db.raw.select('SELECT baseline_ready FROM sync_local').single['baseline_ready'], 0);
    expect(() => db.raw.execute('UPDATE sync_local SET baseline_ready=2'), throwsA(isA<SqliteException>()));
    db.raw.execute("UPDATE sync_local SET device_id='writer',enabled=1,baseline_ready=1");
    db.disconnectSyncForRestore();
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['baseline_ready'], 0); expect(state['requires_new_identity'], 1);
    expect(state['enabled'], 0);
  });
}
