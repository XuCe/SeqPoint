import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/features/attachments/attachment_panel.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  testWidgets('同步元数据和原文件分别到达时原页面即时刷新', (tester) async {
    final db=SeqDatabase.inMemory()..migrate();
    final root=Directory.systemTemp.createTempSync('media-refresh-');
    addTearDown(() {db.close();root.deleteSync(recursive:true);});
    final notes=NoteRepository(db), items=ItemRepository(db);
    final service=NoteService(db:db,notes:notes,items:items,activities:ActivityRepository(db));
    final note=service.capture('同步图片');
    final attachments=AttachmentService(db:db,directory:root);
    Widget screen(int revision)=>MaterialApp(home:AppScope(
      noteService:service,notes:notes,items:items,tags:TagRepository(db),
      search:SearchService(db),database:db,syncRevision:revision,
      child:Scaffold(body:AttachmentPanel(database:db,noteId:note.id,service:attachments))));
    await tester.pumpWidget(screen(0));
    await tester.pumpAndSettle();
    final bytes=base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=');
    late File file;
    await tester.runAsync(() async {
      final attachment=await attachments.addImage(bytes,noteId:note.id,name:'remote.png');
      file=await attachments.file(attachment.id);
      db.raw.execute("UPDATE attachments SET sync='trusted_devices' WHERE id=?",[attachment.id]);
      await file.delete();
      await tester.pumpWidget(screen(1));
      await tester.pump();
      await tester.widget<FutureBuilder<File>>(find.byType(FutureBuilder<File>)).future!;
      await tester.pump();
    });
    expect(find.text('remote.png'),findsOneWidget);
    expect(find.text('等待原文件同步'),findsOneWidget);
    await tester.runAsync(() async {
      await file.writeAsBytes(bytes);
      await tester.pumpWidget(screen(2));
      await tester.pump();
      await tester.widget<FutureBuilder<File>>(find.byType(FutureBuilder<File>)).future!;
      await tester.pump();
    });
    expect(find.text('等待原文件同步'),findsNothing);
    expect(find.byType(Image),findsOneWidget);
  });
}
