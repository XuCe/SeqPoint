import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'tag_merge_test.dart' show tag, delta;

Operation link(String tagId, String field, int millis, {String itemId = 'item'}) =>
    Operation(opId: '$tagId-$field-$millis', deviceId: 'linker',
      hlc: Hlc(millis: millis, counter: 0, deviceId: 'linker'), objectType: 'item_tag',
      objectId: Operation.itemTagId(itemId, tagId), field: field, value: true);

void main() {
  late SeqDatabase db;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '事项',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    SyncInbox(db).storeVerifiedBatch(peerId: 'a', operations: tag('a'));
    SyncProjector(db).project();
  });
  tearDown(() => db.close());
  void receive(List<Operation> ops) => SyncInbox(db)
      .storeVerifiedBatch(peerId: 'linker', operations: ops);
  test('marker-only关联有明确意图，present不覆盖墓碑，真实新restore可重加', () {
    receive([link('a', Operation.restoreField, 2)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
    receive([link('a', Operation.tombstoneField, 3)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    receive([link('a', 'present', 4)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    receive([link('a', Operation.restoreField, 5)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
    expect(db.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
  });
  test('跨alias先归组，较旧restore不绕过canonical删除，较新重加可恢复', () {
    for (final id in ['legacy', 'other']) {
      SyncInbox(db).storeVerifiedBatch(peerId: id, operations:
          tag(id, name: '想法', kind: 'type', builtin: 1, sort: 80));
    }
    receive([link('legacy', Operation.restoreField, 2)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['builtin-type:8']);
    receive([link('builtin-type:8', Operation.tombstoneField, 4),
      link('other', Operation.restoreField, 3)]);
    SyncProjector(db).project(); expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    receive([link('legacy', 'present', 5)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    receive([link('legacy', Operation.restoreField, 6)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['builtin-type:8']);
  });
  test('普通同名关联保留各自身份，另一ID删除不吞关系，重复投影幂等', () {
    SyncInbox(db).storeVerifiedBatch(peerId: 'b', operations: tag('b'));
    receive([link('b', Operation.restoreField, 2)]); SyncProjector(db).project();
    expect(TagRepository(db).byId('b')!.name, '同名 (b)');
    expect(ItemRepository(db).tagIdsOf('item'), ['b']);
    receive([link('a', Operation.tombstoneField, 3)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['b']);
    receive([link('a', Operation.restoreField, 4)]); SyncProjector(db).project();
    SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), unorderedEquals(['a', 'b']));
    expect(db.raw.select('SELECT * FROM item_tags'), hasLength(2));
  });
  test('仅present保留事实待补，不能伪造一次添加', () {
    receive([link('a', 'present', 2)]); expect(SyncProjector(db).project(), 1);
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    receive([link('a', Operation.restoreField, 3)]); expect(SyncProjector(db).project(), 0);
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
  });
  test('标签墓碑先保留未事实化关系，补关联事实后同事务清理，恢复可重建', () {
    db.raw.execute("INSERT INTO item_tags(item_id,tag_id) VALUES ('item','a')");
    SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations:
        [delta('a', Operation.tombstoneField, true, 2)]);
    SyncProjector(db).project();
    expect(TagRepository(db).byId('a'), isNotNull);
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
    receive([link('a', Operation.restoreField, 3)]); SyncProjector(db).project();
    expect(TagRepository(db).byId('a'), isNull);
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations:
        [delta('a', Operation.restoreField, true, 4)]);
    SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('缺事项的关联意图重开仍保留，依赖创建后补投影', () {
    receive([link('a', Operation.restoreField, 2, itemId: 'late')]); SyncProjector(db).project();
    final directory = Directory.systemTemp.createTempSync('seqpoint_link_projection_');
    final path = '${directory.path}/pending.db'; db.raw.execute('VACUUM INTO ?', [path]);
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      expect(reopened.raw.select('SELECT * FROM item_tags'), isEmpty);
      ItemRepository(reopened).insert(Item(id: 'late', title: '后到事项',
          status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
          createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
      SyncProjector(reopened).project();
      expect(ItemRepository(reopened).tagIdsOf('late'), ['a']);
      expect(reopened.raw.select('PRAGMA foreign_key_check'), isEmpty);
    } finally { reopened.close(); directory.deleteSync(recursive: true); }
  });
  test('有本机旧alias行也不借它补身份，标签事实齐后才归一关联', () {
    db.raw.execute("INSERT INTO tags(id,name,kind,builtin,sort) VALUES ('legacy','想法','type',1,80)");
    receive([link('legacy', Operation.restoreField, 2)]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations: [delta('legacy', 'name', '灵感', 3)]);
    SyncProjector(db).project(); expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    SyncInbox(db).storeVerifiedBatch(peerId: 'legacy', operations:
        tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80));
    SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['builtin-type:8']);
    expect(TagRepository(db).byId('builtin-type:8')!.name, '灵感');
    expect(TagRepository(db).byId('legacy'), isNull);
  });
  test('关联拒写撤销同批事实/时钟和标签临时名，解除故障可重试', () {
    final count = db.raw.select('SELECT * FROM sync_operations').length;
    final clock = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    final op = link('a', Operation.restoreField, 2);
    db.raw.execute('CREATE TEMP TRIGGER reject_link BEFORE INSERT ON item_tags '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => db.transaction(() {
      receive([op]); SyncProjector(db).project();
    }), throwsStateError);
    expect(ItemRepository(db).tagIdsOf('item'), isEmpty);
    expect(TagRepository(db).byId('a')!.name, '同名');
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(count));
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, clock);
    db.raw.execute('DROP TRIGGER reject_link');
    receive([op]); SyncProjector(db).project();
    expect(ItemRepository(db).tagIdsOf('item'), ['a']);
  });
}
