import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('不同窗口服务实例复用同一便签窗，已关闭的窗可重新打开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('mixin.one/desktop_multi_window');
    final live = <Map<String, Object>>[];
    var creates = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAllWindows') return List.of(live);
      if (call.method == 'createWindow') {
        final id = 'sticky-${++creates}';
        final args = (call.arguments as Map)['arguments'] as String;
        expect(jsonDecode(args)['noteId'], 'same-note');
        live.add({'windowId': id, 'windowArgument': args});
        return id;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await DesktopWindowService().openSticky('same-note'), 'sticky-1');
    expect(await DesktopWindowService().openSticky('same-note'), 'sticky-1');
    expect(creates, 1);
    live.clear();
    expect(await DesktopWindowService().openSticky('same-note'), 'sticky-2');
    expect(creates, 2);
  });
}
