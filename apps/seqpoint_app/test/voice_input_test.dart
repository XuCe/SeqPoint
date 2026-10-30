import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/voice/voice_input_button.dart';

import 'voice_test_speech.dart';

void main() {
  testWidgets('主动开始后识别，停止编辑确认再插入原输入框', (tester) async {
    final speech = TestSpeech();
    final controller = TextEditingController(text: '原文：');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      TextField(controller: controller),
      VoiceInputButton(controller: controller, speech: speech),
    ]))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    expect(speech.initializations, 0);
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    speech.words('开会讨论');
    await tester.pump();
    expect(find.text('开会讨论'), findsOneWidget);
    await tester.tap(find.text('停止识别'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '明天开会');
    await tester.tap(find.text('确认文字'));
    await tester.pumpAndSettle();
    expect(controller.text, '原文：明天开会');
  });

  testWidgets('权限或能力不可用时保留手动输入且不声称成功', (tester) async {
    final speech = TestSpeech()..available = false;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('语音识别不可用'), findsOneWidget);
    expect(controller.text, isEmpty);
  });

  testWidgets('取消识别保留已识别文字并忽略迟到结果', (tester) async {
    final speech = TestSpeech();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    speech.words('保留');
    await tester.tap(find.text('取消识别'));
    await tester.pumpAndSettle();
    speech.words('迟到覆盖');
    await tester.pump();
    expect(find.text('保留'), findsOneWidget);
    expect(find.text('迟到覆盖'), findsNothing);
    expect(speech.cancellations, 1);
  });

  testWidgets('初始化等待中离开页面，权限返回后不启动麦克风', (tester) async {
    final speech = TestSpeech()..initialization = Completer<bool>();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音输入'));
    await tester.pump();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    speech.initialization!.complete(true);
    await tester.pump();
    expect(speech.starts, 0);
  });

  testWidgets('再次识别追加文字，保留已修改的草稿', (tester) async {
    final speech = TestSpeech();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '先写');
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    speech.words('后说');
    await tester.pump();
    expect(find.text('先写\n后说'), findsOneWidget);
  });
}
