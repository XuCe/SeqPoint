import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/meetings/meeting_panel.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _Attachments extends Fake implements AttachmentService {
  _Attachments(this.name);
  final String name;
  @override
  List<Attachment> list({String? noteId, String? itemId, String media = 'image'}) => [
    Attachment(id: 'id', fileName: name, mime: 'audio/mp4', byteSize: 20,
      sha256: '', createdAt: DateTime.now(), media: 'audio'),
  ];
}

void main() {
  testWidgets('同一面板换数据库和服务后显示新录音', (tester) async {
    final first = SeqDatabase.inMemory()..migrate();
    final second = SeqDatabase.inMemory()..migrate();
    addTearDown(first.close);
    addTearDown(second.close);
    Widget panel(SeqDatabase db, AttachmentService service) => MaterialApp(
      home: Scaffold(body: MeetingPanel(database: db, noteId: 'note', service: service,
        noteService: NoteService(db: db, notes: NoteRepository(db),
          items: ItemRepository(db), activities: ActivityRepository(db)))));
    await tester.pumpWidget(panel(first, _Attachments('旧库录音')));
    await tester.pumpAndSettle();
    expect(find.text('旧库录音'), findsOneWidget);
    await tester.pumpWidget(panel(second, _Attachments('新库录音')));
    await tester.pumpAndSettle();
    expect(find.text('新库录音'), findsOneWidget);
    expect(find.text('旧库录音'), findsNothing);
  });
}
