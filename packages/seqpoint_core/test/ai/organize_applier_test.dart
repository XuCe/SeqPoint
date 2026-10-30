import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late Note note;
  final now = DateTime.utc(2026, 10, 25, 12);
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    TagRepository(db).ensureBuiltins();
    note = NoteRepository(db).insert(Note(id: 'note', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '回复客户\n整理文档', createdAt: now, updatedAt: now));
  });
  tearDown(() => db.close());
  test('只采纳勾选项，保存字段/标签/活动且原文不变，重复采纳幂等', () {
    final due = now.add(const Duration(days: 1));
    final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: [
      ProposedItem(id: 'candidate-a', title: '报价回复', lineIndex: 0, dueAt: due, important: true,
          typeTagName: '沟通', projectTagName: '项目A'),
      const ProposedItem(id: 'candidate-b', title: '文档', lineIndex: 1, accepted: false),
    ]);
    final applier = OrganizeApplier(db, clock: FakeClock(now));
    final created = applier.apply(proposal);
    expect(created, hasLength(1));
    final item = ItemRepository(db).byId('candidate-a')!;
    expect(item.title, '报价回复'); expect(item.noteId, note.id); expect(item.lineIndex, 0);
    expect(item.dueAt, due); expect(item.priority, Priority.p1); expect(item.source, ItemSource.ai);
    expect(ItemRepository(db).byId('candidate-b'), isNull);
    final names = ItemRepository(db).tagIdsOf(item.id).map((id) => TagRepository(db).byId(id)!.name);
    expect(names.toSet(), {'沟通', '项目A'});
    expect(NoteRepository(db).byId(note.id)!.rawContent, note.rawContent);
    expect(applier.apply(proposal), isEmpty);
    final activities = ActivityRepository(db).forObject('note', note.id);
    expect(activities, hasLength(1)); expect(activities.single.action, ActivityAction.aiOrganizeApplied);
    expect(jsonDecode(activities.single.newValue!), ['candidate-a']);
  });
  test('未勾选任何候选不开始事务或写活动', () {
    final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0, accepted: false)]);
    expect(db.transaction(() => OrganizeApplier(db).apply(proposal)), isEmpty);
    expect(ActivityRepository(db).recent(), isEmpty);
  });
  for (final state in ['正文变化', '已删除', '不存在']) {
    test('$state 时拒绝陈旧提案并保留原有数据', () {
      final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
        ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
      if (state == '正文变化') NoteRepository(db).update(note.copyWith(rawContent: '新正文'));
      if (state == '已删除') NoteRepository(db).update(note.copyWith(deletedAt: now));
      if (state == '不存在') db.raw.execute('DELETE FROM notes WHERE id=?', [note.id]);
      expect(() => OrganizeApplier(db).apply(proposal), throwsStateError);
      expect(ItemRepository(db).byNote(note.id), isEmpty);
      expect(ActivityRepository(db).recent(), isEmpty);
    });
  }
  for (final candidate in [
    const ProposedItem(id: '', title: '事项', lineIndex: 1),
    const ProposedItem(id: 'b', title: '  ', lineIndex: 1),
    const ProposedItem(id: 'b', title: '事项', lineIndex: 2),
    const ProposedItem(id: 'b', title: '事项'),
    const ProposedItem(id: 'b', title: '事项', lineIndex: 1, projectTagName: ''),
    const ProposedItem(id: 'b', title: '事项', lineIndex: 1, typeTagName: '未知类型'),
  ]) {
    test('直接采纳非法候选 ${candidate.id}/${candidate.lineIndex}/${candidate.title} 全批回滚', () {
      final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: [
        const ProposedItem(id: 'a', title: '有效', lineIndex: 0, projectTagName: '不应留下'), candidate]);
      expect(() => OrganizeApplier(db).apply(proposal), throwsStateError);
      expect(ItemRepository(db).byNote(note.id), isEmpty);
      expect(TagRepository(db).byName('不应留下', TagKind.project), isNull);
      expect(ActivityRepository(db).recent(), isEmpty);
    });
  }
  for (final table in ['items', 'tags', 'item_tags', 'activities']) {
    test('$table 写失败回滚事项、新标签、关联和活动', () {
      db.raw.execute('CREATE TRIGGER fail_write BEFORE INSERT ON $table '
          '${table == 'items' ? "WHEN NEW.id='b'" : ''} BEGIN SELECT RAISE(ABORT, \'injected\'); END');
      final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
        ProposedItem(id: 'a', title: '事项一', lineIndex: 0, projectTagName: '新项目'),
        ProposedItem(id: 'b', title: '事项二', lineIndex: 1),
      ]);
      expect(() => OrganizeApplier(db).apply(proposal), throwsA(anything));
      expect(ItemRepository(db).byNote(note.id), isEmpty);
      expect(TagRepository(db).byName('新项目', TagKind.project), isNull);
      expect(db.raw.select('SELECT * FROM item_tags'), isEmpty);
      expect(ActivityRepository(db).recent(), isEmpty);
      expect(NoteRepository(db).byId(note.id)!.rawContent, note.rawContent);
    });
  }
  test('候选ID被其他事项占用时整批拒绝，不能当已采纳吞掉冲突', () {
    NoteRepository(db).insert(Note(id: 'other-note', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '其他正文', createdAt: now, updatedAt: now));
    ItemRepository(db).insert(Item(id: 'collision', noteId: 'other-note', lineIndex: 0,
        title: '原事项', status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: now, updatedAt: now));
    final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
      ProposedItem(id: 'a', title: '事项一', lineIndex: 0, projectTagName: '新项目'),
      ProposedItem(id: 'collision', title: '事项二', lineIndex: 1),
    ]);
    expect(() => OrganizeApplier(db).apply(proposal), throwsStateError);
    expect(ItemRepository(db).byNote(note.id), isEmpty);
    expect(ItemRepository(db).byId('collision')!.title, '原事项');
    expect(TagRepository(db).byName('新项目', TagKind.project), isNull);
    expect(ActivityRepository(db).recent(), isEmpty);
  });
  for (final status in ItemStatus.values) {
    test('已有${status.name}事项的行再次整理不重复或复活', () {
      final existing = ItemRepository(db).insert(Item(id: 'existing', noteId: note.id, lineIndex: 0,
          title: '原事项', status: status, priority: Priority.p4, source: ItemSource.manual,
          createdAt: now, updatedAt: now));
      final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
        ProposedItem(id: 'new-candidate', title: '新标题', lineIndex: 0, projectTagName: '不应创建')]);
      expect(OrganizeApplier(db).apply(proposal), isEmpty);
      expect(ItemRepository(db).byNote(note.id).single.id, existing.id);
      expect(ItemRepository(db).byId(existing.id)!.status, status);
      expect(TagRepository(db).byName('不应创建', TagKind.project), isNull);
      expect(ActivityRepository(db).recent(), isEmpty);
    });
  }
  test('已采纳后再删除的候选重放不复活', () {
    final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
      ProposedItem(id: 'a', title: '事项', lineIndex: 0)]);
    OrganizeApplier(db).apply(proposal);
    final repository = ItemRepository(db);
    repository.update(repository.byId('a')!.copyWith(deletedAt: now));
    expect(OrganizeApplier(db).apply(proposal), isEmpty);
    expect(repository.byId('a')!.deletedAt, now);
    expect(ActivityRepository(db).forObject('note', note.id), hasLength(1));
  });
}
