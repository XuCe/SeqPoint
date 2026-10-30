import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late TagRepository repo;
  late String id;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate(); repo = TagRepository(db);
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
    id = repo.upsert(name: '业务名', kind: TagKind.project).id;
    db.raw.execute('UPDATE tags SET name=?,logical_name=? WHERE id=?',
        ['业务名 (id)', '业务名', id]);
    db.raw.execute('DELETE FROM sync_operations');
  });
  tearDown(() => db.close());
  test('显示名noop保留逻辑名，恢复原业务名仅去除派生元数据不发回声', () {
    final clock = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    repo.rename(id, '业务名 (id)');
    expect(repo.byId(id)!.logicalName, '业务名');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    repo.rename(id, '业务名');
    expect(repo.byId(id)!.logicalName, isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, clock);
  });
  test('真实改名清元数据且只发业务新名，操作失败时全部回滚', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_name BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => repo.rename(id, '用户新名'), throwsA(isA<SqliteException>()));
    expect(repo.byId(id)!.name, '业务名 (id)');
    expect(repo.byId(id)!.logicalName, '业务名');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_name');
    repo.rename(id, '用户新名');
    final op = db.raw.select('SELECT field,value_json FROM sync_operations').single;
    expect(op['field'], 'name'); expect(op['value_json'], '"用户新名"');
    expect(repo.byId(id)!.logicalName, isNull);
  });
}
