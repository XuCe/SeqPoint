import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService notes;
  late MeetingTranscriptService transcripts;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    notes = NoteService(db: db, notes: NoteRepository(db), items: ItemRepository(db),
      activities: ActivityRepository(db));
    transcripts = MeetingTranscriptService(db: db, notes: notes);
  });
  tearDown(() => db.close());

  test('导入先预览不写库，确认才追加原文且可被现有整理读取', () {
    final note = notes.capture('原始记录');
    final draft = transcripts.prepare(note.id, '  明天下午开会\n确认预算  ');
    expect(NoteRepository(db).byId(note.id)!.rawContent, '原始记录');
    expect(draft.text, '明天下午开会\n确认预算');
    final result = transcripts.apply(draft);
    expect(result.rawContent, '原始记录\n\n会议转写（手动导入，待校对）\n明天下午开会\n确认预算');
    expect(() => transcripts.apply(draft), throwsStateError);
  });

  test('预览期间便签变化或删除时拒绝旧内容，不覆盖当前正文', () {
    final note = notes.capture('原文');
    final draft = transcripts.prepare(note.id, '会议内容');
    notes.editContent(note.id, '用户改稿');
    expect(() => transcripts.apply(draft), throwsStateError);
    expect(NoteRepository(db).byId(note.id)!.rawContent, '用户改稿');
    final latest = transcripts.prepare(note.id, '会议内容');
    notes.trash(note.id);
    expect(() => transcripts.apply(latest), throwsStateError);
  });

  test('空白、超限、无归属文本拒绝且不新增便签', () {
    final note = notes.capture('原文');
    expect(() => transcripts.prepare(note.id, '  '), throwsArgumentError);
    expect(() => transcripts.prepare(note.id, '字' * 50001), throwsArgumentError);
    expect(() => transcripts.prepare('missing', '文本'), throwsStateError);
    expect(NoteRepository(db).active(), hasLength(1));
  });
}
