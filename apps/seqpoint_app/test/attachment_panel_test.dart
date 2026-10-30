import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/attachments/attachment_panel.dart';
import 'package:seqpoint_app/features/attachments/attachment_picker.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _ObservedAttachmentService extends AttachmentService {
  _ObservedAttachmentService({required super.db, required super.directory});

  int cleanupCalls = 0;
  Future<void>? removal;

  @override
  Future<int> cleanupOrphans({Set<String>? recoverableIds}) {
    cleanupCalls++;
    return super.cleanupOrphans(recoverableIds: recoverableIds);
  }

  @override
  Future<void> remove(String id) => removal = super.remove(id);
}

void main() {
  testWidgets('取消选择不生成附件，选择失败有反馈且可重试', (tester) async {
    final db = SeqDatabase.inMemory()..migrate();
    final root = Directory.systemTemp.createTempSync('seqpoint-panel-');
    addTearDown(() {
      db.close();
      root.deleteSync(recursive: true);
    });
    final now = DateTime.now();
    final note = NoteRepository(db).insert(
      Note(
        id: '',
        kind: NoteKind.text,
        status: NoteStatus.active,
        rawContent: '照片',
        createdAt: now,
        updatedAt: now,
      ),
    );
    var fail = false;
    final service = _ObservedAttachmentService(db: db, directory: root);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentPanel(
              database: db,
              noteId: note.id,
              service: service,
              picker: AttachmentPicker(
                select: () async {
                  if (fail) {
                    throw const FileSystemException('permission denied');
                  }
                  return null;
                },
              ),
            ),
          ),
        ),
      );
      expect(service.cleanupCalls, 0);
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加图片'));
    await tester.pumpAndSettle();
    expect(db.raw.select('SELECT * FROM attachments'), isEmpty);
    fail = true;
    await tester.tap(find.text('添加图片'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法添加图片'), findsOneWidget);
    expect(find.text('添加图片'), findsOneWidget);
  });

  testWidgets('已保存图片显示缩略图、预览、删除闭环', (tester) async {
    final db = SeqDatabase.inMemory()..migrate();
    final root = Directory.systemTemp.createTempSync('seqpoint-gallery-');
    addTearDown(() {
      db.close();
      root.deleteSync(recursive: true);
    });
    final now = DateTime.now();
    final note = NoteRepository(db).insert(
      Note(
        id: '',
        kind: NoteKind.text,
        status: NoteStatus.active,
        rawContent: '照片',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final service = _ObservedAttachmentService(db: db, directory: root);
    final image = (await tester.runAsync(
      () => service.addImage(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
        ),
        noteId: note.id,
        name: 'photo.png',
      ),
    ))!;
    final target = (await tester.runAsync(() => service.file(image.id)))!;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentPanel(
              database: db,
              noteId: note.id,
              service: service,
            ),
          ),
        ),
      );
      expect(service.cleanupCalls, 0);
      await tester.pump();
      await tester
          .widget<FutureBuilder<File>>(find.byType(FutureBuilder<File>))
          .future!;
      await tester.pump();
    });
    expect(find.text('photo.png'), findsOneWidget);
    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('删除图片'));
      await service.removal;
    });
    await tester.pumpAndSettle();
    expect(service.list(noteId: note.id), isEmpty);
    expect(target.existsSync(), isTrue);
  });
}
