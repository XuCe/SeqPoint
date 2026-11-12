import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/mobile/quick_capture_page.dart';

import 'note_editor_test_support.dart';

void main() {
  Future<Bootstrap> open(WidgetTester t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    await t.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScope(
          noteService: b.noteService,
          notes: b.notes,
          items: b.items,
          tags: b.tags,
          search: b.search,
          child: child!,
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .push<bool>(MaterialPageRoute(builder: (_) => const QuickCapturePage())),
            child: const Text('新建'),
          ),
        ),
      ),
    );
    await t.tap(find.text('新建'));
    await t.pumpAndSettle();
    return b;
  }

  testWidgets('空行斜杠菜单支持引用、日期、待办和提醒，并按前缀筛选', (t) async {
    final b = await open(t);
    await typeNote(t, '/');
    for (final label in ['引用', '今天日期', '待办', '设提醒…']) {
      expect(find.text(label), findsOneWidget);
    }
    await typeNote(t, '/引');
    expect(find.text('今天日期'), findsNothing);
    await t.tap(find.text('引用'));
    await t.pump();
    expect(noteEditor(t).controller.text, '> ');
    await typeNote(t, '/待办 买牛奶');
    await t.tap(find.text('保存为待办'));
    await t.pumpAndSettle();
    final note = b.notes.active().single;
    expect(note.rawContent, '买牛奶');
    expect(b.items.byNote(note.id).single.title, '买牛奶');
  });
  testWidgets('列表用 Tab 调层级，Shift+Enter 在当前项中继续写', (t) async {
    await open(t);
    await typeNote(t, '- 采购\n- 牛奶');
    final editor = noteEditor(t).controller;
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(editor.text, '- 采购\n  - 牛奶');
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(editor.text, '- 采购\n- 牛奶');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(editor.text, '- 采购\n- 牛奶  \n  ');
  });
  testWidgets('斜杠入口取消后保留草稿，确认后只保存正文和一个有期限的事项', (t) async {
    final b = await open(t);
    await typeNote(t, '采购\n/提醒 买菜');
    await t.tap(find.text('设提醒…'));
    await t.pumpAndSettle();
    await t.tap(find.text('取消'));
    await t.pumpAndSettle();
    expect(noteEditor(t).controller.text, '采购\n/提醒 买菜');
    expect(b.notes.active(), isEmpty);
    await t.tap(find.text('设提醒…'));
    await t.pumpAndSettle();
    await t.tap(find.text('保存并设提醒'));
    await t.pumpAndSettle();
    final note = b.notes.active().single;
    expect(note.rawContent, '采购\n买菜');
    final item = b.items.byNote(note.id).single;
    expect(item.title, '买菜');
    expect(item.lineIndex, 1);
    expect(item.dueAt, isNotNull);
  });
  testWidgets('自然语言时间复用同一确认入口，选区菜单批量转换可撤销', (t) async {
    final b = await open(t);
    await typeNote(t, '买茶\n明天下午三点回电话');
    final editor = noteEditor(t).controller;
    expect(find.textContaining('设提醒 · '), findsOneWidget);
    editor.selection = TextSelection(baseOffset: 0, extentOffset: editor.text.length);
    await t.pump();
    await t.tap(find.byTooltip('编辑操作'));
    await t.pumpAndSettle();
    await t.tap(find.text('选中行转为勾选清单'));
    await t.pumpAndSettle();
    expect(editor.text, '- [ ] 买茶\n- [ ] 明天下午三点回电话');
    editor.undo();
    expect(editor.text, '买茶\n明天下午三点回电话');
    expect(b.notes.active(), isEmpty);
  });
  testWidgets('真实输入连接在拼音确认时转换，撤销恢复原文，列表回车续号', (t) async {
    await open(t);
    await typeNote(t, '1.');
    final editor = noteEditor(t).controller;
    t.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '1.mai',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 2, end: 5),
      ),
    );
    await t.pump();
    expect(editor.value.composing, const TextRange(start: 2, end: 5));
    t.testTextInput.enterText('1.买菜');
    await t.pump();
    expect(editor.text, '1. 买菜');
    await t.tap(find.byTooltip('编辑操作'));
    await t.pumpAndSettle();
    await t.tap(find.text('撤销'));
    await t.pumpAndSettle();
    expect(editor.text, '1.买菜');
    await typeNote(t, '1. 买菜');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(editor.text, '1. 买菜\n2. ');
  });
}
