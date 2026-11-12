import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';
import 'package:seqpoint_app/shared/note_markdown_field.dart';

import '../test/note_editor_test_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows 原生编辑菜单已注册，输入保留 Markdown 原文', (tester) async {
    final controller = MarkdownEditorController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NoteMarkdownField(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    const channel = MethodChannel('native_adaptive_toolbox/menu');
    await channel.invokeMethod<void>('dismissMenu');
    await typeNote(tester, '1.');
    tester.testTextInput.enterText('1.茶');
    await tester.pump();
    expect(controller.text, '1. 茶');
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);
}
