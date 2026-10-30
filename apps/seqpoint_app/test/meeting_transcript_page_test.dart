import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/meetings/meeting_transcript_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  testWidgets('转写先预览，取消不写入，正文变化拒绝旧确认', (tester) async {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final notes = NoteService(db: db, notes: NoteRepository(db),
      items: ItemRepository(db), activities: ActivityRepository(db));
    final note = notes.capture('原文');
    await tester.pumpWidget(MaterialApp(home: MeetingTranscriptPage(
      database: db, noteId: note.id, noteService: notes)));
    await tester.enterText(find.byType(TextField), '会议文字');
    await tester.tap(find.text('预览导入'));
    await tester.pumpAndSettle();
    expect(NoteRepository(db).byId(note.id)!.rawContent, '原文');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(NoteRepository(db).byId(note.id)!.rawContent, '原文');
    await tester.tap(find.text('预览导入'));
    await tester.pumpAndSettle();
    notes.editContent(note.id, '用户改稿');
    await tester.tap(find.text('追加原文'));
    await tester.pumpAndSettle();
    expect(NoteRepository(db).byId(note.id)!.rawContent, '用户改稿');
    expect(find.textContaining('便签已变化'), findsOneWidget);
  });
}
