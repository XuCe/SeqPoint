import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  late SeqDatabase source, target;
  late Note note;
  late Item item;
  setUp(() {
    source = SeqDatabase.inMemory()..migrate();
    target = SeqDatabase.inMemory()..migrate();
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    target.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
    final clock = FakeClock(DateTime.utc(2026, 10, 25));
    note = NoteRepository(source, clock: clock).insert(Note(id: 'same',
        kind: NoteKind.text, status: NoteStatus.active, rawContent: '父便签原文',
        createdAt: clock.now(), updatedAt: clock.now()));
    item = ItemRepository(source, clock: clock).insert(Item(id: 'same',
        noteId: note.id, lineIndex: 0, title: '子事项标题', status: ItemStatus.todo,
        priority: Priority.p1, source: ItemSource.ai,
        dueAt: DateTime(2026, 11, 1, 23, 30).toUtc(),
        createdAt: clock.now(), updatedAt: clock.now()));
  });
  tearDown(() { source.close(); target.close(); });
  void receive(List<Operation> ops) => SyncInbox(target)
      .storeVerifiedBatch(peerId: 'peer', operations: ops);

  test('便签与同ID事项按类型隔离，乱序同批先投影父对象', () {
    receive(facts(source).reversed.toList()); SyncProjector(target).project();
    expect(NoteRepository(target).byId('same')!.rawContent, '父便签原文');
    final result = ItemRepository(target).byId('same')!;
    expect(result.title, '子事项标题'); expect(result.noteId, note.id);
    expect(result.dueAt!.isAtSameMomentAs(item.dueAt!), isTrue);
    expect(result.source, ItemSource.ai);
    expect(target.raw.select('SELECT * FROM search_index'), hasLength(2));
    expect(target.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('事项先到持久等待缺失父便签，后续重投影可补齐', () {
    receive(facts(source).where((op) => op.objectType == 'item').toList());
    SyncProjector(target).project(); expect(ItemRepository(target).byId('same'), isNull);
    receive(facts(source).where((op) => op.objectType == 'note').toList());
    SyncProjector(target).project();
    expect(ItemRepository(target).byId('same')!.noteId, note.id);
  });
  test('note_id缺失不能默认为独立事项，显式null可以', () {
    final operations = facts(source);
    receive(operations.where((op) => op.field != 'note_id').toList());
    SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id), isNull);
    receive(operations.where((op) => op.field == 'note_id').toList());
    SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id)!.noteId, note.id);
    final standalone = ItemRepository(source).insert(Item(id: 'standalone',
        title: '独立', status: ItemStatus.todo, priority: Priority.p4,
        source: ItemSource.manual, createdAt: item.createdAt, updatedAt: item.updatedAt));
    receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).byId(standalone.id)!.noteId, isNull);
  });
  test('事项软删/普通编辑/恢复与物理清理保持索引和墓碑，不产回声', () {
    final repo = ItemRepository(source);
    receive(facts(source)); SyncProjector(target).project();
    repo.update(item.copyWith(deletedAt: DateTime.utc(2026, 10, 25)));
    repo.update(repo.byId(item.id)!.copyWith(title: '删除后更新'));
    receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id)!.deletedAt, isNotNull);
    expect(target.raw.select("SELECT * FROM search_index WHERE object_type='item'"), isEmpty);
    repo.update(repo.byId(item.id)!.copyWith(clearDeletedAt: true));
    receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id)!.deletedAt, isNull);
    expect(target.raw.select("SELECT text FROM search_index WHERE object_type='item'").single['text'],
        '删除后更新');
    repo.purge(item.id); receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id)!.deletedAt, isNotNull);
    expect(target.raw.select("SELECT * FROM search_index WHERE object_type='item'"), isEmpty);
    expect(target.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
  });
  test('更新保留本机来源引用和旧hlc，不复制对端本机字段', () {
    receive(facts(source)); SyncProjector(target).project();
    const local = '{"note_id":"local-only","timestamp_ms":123}';
    target.raw.execute('UPDATE items SET source_ref_json=?,hlc=?', [local, 'legacy']);
    ItemRepository(source).update(item.copyWith(title: '远端事项编辑',
        sourceRef: const SourceRef(noteId: 'peer-only', timestampMs: 456)));
    receive(facts(source)); SyncProjector(target).project();
    final row = target.raw.select('SELECT * FROM items').single;
    expect(row['source_ref_json'], local); expect(row['hlc'], 'legacy');
    expect(row['title'], '远端事项编辑');
    expect(target.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('事项拒写回滚此前便签和索引及同批事实，解除故障可重试', () {
    receive(facts(source)); SyncProjector(target).project();
    final count = facts(target).length;
    NoteRepository(source).update(note.copyWith(rawContent: '批内便签修改'));
    ItemRepository(source).update(item.copyWith(title: '批内事项修改'));
    target.raw.execute('CREATE TEMP TRIGGER reject_item BEFORE UPDATE ON items '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => target.transaction(() {
      receive(facts(source)); SyncProjector(target).project();
    }), throwsStateError);
    expect(NoteRepository(target).byId(note.id)!.rawContent, '父便签原文');
    expect(ItemRepository(target).byId(item.id)!.title, '子事项标题');
    expect(facts(target), hasLength(count));
    expect(target.raw.select('SELECT text FROM search_index').map((r) => r['text']),
        unorderedEquals(['父便签原文', '子事项标题']));
    target.raw.execute('DROP TRIGGER reject_item');
    receive(facts(source)); SyncProjector(target).project();
    expect(NoteRepository(target).byId(note.id)!.rawContent, '批内便签修改');
    expect(ItemRepository(target).byId(item.id)!.title, '批内事项修改');
  });
  test('缺父操作关闭重开仍保留，补入父对象后可完成投影', () {
    receive(facts(source).where((op) => op.objectType == 'item').toList());
    SyncProjector(target).project();
    final directory = Directory.systemTemp.createTempSync('seqpoint_projection_');
    final path = '${directory.path}/pending.db';
    target.raw.execute('VACUUM INTO ?', [path]);
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      expect(ItemRepository(reopened).byId(item.id), isNull);
      expect(facts(reopened), isNotEmpty);
      SyncInbox(reopened).storeVerifiedBatch(peerId: 'peer', operations:
          facts(source).where((op) => op.objectType == 'note').toList());
      SyncProjector(reopened).project();
      expect(ItemRepository(reopened).byId(item.id)!.noteId, note.id);
      expect(reopened.raw.select('SELECT * FROM search_index'), hasLength(2));
    } finally {
      reopened.close(); directory.deleteSync(recursive: true);
    }
  });
  test('父便签软删除隐藏子事项查询/提醒/搜索，恢复后保留原子事项', () async {
    receive(facts(source)); SyncProjector(target).project();
    final repo = NoteRepository(source);
    repo.update(note.copyWith(deletedAt: DateTime.utc(2026, 10, 25)));
    receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).byId(item.id), isNotNull);
    expect(ItemRepository(target).openAll(), isEmpty);
    expect(ItemRepository(target).remindable(), isEmpty);
    expect(await SearchService(target).query('子事项标题'), isEmpty);
    expect(target.raw.select('PRAGMA foreign_key_check'), isEmpty);
    repo.update(repo.byId(note.id)!.copyWith(clearDeletedAt: true));
    receive(facts(source)); SyncProjector(target).project();
    expect(ItemRepository(target).openAll().single.id, item.id);
    expect(await SearchService(target).query('子事项标题'), hasLength(1));
  });
}
