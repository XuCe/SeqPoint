import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'tag_merge_test.dart' show tag, delta;
import 'sync_projector_test.dart' show facts;
import 'item_tag_projection_test.dart' show link;

void main() {
  test('缺创建字段返回并持久pending，事实补齐后归零', () {
    final db = SeqDatabase.inMemory()..migrate(); addTearDown(db.close);
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    SyncInbox(db).storeVerifiedBatch(peerId: 'peer', operations: [Operation(
        opId: 'partial', deviceId: 'peer', hlc: const Hlc(millis: 1, counter: 0, deviceId: 'peer'),
        objectType: 'note', objectId: 'n1', field: 'raw_content', value: '局部')]);
    expect(SyncProjector(db).project(), 1);
    expect(db.raw.select('SELECT pending_count FROM sync_local').single['pending_count'], 1);
    final source = SeqDatabase.inMemory()..migrate(); addTearDown(source.close);
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    NoteRepository(source).insert(Note(id: 'n1', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '完整', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    SyncInbox(db).storeVerifiedBatch(peerId: 'peer', operations: facts(source));
    expect(SyncProjector(db).project(), 0);
    expect(db.raw.select('SELECT pending_count FROM sync_local').single['pending_count'], 0);
  });
  test('占名标签与缺依赖关联分别计数，补基线后全部归零', () {
    final db = SeqDatabase.inMemory()..migrate(); addTearDown(db.close);
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('a','同名','project')");
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '事项',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    SyncInbox(db).storeVerifiedBatch(peerId: 'b', operations: tag('b'));
    expect(SyncProjector(db).project(), 1);
    SyncInbox(db).storeVerifiedBatch(peerId: 'linker', operations: [link('b', Operation.restoreField, 2)]);
    expect(SyncProjector(db).project(), 2);
    SyncInbox(db).storeVerifiedBatch(peerId: 'a', operations: tag('a'));
    expect(SyncProjector(db).project(), 0);
    expect(ItemRepository(db).tagIdsOf('item'), ['b']);
  });
  test('同批事实先释放墓碑占名再补新目标关联，最终pending为零', () {
    final db = SeqDatabase.inMemory()..migrate(); addTearDown(db.close);
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    db.withoutSyncCapture(() => ItemRepository(db).insert(Item(id: 'item', title: '事项',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026))));
    SyncInbox(db).storeVerifiedBatch(peerId: 'a', operations: tag('a'));
    SyncProjector(db).project();
    db.raw.execute("INSERT INTO item_tags(item_id,tag_id) VALUES ('item','a')");
    SyncInbox(db).storeVerifiedBatch(peerId: 'b', operations: tag('b'));
    SyncInbox(db).storeVerifiedBatch(peerId: 'editor', operations:
        [delta('a', Operation.tombstoneField, true, 2)]);
    SyncInbox(db).storeVerifiedBatch(peerId: 'linker', operations:
        [link('a', Operation.restoreField, 3), link('b', Operation.restoreField, 4)]);
    expect(SyncProjector(db).project(), 0);
    expect(TagRepository(db).byId('a'), isNull);
    expect(TagRepository(db).byId('b')!.name, '同名');
    expect(ItemRepository(db).tagIdsOf('item'), ['b']);
  });
}
