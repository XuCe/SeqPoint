import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('快速连点同一便签只启动一个子引擎', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('mixin.one/desktop_multi_window');
    final scan = Completer<void>();
    var creates = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAllWindows') {
        await scan.future;
        return [];
      }
      if (call.method == 'createWindow') return 'sticky-${++creates}';
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final first = DesktopWindowService().openSticky('same-note');
    final second = DesktopWindowService().openSticky('same-note');
    scan.complete();
    expect(await Future.wait([first, second]), ['sticky-1', 'sticky-1']);
    expect(creates, 1);
  });

  testWidgets('不同窗口服务实例复用同一便签窗，已关闭的窗可重新打开', (tester) async {
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('mixin.one/desktop_multi_window');
    final live = <Map<String, Object>>[];
    var creates = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
    var activates = 0;
    messenger.setMockMethodCallHandler(channels, (call) async {
      expect((call.arguments as Map)['method'], 'activate');
      activates++;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channels, null));
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
    expect(activates, 1);
  });
}
