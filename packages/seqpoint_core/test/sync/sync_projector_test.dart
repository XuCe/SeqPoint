import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

List<Operation> facts(SeqDatabase db) => db.raw.select('SELECT * FROM sync_operations')
    .map((r) => Operation(opId: r['op_id'] as String,
      deviceId: r['device_id'] as String,
      hlc: Hlc(millis: r['hlc_millis'] as int, counter: r['hlc_counter'] as int,
          deviceId: r['device_id'] as String),
      objectType: r['object_type'] as String, objectId: r['object_id'] as String,
      field: r['field'] as String, value: jsonDecode(r['value_json'] as String))).toList();

void main() {
  late SeqDatabase source, target;
  late NoteRepository notes;
  setUp(() {
    source = SeqDatabase.inMemory()..migrate();
    target = SeqDatabase.inMemory()..migrate();
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    target.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
    notes = NoteRepository(source, clock: FakeClock(DateTime.utc(2026, 10, 25)));
  });
  tearDown(() { source.close(); target.close(); });
  Note create() => notes.insert(Note(id: 'same', kind: NoteKind.text,
      status: NoteStatus.active, title: '便签标题', rawContent: '原始文本',
      createdAt: DateTime.utc(2026, 10, 25), updatedAt: DateTime.utc(2026, 10, 25)));
  void receive(List<Operation> ops) => SyncInbox(target)
      .storeVerifiedBatch(peerId: 'peer', operations: ops);
  Operation change(String field, Object? value, int counter) => Operation(
      opId: 'change-$counter', deviceId: 'peer',
      hlc: Hlc(millis: DateTime.utc(2026, 10, 25).millisecondsSinceEpoch,
          counter: counter, deviceId: 'peer'),
      objectType: 'note', objectId: 'same', field: field, value: value);

  test('真实仓储乱序字段按LWW投影便签和索引，不产回声或水位', () {
    final note = create();
    notes.update(note.copyWith(rawContent: '最新文本'));
    receive(facts(source).reversed.toList());
    SyncProjector(target).project();
    expect(NoteRepository(target).byId(note.id)!.rawContent, '最新文本');
    expect(target.raw.select('SELECT text FROM search_index').single['text'], '便签标题\n最新文本');
    expect(target.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
    expect(target.raw.select('SELECT * FROM sync_state'), isEmpty);
    SyncProjector(target).project();
    expect(target.raw.select('SELECT * FROM search_index'), hasLength(1));
  });
  test('创建字段未齐先持久等待，补齐后重投影，不编造默认正文或日期', () {
    create();
    final operations = facts(source);
    final missing = operations.where((op) => op.field == 'created_at').toList();
    receive(operations.where((op) => op.field != 'created_at').toList());
    SyncProjector(target).project();
    expect(target.raw.select('SELECT * FROM notes'), isEmpty);
    expect(target.raw.select('SELECT * FROM sync_operations'), hasLength(operations.length - 1));
    receive(missing);
    SyncProjector(target).project();
    expect(NoteRepository(target).byId('same')!.rawContent, '原始文本');
    expect(NoteRepository(target).byId('same')!.createdAt, DateTime.utc(2026, 10, 25));
  });
  test('物理删除墓碑保留FK行，普通更新不复活，明确恢复才重新索引', () {
    create();
    receive(facts(source));
    SyncProjector(target).project();
    receive([change(Operation.tombstoneField, true, 100),
      change('raw_content', '墓碑后编辑', 101)]);
    SyncProjector(target).project();
    final hidden = NoteRepository(target).byId('same')!;
    expect(hidden.deletedAt, isNotNull);
    expect(hidden.rawContent, '墓碑后编辑');
    expect(target.raw.select('SELECT * FROM search_index'), isEmpty);
    receive([change(Operation.restoreField, true, 102)]);
    SyncProjector(target).project();
    expect(NoteRepository(target).byId('same')!.deletedAt, isNull);
    expect(target.raw.select('SELECT text FROM search_index').single['text'],
        '便签标题\n墓碑后编辑');
  });
  test('UPSERT保留本机窗口与旧hlc，不替换便签或破坏子事项FK', () {
    create(); receive(facts(source)); SyncProjector(target).project();
    const window = '{"x":1,"y":2,"w":300,"h":400}';
    target.raw.execute('UPDATE notes SET window_json=?,hlc=?', [window, 'legacy']);
    target.raw.execute('INSERT INTO items(id,note_id,title,status,created_at,updated_at) '
        "VALUES ('child','same','child','todo',?,?)",
        [encodeTime(DateTime.utc(2026)), encodeTime(DateTime.utc(2026))]);
    receive([change('raw_content', '远端修改', 100)]);
    SyncProjector(target).project();
    final row = target.raw.select('SELECT * FROM notes').single;
    expect(row['window_json'], window);
    expect(row['hlc'], 'legacy');
    expect(row['raw_content'], '远端修改');
    expect(target.raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(target.raw.select('SELECT * FROM items'), hasLength(1));
    expect(target.raw.select("SELECT * FROM sync_operations WHERE source='local'"), isEmpty);
  });
  test('索引写入失败回滚业务、同批事实和时钟，错误脱敏后可重试', () {
    create(); receive(facts(source)); SyncProjector(target).project();
    final count = facts(target).length;
    final clock = target.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'];
    final next = change('raw_content', '必须保密的修改', 100);
    target.raw.execute('ALTER TABLE search_index RENAME TO saved_index');
    expect(() => target.transaction(() {
      receive([next]); SyncProjector(target).project();
    }), throwsA(isA<StateError>().having((e) => e.toString(), '脱敏',
        isNot(contains('必须保密')))));
    expect(NoteRepository(target).byId('same')!.rawContent, '原始文本');
    expect(facts(target), hasLength(count));
    expect(target.raw.select('SELECT hlc_counter FROM sync_local').single['hlc_counter'], clock);
    expect(target.raw.select('SELECT text FROM saved_index').single['text'], '便签标题\n原始文本');
    target.raw.execute('ALTER TABLE saved_index RENAME TO search_index');
    receive([next]); SyncProjector(target).project();
    expect(NoteRepository(target).byId('same')!.rawContent, '必须保密的修改');
  });
  test('现有业务行不补齐缺少的创建事实，局部/删除/恢复都等待基线', () {
    final original = create();
    target.withoutSyncCapture(() => NoteRepository(target).insert(
        original.copyWith(rawContent: '本机旧行')));
    for (final op in [change('raw_content', '局部修改', 100),
      change(Operation.tombstoneField, true, 101),
      change(Operation.restoreField, true, 102)]) {
      receive([op]); SyncProjector(target).project();
      final waiting = NoteRepository(target).byId('same')!;
      expect(waiting.rawContent, '本机旧行');
      expect(waiting.deletedAt, isNull);
    }
    receive(facts(source)); SyncProjector(target).project();
    expect(NoteRepository(target).byId('same')!.rawContent, '局部修改');
    expect(NoteRepository(target).byId('same')!.deletedAt, isNull);
  });
  test('墓碑与恢复正序反序和单批到达的最终投影一致', () {
    create();
    final tomb = change(Operation.tombstoneField, true, 100);
    final restore = change(Operation.restoreField, true, 101);
    for (final batches in [ [[tomb], [restore]], [[restore], [tomb]], [[restore, tomb]] ]) {
      target.raw.execute('DELETE FROM notes');
      target.raw.execute('DELETE FROM sync_operations');
      target.raw.execute('DELETE FROM search_index');
      receive(facts(source));
      for (final batch in batches) {
        receive(batch); SyncProjector(target).project();
      }
      expect(NoteRepository(target).byId('same')!.deletedAt, isNull);
      expect(target.raw.select('SELECT text FROM search_index').single['text'],
          '便签标题\n原始文本');
    }
  });
  test('相同HLC毫秒和计数用作者排序，不依赖到达顺序或opId', () {
    create();
    for (final writers in [['zzz', 'aaa'], ['aaa', 'zzz']]) {
      target.raw.execute('DELETE FROM notes');
      target.raw.execute('DELETE FROM search_index');
      target.raw.execute('DELETE FROM sync_operations');
      receive(facts(source));
      for (final writer in writers) {
        SyncInbox(target).storeVerifiedBatch(peerId: writer, operations: [Operation(
          opId: writer == 'zzz' ? 'a-operation' : 'z-operation', deviceId: writer,
          hlc: Hlc(millis: DateTime.utc(2026, 10, 25).millisecondsSinceEpoch,
              counter: 100, deviceId: writer), objectType: 'note', objectId: 'same',
          field: 'raw_content', value: writer)]);
        SyncProjector(target).project();
      }
      expect(NoteRepository(target).byId('same')!.rawContent, 'zzz');
    }
  });
}
