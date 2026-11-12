import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/note_editor.dart';
import 'package:seqpoint_app/shared/note_markdown_field.dart';
import 'package:seqpoint_app/theme/seq_tokens.dart';

void main() {
  testWidgets('宽窗暗色主题下，正文和提示左对齐，纸面空白处也能接着写', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1264, 710));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = MarkdownEditorController(text: 'qwe');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(), home: Scaffold(
      backgroundColor: SeqTokens.noteYellow,
      body: Padding(padding: const EdgeInsets.all(14), child: NoteMarkdownField(controller: controller)),
    )));
    await tester.pump();
    final editable = tester.widget<MarkdownEditableText>(find.byType(MarkdownEditableText));
    expect(editable.style.color, SeqTokens.noteInk);
    final render = tester.allRenderObjects.whereType<RenderMarkdownEditable>().single;
    expect(render.text.style?.color, SeqTokens.noteInk);
    final caret = render.getLocalRectForCaret(const TextPosition(offset: 0));
    expect(render.localToGlobal(caret.topLeft).dx, closeTo(14, 1));
    final content = tester.getRect(find.byKey(const Key('markdown-content')));
    expect(content.left, 14);
    expect(content.right, 1250);
    editable.focusNode.unfocus();
    await tester.pump();
    await tester.tapAt(const Offset(1210, 520));
    await tester.pump();
    expect(editable.focusNode.hasFocus, isTrue);
    expect(controller.selection.extentOffset, 3);
    await tester.tapAt(const Offset(15, 22));
    await tester.pump();
    expect(controller.selection.extentOffset, 0);
    tester.testTextInput.enterText('qwe 中文');
    await tester.pump();
    expect(controller.text, 'qwe 中文');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小便签编辑时底部媒体按钮同排，附件管理可展开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 268));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('小窗口正文\n第二行待办', title: '采购');
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
    expect(tester.getSize(find.byType(LiveMarkdownEditor)).height, greaterThanOrEqualTo(100));
    expect(find.text('采购'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '标题（选填）'), '周末采购');
    final photo = find.byIcon(Icons.image_outlined);
    final mic = find.byIcon(Icons.graphic_eq_rounded);
    expect(tester.getCenter(photo).dy, tester.getCenter(mic).dy);
    expect(find.text('导入转写'), findsNothing);
    await tester.tap(find.byTooltip('管理附件与转写'));
    await tester.pumpAndSettle();
    expect(find.text('导入转写'), findsOneWidget);
    Navigator.of(tester.element(find.text('导入转写'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LiveMarkdownEditor));
    tester.testTextInput.enterText('小窗口修改后的正文');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.byId(note.id)!.rawContent, '小窗口修改后的正文');
    expect(boot.notes.byId(note.id)!.title, '周末采购');
    expect(tester.takeException(), isNull);
  });
}
