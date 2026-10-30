import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'tag_merge_test.dart' show tag, delta;

void main() {
  late SeqDatabase db;
  late TagRepository repo;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate(); repo = TagRepository(db);
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
  });
  tearDown(() => db.close());
  test('内置想法改名后启动不新增默认标签或操作，旧角色保留', () {
    repo.ensureBuiltins();
    final idea = repo.all().singleWhere((t) => t.sort == 80);
    repo.rename(idea.id, '灵感');
    final count = db.raw.select('SELECT * FROM sync_operations').length;
    repo.ensureBuiltins();
    expect(repo.all(), hasLength(9)); expect(repo.byId(idea.id)!.name, '灵感');
    expect(repo.byId(idea.id)!.isIdea, isTrue);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(count));
  });
  test('角色墓碑已持久保存时启动不创建默认restore或名称', () {
    SyncInbox(db).storeVerifiedBatch(peerId: 'old-idea', operations:
        tag('old-idea', name: '灵感', kind: 'type', builtin: 1, sort: 80));
    SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations:
        [delta('old-idea', Operation.tombstoneField, true, 2)]);
    repo.ensureBuiltins();
    expect(repo.all(), hasLength(8));
    expect(repo.all().any((t) => t.sort == 80), isFalse);
  });
  for (final id in ['builtin-type:8', 'unknown-legacy']) {
    test('$id仅name增量未齐时启动不伪造角色创建', () {
      SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations:
          [delta(id, 'name', '灵感', 2)]);
      repo.ensureBuiltins();
      expect(repo.all(), hasLength(id == 'builtin-type:8' ? 8 : 0));
      expect(repo.all().any((t) => t.sort == 80), isFalse);
    });
  }
  test('普通type占用默认名仍建固定角色，保留普通ID且不发派生名回声', () {
    final ordinary = repo.upsert(name: '想法', kind: TagKind.type);
    final count = db.raw.select('SELECT * FROM sync_operations WHERE object_id=?', [ordinary.id]).length;
    repo.ensureBuiltins();
    expect(repo.all(), hasLength(10));
    expect(repo.byId('builtin-type:8')!.name, '想法');
    expect(repo.byId(ordinary.id)!.name, '想法 (${ordinary.id})');
    expect(repo.byId(ordinary.id)!.logicalName, '想法');
    expect(db.raw.select('SELECT * FROM sync_operations WHERE object_id=?', [ordinary.id]), hasLength(count));
    expect(db.raw.select("SELECT value_json FROM sync_operations WHERE object_id='builtin-type:8' AND field='name'")
        .single['value_json'], '"想法"');
  });
  test('默认消歧预留用户后缀原名，不覆盖已有标签', () {
    final ordinary = repo.upsert(name: '想法', kind: TagKind.type);
    final reserved = repo.upsert(name: '想法 (${ordinary.id})', kind: TagKind.type);
    repo.ensureBuiltins();
    expect(repo.all(), hasLength(11));
    expect(repo.byId(reserved.id)!.name, '想法 (${ordinary.id})');
    expect(repo.byId(ordinary.id)!.name, '想法 (${ordinary.id}) [2]');
  });
  test('内置末项写操作失败撤销此前角色与临时名，保留普通业务名和时钟', () {
    final ordinary = repo.upsert(name: '想法', kind: TagKind.type);
    final count = db.raw.select('SELECT * FROM sync_operations').length;
    final clock = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    db.raw.execute('CREATE TEMP TRIGGER reject_builtin BEFORE INSERT ON sync_operations '
        "WHEN NEW.object_id='builtin-type:8' BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(repo.ensureBuiltins, throwsA(isA<SqliteException>()));
    expect(repo.all(), hasLength(1));
    expect(repo.byId(ordinary.id)!.name, '想法');
    expect(repo.byId(ordinary.id)!.logicalName, isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(count));
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, clock);
    db.raw.execute('DROP TRIGGER reject_builtin'); repo.ensureBuiltins();
    expect(repo.byId('builtin-type:8'), isNotNull);
  });
}
