import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class TestSpeech extends Fake implements SpeechToText {
  bool available = true;
  bool listening = false;
  int initializations = 0;
  int cancellations = 0;
  int starts = 0;
  bool autoDone = true;
  Completer<void>? cancellation;
  SpeechResultListener? result;
  SpeechStatusListener? status;
  Completer<bool>? initialization;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #initialize:
        initializations++;
        status = invocation.namedArguments[#onStatus] as SpeechStatusListener?;
        return initialization?.future ?? Future<bool>.value(available);
      case #listen:
        starts++;
        listening = true;
        result = invocation.namedArguments[#onResult] as SpeechResultListener?;
        return Future<void>.value();
      case #stop:
        listening = false;
        if (autoDone) status?.call(SpeechToText.doneStatus);
        return Future<void>.value();
      case #cancel:
        cancellations++;
        listening = false;
        return cancellation?.future ?? Future<void>.value();
      case #isListening: return listening;
      case const Symbol('statusListener='): return null;
      case const Symbol('errorListener='): return null;
    }
    return super.noSuchMethod(invocation);
  }

  void words(String text, {bool finalResult = false}) => result?.call(SpeechRecognitionResult.fromJson({
    'alternates': [{'recognizedWords': text, 'confidence': 1.0}], 'resultType': finalResult ? 1 : 0,
  }));
}
