import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('v9远端收据约束/默认待投影计数，恢复候选清收据和状态', () {
    final db = SeqDatabase.inMemory(); addTearDown(db.close);
    for (var version = 1; version <= 8; version++) {
      for (final sql in migrations[version]!) { db.raw.execute(sql); }
    }
    db.raw.execute('PRAGMA user_version=8'); db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    expect(db.raw.select('SELECT pending_count FROM sync_local').single['pending_count'], 0);
    void insert(int seq, int count, String hash) => db.raw.execute(
        'INSERT INTO sync_received_segments(device_id,seq,key_epoch,created_at,op_count,sealed,segment_hash) '
        'VALUES (?,?,1,?,?,1,?)', ['peer', seq, '2026-10-25T00:00:00.000000Z', count, hash]);
    final hash = '0' * 64;
    insert(1, 1, hash);
    final rejected = throwsA(isA<SqliteException>());
    expect(() => insert(1, 1, hash), rejected);
    expect(() => insert(0, 1, hash), rejected);
    expect(() => insert(2, 0, hash), rejected);
    expect(() => insert(2, 501, hash), rejected);
    expect(() => insert(2, 1, 'bad'), rejected);
    db.raw.execute('UPDATE sync_local SET pending_count=2');
    db.disconnectSyncForRestore();
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['pending_count'], 0); expect(state['requires_new_identity'], 1);
    expect(state['enabled'], 0);
  });
}
