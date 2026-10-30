import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/meetings/recording_session.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'meeting_test_recorder.dart';
import 'meeting_paused_attachments.dart';

void main() {
  late SeqDatabase db;
  late Directory root;
  late TestRecorder recorder;
  late RecordingSession session;
  late AttachmentService attachments;
  late String noteId;
  setUp(() async {
    db = SeqDatabase.inMemory()..migrate();
    root = await Directory.systemTemp.createTemp('seqpoint-recording-test-');
    final now = DateTime.now();
    noteId = NoteRepository(db).insert(Note(id: '', kind: NoteKind.text,
      status: NoteStatus.active, rawContent: '会议', createdAt: now, updatedAt: now)).id;
    attachments = AttachmentService(db: db, directory: Directory('${root.path}/attachments'));
    recorder = TestRecorder();
    session = RecordingSession(recorder: recorder, attachments: attachments,
      noteId: noteId, temporaryDirectory: root);
  });
  tearDown(() async { await session.dispose(); db.close(); await root.delete(recursive: true); });

  test('开始无记录，停止后保存本机音频关联，清理临时录音', () async {
    await session.start();
    expect(session.recording, isTrue);
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
    final image = await session.save();
    expect(image.media, 'audio');
    expect(session.recording, isFalse);
    expect(await File(recorder.path!).exists(), isFalse);
    expect(attachments.list(noteId: noteId, media: 'audio'), hasLength(1));
  });

  test('权限拒绝与取消不生成附件且清理临时文件', () async {
    recorder.permission = false;
    await expectLater(session.start(), throwsStateError);
    expect(recorder.starts, 0);
    recorder.permission = true;
    await session.start();
    final path = recorder.path!;
    await session.cancel();
    expect(await File(path).exists(), isFalse);
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
  });

  test('保存失败保留临时录音供重试，重试成功只创建一个附件', () async {
    await session.start();
    db.raw.execute('CREATE TRIGGER reject_audio BEFORE INSERT ON attachments '
      "BEGIN SELECT RAISE(ABORT, 'blocked'); END;");
    await expectLater(session.save(), throwsA(anything));
    expect(session.hasDraft, isTrue);
    expect(await File(recorder.path!).exists(), isTrue);
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_audio');
    await session.save();
    expect(attachments.list(noteId: noteId, media: 'audio'), hasLength(1));
  });

  test('停止失败不假报保存，取消后清理草稿', () async {
    await session.start();
    recorder.stopFails = true;
    await expectLater(session.save(), throwsStateError);
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
    expect(session.hasDraft, isTrue);
    await session.cancel();
    expect(await File(recorder.path!).exists(), isFalse);
  });

  test('保存异步等待期间取消，迟到保存不生成附件', () async {
    await session.dispose();
    final paused = PausedAttachments(db: db, directory: attachments.directory);
    session = RecordingSession(attachments: paused, noteId: noteId,
      temporaryDirectory: root, recorder: recorder);
    await session.start();
    final saving = session.save();
    await paused.reached.future;
    await session.cancel();
    paused.release.complete();
    await expectLater(saving, throwsStateError);
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
    expect(await attachments.directory.list().length, 0);
  });

  test('原生取消等待期间拒绝保存和重启，重复取消串行', () async {
    await session.start();
    recorder.cancelPending = Completer<void>();
    final cancel = session.cancel();
    final again = session.cancel();
    try {
      expect(session.busy, isTrue);
      await expectLater(session.save(), throwsStateError);
      await expectLater(session.start(), throwsStateError);
      expect(recorder.cancellations, 1);
    } finally {
      recorder.cancelPending!.complete();
      await Future.wait([cancel, again]);
    }
    expect(attachments.list(noteId: noteId, media: 'audio'), isEmpty);
  });
}
