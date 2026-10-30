import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  late SeqDatabase db;
  late FakeClock clock;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate(); clock = FakeClock(DateTime.utc(2026, 10, 25));
  });
  tearDown(() => db.close());
  test('已有本机数据完整建基线后原子启用，逻辑名上wire且排除本机元数据', () {
    NoteRepository(db).insert(Note(id: 'n1', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '存量原文', window: const NoteWindow(x: 1, y: 2, w: 300, h: 400),
        createdAt: clock.now(), updatedAt: clock.now()));
    final item = ItemRepository(db).insert(Item(id: 'i1', noteId: 'n1', title: '存量事项',
        status: ItemStatus.todo, priority: Priority.p1, source: ItemSource.manual,
        sourceRef: const SourceRef(noteId: 'private-ref'), createdAt: clock.now(), updatedAt: clock.now()));
    final tag = TagRepository(db).upsert(name: '派生显示名', kind: TagKind.project);
    db.raw.execute('UPDATE tags SET logical_name=? WHERE id=?', ['业务原名', tag.id]);
    ItemRepository(db).addTag(item.id, tag.id);
    expect(facts(db), isEmpty);
    final count = SyncBaseline(db, clock: clock).initialize('writer');
    final operations = facts(db);
    expect(count, operations.length); expect(count, greaterThan(0));
    expect(operations.map((op) => op.objectType).toSet(), {'note', 'item', 'tag', 'item_tag'});
    expect(operations.singleWhere((op) => op.objectType == 'tag' && op.field == 'name').value, '业务原名');
    expect(operations.map((op) => op.field), isNot(contains('logical_name')));
    expect(operations.map((op) => op.field), isNot(contains('window_json')));
    expect(operations.map((op) => op.field), isNot(contains('source_ref_json')));
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['enabled'], 1); expect(state['baseline_ready'], 1);
    expect(state['device_id'], 'writer'); expect(state['pending_count'], 0);
    expect(NoteRepository(db).byId('n1')!.window!.x, 1);
    expect(ItemRepository(db).byId('i1')!.sourceRef!.noteId, 'private-ref');
    final ids = operations.map((op) => op.opId).toList();
    expect(SyncBaseline(db, clock: clock).initialize('writer'), 0);
    expect(facts(db).map((op) => op.opId), ids);
  });
  test('空库也持久ready并幂等，不能切writer或关闭后静默重新启用', () {
    final baseline = SyncBaseline(db, clock: clock);
    expect(baseline.initialize('writer'), 0);
    expect(db.raw.select('SELECT baseline_ready FROM sync_local').single['baseline_ready'], 1);
    expect(baseline.initialize('writer'), 0);
    expect(() => baseline.initialize('other'), throwsStateError);
    db.raw.execute('UPDATE sync_local SET enabled=0');
    expect(() => baseline.initialize('writer'), throwsStateError);
    expect(facts(db), isEmpty);
  });
  test('归档和回收站/软删事项均入基线，删除对象仅墓碑而非明确恢复', () {
    final notes = NoteRepository(db);
    for (final id in ['closed', 'deleted']) {
      notes.insert(Note(id: id, kind: NoteKind.text,
          status: id == 'closed' ? NoteStatus.closed : NoteStatus.active, rawContent: id,
          closedAt: id == 'closed' ? clock.now() : null, deletedAt: id == 'deleted' ? clock.now() : null,
          createdAt: clock.now(), updatedAt: clock.now()));
    }
    ItemRepository(db).insert(Item(id: 'deleted-item', noteId: 'deleted', title: '旧事项',
        status: ItemStatus.done, priority: Priority.p4, source: ItemSource.manual,
        deletedAt: clock.now(), completedAt: clock.now(), createdAt: clock.now(), updatedAt: clock.now()));
    SyncBaseline(db, clock: clock).initialize('writer');
    expect(facts(db).map((op) => op.objectId).toSet(), {'closed', 'deleted', 'deleted-item'});
    for (final id in ['deleted', 'deleted-item']) {
      final fields = facts(db).where((op) => op.objectId == id).map((op) => op.field);
      expect(fields, contains(Operation.tombstoneField)); expect(fields, isNot(contains(Operation.restoreField)));
    }
    expect(notes.byId('closed')!.isClosed, isTrue); expect(notes.byId('deleted')!.deletedAt, isNotNull);
  });
  test('生成中途拒写回滚启用/ready/操作/时钟，不改原业务，修复后可重试', () {
    NoteRepository(db).insert(Note(id: 'n1', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '保留原文', createdAt: clock.now(), updatedAt: clock.now()));
    db.raw.execute('CREATE TEMP TRIGGER reject_seed BEFORE INSERT ON sync_operations '
        "WHEN NEW.field='raw_content' BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => SyncBaseline(db, clock: clock).initialize('writer'), throwsStateError);
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['enabled'], 0); expect(state['baseline_ready'], 0); expect(state['device_id'], isNull);
    expect(state['hlc_millis'], 0); expect(facts(db), isEmpty);
    expect(NoteRepository(db).byId('n1')!.rawContent, '保留原文');
    db.raw.execute('DROP TRIGGER reject_seed');
    expect(SyncBaseline(db, clock: clock).initialize('writer'), greaterThan(0));
  });
  test('坏writer/调用方事务/恢复须换身份均不能绕过首次启用', () {
    final baseline = SyncBaseline(db, clock: clock);
    for (final id in ['', 'bad/id', 'writer\n', 'a' * 129]) {
      expect(() => baseline.initialize(id), throwsStateError);
    }
    expect(() => db.transaction(() => baseline.initialize('writer')), throwsStateError);
    db.disconnectSyncForRestore();
    expect(() => baseline.initialize('writer'), throwsStateError);
    expect(db.raw.select('SELECT requires_new_identity FROM sync_local').single['requires_new_identity'], 1);
    expect(db.raw.select('SELECT enabled FROM sync_local').single['enabled'], 0);
    expect(facts(db), isEmpty);
  });
  test('关闭但有历史时拒绝清空/伪重启，原事实和公开状态保留', () {
    db.raw.execute('INSERT INTO sync_operations '
        '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
        "VALUES ('old','writer',1,0,'note','n1','raw_content',?,'local')", ['"旧事实"']);
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(() => SyncBaseline(db, clock: clock).initialize('writer'), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_local').single, state);
    expect(facts(db).single.opId, 'old');
    expect(facts(db).single.value, '旧事实');
  });
}
