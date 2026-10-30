import 'dart:io';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('恢复旧SQLite及回滚保护副本仍能读取原有附件字节', () async {
    final root = await Directory.systemTemp.createTemp('seqpoint-media-retain-');
    final db = SeqDatabase.inMemory()..migrate();
    final media = Directory('${root.path}/attachments');
    final now = DateTime.now();
    final note = NoteRepository(db).insert(Note(id: '', kind: NoteKind.text,
      status: NoteStatus.active, rawContent: '保留照片', createdAt: now, updatedAt: now));
    final service = AttachmentService(db: db, directory: media);
    final bytes = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);
    final first = await service.addImage(bytes, noteId: note.id);
    db.raw.execute('VACUUM INTO ?', ['${root.path}/older.sqlite']);
    final recent = await service.addImage(bytes, noteId: note.id);
    db.raw.execute('VACUUM INTO ?', ['${root.path}/protection.sqlite']);
    final older = SeqDatabase.open('${root.path}/older.sqlite');
    final protection = SeqDatabase.open('${root.path}/protection.sqlite');
    addTearDown(() async {
      older.close(); protection.close(); db.close();
      await root.delete(recursive: true);
    });
    await service.remove(first.id);
    expect(service.list(noteId: note.id).map((a) => a.id), [recent.id]);
    final restored = AttachmentService(db: older, directory: media);
    expect(restored.list(noteId: note.id).single.id, first.id);
    expect(await restored.cleanupOrphans(), 0);
    expect(await (await restored.file(first.id)).readAsBytes(), bytes);
    final rolledBack = AttachmentService(db: protection, directory: media);
    expect(rolledBack.list(noteId: note.id), hasLength(2));
    expect(await (await rolledBack.file(first.id)).readAsBytes(), bytes);
    expect(await (await rolledBack.file(recent.id)).readAsBytes(), bytes);
  });
}
