import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/meetings/meeting_recording_page.dart';
import 'package:seqpoint_app/features/meetings/recording_session.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _Session extends Fake implements RecordingSession {
  @override bool recording = false;
  @override bool busy = false;
  @override bool get hasDraft => recording;
  int started = 0;
  int saved = 0;
  int canceled = 0;
  @override Future<void> start() async { started++; recording = true; }
  @override Future<Attachment> save() async {
    saved++; recording = false;
    return Attachment(id: 'id', mime: 'audio/mp4', byteSize: 20,
      sha256: '', createdAt: DateTime.now(), media: 'audio');
  }
  @override Future<void> cancel() async { canceled++; recording = false; }
  @override Future<void> dispose() async { recording = false; }
}

void main() {
  testWidgets('录音页只在点击开始后录音，停止保存后返回成功', (tester) async {
    final session = _Session();
    bool? saved;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () async {
        saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => MeetingRecordingPage(session: session)));
      }, child: const Text('打开录音'))))));
    await tester.tap(find.text('打开录音'));
    await tester.pumpAndSettle();
    expect(session.started, 0);
    await tester.tap(find.text('开始录音'));
    await tester.pump();
    expect(session.started, 1);
    await tester.tap(find.text('停止并保存'));
    await tester.pumpAndSettle();
    expect(session.saved, 1);
    expect(saved, isTrue);
  });
}
