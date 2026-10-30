import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('v7迁移增加本机逻辑名，保留原标签且默认NULL，不加入wire', () {
    final db = SeqDatabase.inMemory();
    addTearDown(db.close);
    for (var version = 1; version <= 7; version++) {
      for (final sql in migrations[version]!) { db.raw.execute(sql); }
    }
    db.raw.execute('PRAGMA user_version=7');
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('tag','原标签','project')");
    db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    final row = db.raw.select('SELECT * FROM tags').single;
    expect(row['id'], 'tag'); expect(row['name'], '原标签');
    expect(row.containsKey('logical_name'), isTrue);
    expect(row['logical_name'], isNull);
    db.raw.execute('UPDATE tags SET name=?,logical_name=? WHERE id=?',
        ['原标签 (tag)', '原标签', 'tag']);
    db.migrate();
    expect(db.raw.select('SELECT logical_name FROM tags').single['logical_name'], '原标签');
    expect(Operation.syncFields['tag'], {'name', 'kind', 'builtin', 'color', 'sort'});
  });
}
