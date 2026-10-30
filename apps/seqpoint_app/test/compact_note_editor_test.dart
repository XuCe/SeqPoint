import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/note_editor.dart';

void main() {
  testWidgets('小便签编辑时正文保留可用高度，附件区域可滚动', (tester) async {
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
    expect(tester.getSize(find.byType(EditableText)).height, greaterThanOrEqualTo(48));
    expect(find.byType(SingleChildScrollView), findsWidgets);
    await tester.enterText(find.byType(TextField), '小窗口修改后的正文');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.byId(note.id)!.rawContent, '小窗口修改后的正文');
    expect(tester.takeException(), isNull);
  });
}
