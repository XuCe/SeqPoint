import 'dart:io';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 0]);

void main() {
  late SeqDatabase db;
  late Directory root;
  late AttachmentService service;
  late String noteId;
  setUp(() async {
    db = SeqDatabase.inMemory()..migrate();
    root = await Directory.systemTemp.createTemp('seqpoint-attachments-');
    final now = DateTime.utc(2026, 10, 26);
    noteId = NoteRepository(db)
        .insert(
          Note(
            id: '',
            kind: NoteKind.text,
            status: NoteStatus.active,
            rawContent: '照片',
            createdAt: now,
            updatedAt: now,
          ),
        )
        .id;
    service = AttachmentService(db: db, directory: root);
  });
  tearDown(() async {
    db.close();
    await root.delete(recursive: true);
  });

  test('图片写入受管路径并关联便签，原文件名不参与路径', () async {
    final image = await service.addImage(
      png,
      noteId: noteId,
      name: '../../holiday.png',
    );
    expect(image.noteId, noteId);
    expect(image.fileName, 'holiday.png');
    expect(image.mime, 'image/png');
    expect(image.byteSize, png.length);
    expect(await (await service.file(image.id)).readAsBytes(), png);
    expect(service.list(noteId: noteId).single.id, image.id);
    expect(image.sha256, hasLength(64));
  });

  test('支持 JPEG GIF WebP 并按内容识别类型', () async {
    for (final (bytes, mime) in [
      ([255, 216, 255, 224], 'image/jpeg'),
      ([71, 73, 70, 56, 57, 97], 'image/gif'),
      ([82, 73, 70, 70, 1, 0, 0, 0, 87, 69, 66, 80], 'image/webp'),
    ]) {
      final image = await service.addImage(
        Uint8List.fromList(bytes),
        noteId: noteId,
        name: 'wrong.exe',
      );
      expect(image.mime, mime);
    }
  });

  test('无效内容、超限、缺失归属不留下记录或文件', () async {
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([1, 2]),
      Uint8List(AttachmentService.maxImageBytes + 1),
    ]) {
      await expectLater(
        service.addImage(bytes, noteId: noteId),
        throwsArgumentError,
      );
    }
    await expectLater(service.addImage(png), throwsArgumentError);
    await expectLater(
      service.addImage(png, noteId: 'missing'),
      throwsStateError,
    );
    expect(db.raw.select('SELECT * FROM attachments'), isEmpty);
    expect(await root.list().toList(), isEmpty);
  });

  test('数据库失败清理已复制文件', () async {
    db.raw.execute(
      'CREATE TRIGGER reject_image BEFORE INSERT ON attachments '
      "BEGIN SELECT RAISE(ABORT, 'blocked'); END;",
    );
    await expectLater(service.addImage(png, noteId: noteId), throwsA(anything));
    expect(await root.list().toList(), isEmpty);
    expect(db.raw.select('SELECT * FROM attachments'), isEmpty);
  });

  test('删除隐藏记录但保留文件，未知快照引用时不回收孤儿', () async {
    final removed = await service.addImage(png, noteId: noteId);
    final orphan = await service.addImage(png, noteId: noteId);
    final removedFile = await service.file(removed.id);
    final orphanFile = await service.file(orphan.id);
    await service.remove(removed.id);
    expect(await removedFile.exists(), isTrue);
    expect(service.list(noteId: noteId).single.id, orphan.id);
    db.raw.execute('DELETE FROM notes WHERE id = ?', [noteId]);
    expect(await service.cleanupOrphans(), 0);
    expect(await orphanFile.exists(), isTrue);
  });

  test('安全边界拒绝目录/文件符号链接及路径穿越', () async {
    await expectLater(service.file('../outside'), throwsArgumentError);
    final outside = await Directory.systemTemp.createTemp('seqpoint-outside-');
    addTearDown(() => outside.delete(recursive: true));
    final linked = Directory('${root.path}/linked');
    await Link(linked.path).create(outside.path);
    await expectLater(
      AttachmentService(
        db: db,
        directory: linked,
      ).addImage(png, noteId: noteId),
      throwsStateError,
    );
    final image = await service.addImage(png, noteId: noteId);
    final target = await service.file(image.id);
    await target.delete();
    final other = await File('${outside.path}/private').writeAsString('保留');
    await Link(target.path).create(other.path);
    await expectLater(service.file(image.id), throwsStateError);
    expect(await other.readAsString(), '保留');
  });

  test('图片可以只关联事项，清理保留活跃附件与无关文件', () async {
    final notes = NoteService(db: db, notes: NoteRepository(db),
      items: ItemRepository(db), activities: ActivityRepository(db));
    final item = notes.lineToItem(noteId, 0);
    final image = await service.addImage(png, itemId: item.id);
    expect(image.itemId, item.id);
    expect(image.noteId, isNull);
    expect(service.list(noteId: noteId), isEmpty);
    expect(service.list(itemId: item.id).single.id, image.id);
    final unrelated = await File('${root.path}/keep.txt').writeAsString('保留');
    expect(await service.cleanupOrphans(), 0);
    expect(await unrelated.readAsString(), '保留');
    expect(await (await service.file(image.id)).exists(), isTrue);
    await expectLater(service.addImage(png, noteId: noteId, itemId: item.id),
      throwsArgumentError);
  });
}
