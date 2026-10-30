import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'tag_merge_test.dart' show tag, delta;

void main() {
  late SeqDatabase db;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
  });
  tearDown(() => db.close());
  void receive(String peer, List<Operation> ops) => SyncInbox(db)
      .storeVerifiedBatch(peerId: peer, operations: ops);
  test('同名普通标签保留两个ID，显示和逻辑名分别持久化，无回声', () {
    receive('b', tag('b')); receive('a', tag('a'));
    SyncProjector(db).project();
    final repo = TagRepository(db);
    expect(repo.all(), hasLength(2));
    expect(repo.byId('a')!.name, '同名');
    expect(repo.byId('b')!.name, '同名 (b)');
    expect(repo.byId('b')!.logicalName, '同名');
    expect(db.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
    SyncProjector(db).project(); expect(repo.all(), hasLength(2));
  });
  test('旧内置alias已有本机关联先迁canonical，再删除alias，不丢关联', () {
    db.raw.execute("INSERT INTO tags(id,name,kind,builtin,sort) VALUES ('legacy','想法','type',1,80)");
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '关联事项',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    db.raw.execute("INSERT INTO item_tags(item_id,tag_id) VALUES ('item','legacy')");
    receive('legacy', tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80));
    SyncProjector(db).project();
    expect(TagRepository(db).byId('legacy'), isNull);
    expect(TagRepository(db).byId('builtin-type:8')!.name, '想法');
    expect(ItemRepository(db).tagIdsOf('item'), ['builtin-type:8']);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(db.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
  });
  test('唯一索引保留，两标签交换名字可在一个事务中完成', () {
    receive('a', tag('a', name: 'A')); receive('b', tag('b', name: 'B'));
    SyncProjector(db).project();
    receive('editor', [delta('a', 'name', 'B', 2), delta('b', 'name', 'A', 3)]);
    SyncProjector(db).project();
    expect(TagRepository(db).byId('a')!.name, 'B');
    expect(TagRepository(db).byId('b')!.name, 'A');
    expect(() => db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('c','A','project')"),
        throwsA(isA<SqliteException>()));
  });
  test('未基线本机占名先等待，保持原行与元数据；事实补齐可重试', () {
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('a','同名','project')");
    receive('b', tag('b')); SyncProjector(db).project();
    expect(TagRepository(db).all(), hasLength(1));
    expect(TagRepository(db).byId('a')!.name, '同名');
    expect(TagRepository(db).byId('a')!.logicalName, isNull);
    expect(db.raw.select('SELECT * FROM sync_operations'), isNotEmpty);
    receive('a', tag('a')); SyncProjector(db).project();
    expect(TagRepository(db).all(), hasLength(2));
    expect(TagRepository(db).byId('b')!.name, '同名 (b)');
  });
  test('完整标签墓碑遇未事实化关联暂缓，不提交临时名或级联丢关系', () {
    receive('a', tag('a')); SyncProjector(db).project();
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '本机关联',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    db.raw.execute("INSERT INTO item_tags(item_id,tag_id) VALUES ('item','a')");
    receive('editor', [delta('a', Operation.tombstoneField, true, 2)]);
    SyncProjector(db).project();
    expect(TagRepository(db).byId('a')!.name, '同名');
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('名称交换中途拒写撤销临时名/事实/时钟，解除故障可重试', () {
    receive('a', tag('a', name: 'A')); receive('b', tag('b', name: 'B'));
    SyncProjector(db).project();
    final count = db.raw.select('SELECT * FROM sync_operations').length;
    final clock = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    final edits = [delta('a', 'name', 'B', 2), delta('b', 'name', 'A', 3)];
    db.raw.execute('CREATE TEMP TRIGGER reject_tag BEFORE UPDATE ON tags '
        "WHEN OLD.id='b' BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => db.transaction(() {
      receive('editor', edits); SyncProjector(db).project();
    }), throwsStateError);
    expect(TagRepository(db).byId('a')!.name, 'A');
    expect(TagRepository(db).byId('b')!.name, 'B');
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(count));
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, clock);
    db.raw.execute('DROP TRIGGER reject_tag');
    receive('editor', edits); SyncProjector(db).project();
    expect(TagRepository(db).byId('a')!.name, 'B');
  });
  test('alias删除失败撤销新canonical和已搬迁关联，重试完整保留关系', () {
    db.raw.execute("INSERT INTO tags(id,name,kind,builtin,sort) VALUES ('legacy','想法','type',1,80)");
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '关联事项',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    db.raw.execute("INSERT INTO item_tags(item_id,tag_id) VALUES ('item','legacy')");
    db.raw.execute('CREATE TEMP TRIGGER reject_alias BEFORE DELETE ON tags '
        "WHEN OLD.id='legacy' BEGIN SELECT RAISE(ABORT,'forced'); END");
    final ops = tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80);
    expect(() => db.transaction(() {
      receive('legacy', ops); SyncProjector(db).project();
    }), throwsStateError);
    expect(TagRepository(db).byId('legacy')!.name, '想法');
    expect(TagRepository(db).byId('builtin-type:8'), isNull);
    expect(ItemRepository(db).tagIdsOf('item'), ['legacy']);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_alias');
    receive('legacy', ops); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['builtin-type:8']);
    expect(TagRepository(db).byId('legacy'), isNull);
  });
  test('删除释放名称并清旧逻辑名，普通字段不复活，明确恢复可重建', () {
    receive('a', tag('a')); receive('b', tag('b')); SyncProjector(db).project();
    receive('editor', [delta('a', Operation.tombstoneField, true, 2)]);
    SyncProjector(db).project();
    expect(TagRepository(db).byId('a'), isNull);
    expect(TagRepository(db).byId('b')!.name, '同名');
    expect(TagRepository(db).byId('b')!.logicalName, isNull);
    receive('editor', [delta('a', 'name', '恢复前编辑', 3)]);
    SyncProjector(db).project(); expect(TagRepository(db).byId('a'), isNull);
    receive('editor', [delta('a', Operation.restoreField, true, 4)]);
    SyncProjector(db).project(); expect(TagRepository(db).byId('a')!.name, '恢复前编辑');
  });
  test('占名等待事实关闭重开仍保留，补齐后重投影', () {
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('a','同名','project')");
    receive('b', tag('b')); SyncProjector(db).project();
    final directory = Directory.systemTemp.createTempSync('seqpoint_tag_projection_');
    final path = '${directory.path}/pending.db'; db.raw.execute('VACUUM INTO ?', [path]);
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      expect(TagRepository(reopened).byId('a')!.name, '同名');
      expect(TagRepository(reopened).byId('b'), isNull);
      SyncInbox(reopened).storeVerifiedBatch(peerId: 'a', operations: tag('a'));
      SyncProjector(reopened).project();
      expect(TagRepository(reopened).byId('b')!.name, '同名 (b)');
      expect(TagRepository(reopened).byId('b')!.logicalName, '同名');
    } finally { reopened.close(); directory.deleteSync(recursive: true); }
  });
  test('多批正反序到达的普通同名最终显示与逻辑名一致', () {
    for (final order in [['a', 'b'], ['b', 'a']]) {
      db.raw.execute('DELETE FROM tags'); db.raw.execute('DELETE FROM sync_operations');
      for (final id in order) { receive(id, tag(id)); SyncProjector(db).project(); }
      expect(TagRepository(db).byId('a')!.name, '同名');
      expect(TagRepository(db).byId('a')!.logicalName, isNull);
      expect(TagRepository(db).byId('b')!.name, '同名 (b)');
      expect(TagRepository(db).byId('b')!.logicalName, '同名');
    }
  });
}
