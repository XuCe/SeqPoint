import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';
import 'package:seqpoint_app/shared/note_markdown_field.dart';

/// Windows 引擎收到 setEditingState 会结束正在进行的输入法组字，之后每次拼音
/// 更新都被当成已上屏的文字插入，出现"wwuwu'z乌镇"。所以平台刚发来的值不能
/// 原样回送；只有应用自己改了内容才同步给平台。
void main() {
  Iterable<MethodCall> sentStates(WidgetTester tester) => tester.testTextInput.log
      .where((call) => call.method == 'TextInput.setEditingState');
  Iterable<MethodCall> reconnects(WidgetTester tester) => tester.testTextInput.log
      .where((call) => call.method == 'TextInput.setClient' ||
          call.method == 'TextInput.clearClient');

  Future<MarkdownEditorController> pumpEditor(WidgetTester tester) async {
    final controller = MarkdownEditorController(text: '经营平台 app端 打包\n');
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: NoteMarkdownField(controller: controller)),
    ));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isRegistered, isTrue);
    tester.testTextInput.log.clear();
    return controller;
  }

  testWidgets('拼音组字过程中不把平台发来的值回送给平台', (tester) async {
    final controller = await pumpEditor(tester);
    final base = controller.text;
    for (final pinyin in ['w', 'wu', "wu'z"]) {
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: '$base$pinyin',
        selection: TextSelection.collapsed(offset: base.length + pinyin.length),
        composing: TextRange(start: base.length, end: base.length + pinyin.length),
      ));
      await tester.pump();
      await tester.pump();
    }
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: '$base乌镇',
      selection: TextSelection.collapsed(offset: base.length + 2),
    ));
    await tester.pumpAndSettle();
    expect(reconnects(tester), isEmpty);
    expect(sentStates(tester), isEmpty);
    expect(controller.text, '$base乌镇');
  });

  testWidgets('应用自己改了正文仍会同步给平台', (tester) async {
    final controller = await pumpEditor(tester);
    tester.testTextInput.updateEditingValue(TextEditingValue(
      text: '${controller.text}视频',
      selection: TextSelection.collapsed(offset: controller.text.length + 2),
    ));
    await tester.pumpAndSettle();
    expect(sentStates(tester), isEmpty);
    controller.value = const TextEditingValue(
      text: '- [ ] 接入',
      selection: TextSelection.collapsed(offset: 8),
    );
    await tester.pumpAndSettle();
    expect(sentStates(tester).single.arguments, containsPair('text', '- [ ] 接入'));
  });
}
