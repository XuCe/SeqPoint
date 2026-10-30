import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('v11 history survives media sync schema upgrade', () {
    final db = SeqDatabase.inMemory();
    addTearDown(db.close);
    for (var version = 1; version <= 11; version++) {
      for (final sql in migrations[version]!) {
        db.raw.execute(sql);
      }
    }
    db.raw.execute('PRAGMA user_version=11');
    db.raw.execute('INSERT INTO sync_operations VALUES (?,?,?,?,?,?,?,?,?,?)', [
      'old',
      'peer',
      1,
      0,
      'note',
      'n1',
      'raw_content',
      '"keep"',
      'remote',
      null,
    ]);
    db.migrate();
    expect(
      db.raw.select('SELECT value_json FROM sync_operations WHERE op_id=?', [
        'old',
      ]).single['value_json'],
      '"keep"',
    );
    expect(
      db.raw
          .select('SELECT media_enabled FROM sync_local')
          .single['media_enabled'],
      0,
    );
    expect(
      db.raw.select('PRAGMA table_info(attachments)').map((row) => row['name']),
      containsAll(['content_owner', 'manifest_hash']),
    );
    db.raw.execute('INSERT INTO sync_operations VALUES (?,?,?,?,?,?,?,?,?,?)', [
      'media',
      'peer',
      2,
      0,
      'attachment',
      'a1',
      'media',
      '"audio"',
      'remote',
      null,
    ]);
    expect(db.raw.select('PRAGMA integrity_check').single.values.single, 'ok');
    db.migrate();
  });
}
