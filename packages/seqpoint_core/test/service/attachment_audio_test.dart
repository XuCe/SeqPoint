import 'dart:io';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('录音复用受管存储，仅接受有M4A头的有界音频', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final dir = await Directory.systemTemp.createTemp('seqpoint-audio-');
    addTearDown(() async { db.close(); await dir.delete(recursive: true); });
    final now = DateTime.now();
    final note = NoteRepository(db).insert(Note(id: '', kind: NoteKind.text,
      status: NoteStatus.active, rawContent: '会议', createdAt: now, updatedAt: now));
    final service = AttachmentService(db: db, directory: dir);
    final bytes = Uint8List.fromList([0, 0, 0, 20, 102, 116, 121, 112,
      77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]);
    final recording = await service.addAudio(bytes, noteId: note.id, name: '会议.m4a');
    expect(recording.media, 'audio');
    expect(recording.mime, 'audio/mp4');
    expect(service.list(noteId: note.id), isEmpty);
    expect(service.list(noteId: note.id, media: 'audio').single.id, recording.id);
    await expectLater(service.addAudio(Uint8List.fromList([1, 2]), noteId: note.id),
      throwsArgumentError);
    await expectLater(service.addAudio(Uint8List(AttachmentService.maxAudioBytes + 1),
      noteId: note.id), throwsArgumentError);
    expect(service.list(noteId: note.id, media: 'audio'), hasLength(1));
    await expectLater(service.addAudio(bytes, noteId: note.id,
      canCommit: () => false), throwsStateError);
    expect(service.list(noteId: note.id, media: 'audio'), hasLength(1));
    expect(await dir.list().length, 1);
    await service.remove(recording.id);
    expect(await (await service.file(recording.id)).exists(), isTrue);
  });
}
