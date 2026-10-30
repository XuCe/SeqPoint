import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

class TestRecorder extends Fake implements AudioRecorder {
  bool permission = true;
  String? path;
  int starts = 0;
  int cancellations = 0;
  bool stopFails = false;
  Completer<bool>? requested;
  Completer<void>? cancelPending;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #hasPermission:
        return requested?.future ?? Future<bool>.value(permission);
      case #start:
        starts++;
        path = invocation.namedArguments[#path] as String;
        return File(path!).writeAsBytes([0, 0, 0, 20, 102, 116, 121, 112,
          77, 52, 65, 32, 0, 0, 0, 0, 77, 52, 65, 32]).then<void>((_) {});
      case #stop:
        return stopFails ? Future<String?>.error(StateError('stop failed'))
          : Future<String?>.value(path);
      case #cancel:
        cancellations++;
        return cancelPending?.future ?? Future<void>.value();
      case #dispose: return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
