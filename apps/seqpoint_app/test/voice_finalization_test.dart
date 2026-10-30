import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/features/voice/voice_input_button.dart';

import 'voice_test_speech.dart';

void main() {
  testWidgets('stop平台返回后继续等final结果，确认使用最终文字', (tester) async {
    final speech = TestSpeech()..autoDone = false;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    speech.words('部分');
    await tester.tap(find.text('停止识别'));
    await tester.pump();
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '确认文字')).onPressed, isNull);
    speech.words('最终完整文字', finalResult: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认文字'));
    await tester.pumpAndSettle();
    expect(controller.text, '最终完整文字');
  });

  testWidgets('cancel未完成期间不能重新识别或确认', (tester) async {
    final speech = TestSpeech()..cancellation = Completer<void>();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      VoiceInputButton(controller: controller, speech: speech))));
    await tester.tap(find.byTooltip('语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始语音输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消识别'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '开始语音输入')).onPressed, isNull);
    speech.cancellation!.complete();
    await tester.pumpAndSettle();
  });
}
