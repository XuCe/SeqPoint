import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/note_editor.dart';

void main() {
  testWidgets('小便签编辑时底部媒体按钮同排，附件管理可展开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 268));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('小窗口正文\n第二行待办');
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppScope(
        noteService: boot.noteService, notes: boot.notes, items: boot.items,
        tags: boot.tags, search: boot.search, database: boot.db, child: child!),
      home: Builder(builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push<String>(MaterialPageRoute(
          builder: (_) => NoteEditor(noteId: note.id))),
        child: const Text('编辑'))),
    ));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TextField)).height, greaterThanOrEqualTo(100));
    final photo = find.byIcon(Icons.image_outlined);
    final mic = find.byIcon(Icons.graphic_eq_rounded);
    expect(tester.getCenter(photo).dy, tester.getCenter(mic).dy);
    expect(find.text('导入转写'), findsNothing);
    await tester.tap(find.byTooltip('管理附件与转写'));
    await tester.pumpAndSettle();
    expect(find.text('导入转写'), findsOneWidget);
    Navigator.of(tester.element(find.text('导入转写'))).pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '小窗口修改后的正文');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.byId(note.id)!.rawContent, '小窗口修改后的正文');
    expect(tester.takeException(), isNull);
  });
}
