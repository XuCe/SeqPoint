import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

void main() {
  for (final action in [HotkeyAction.toggleQuickNote, HotkeyAction.newNote,
    HotkeyAction.clipboardToNote, HotkeyAction.openSearch]) {
    testWidgets('原生关闭后仍可通过$action唤起', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      final hotkeys = TestHotkeys(); final tray = TestTray();
      addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
      var visible = true; var focused = 0;
      const channel = MethodChannel('window_manager');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'hide') visible = false;
        if (call.method == 'show') visible = true;
        if (call.method == 'focus') focused++;
        if (call.method == 'isVisible') return visible;
        if (call.method == 'isMinimized' || call.method == 'isFocused') return false;
        return null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async =>
        call.method == 'Clipboard.getData' ? {'text': '后台剪贴板内容'} : null);
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.pumpWidget(hotkeyApp(boot, hotkeys, tray: tray));
      await tester.pumpAndSettle();
      tester.binding.channelBuffers.push('window_manager', const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('onEvent', {'eventName': 'close'})), (_) {});
      await tester.pumpAndSettle(); expect(visible, isFalse);
      hotkeys.events.add(action); await tester.pumpAndSettle();
      expect(visible, isTrue); expect(focused, 1);
      expect(hotkeys.bound, hasLength(4)); expect(hotkeys.releases, 0);
      expect(find.byType(TextField), action == HotkeyAction.toggleQuickNote
        ? findsNothing : findsOneWidget);
      if (action == HotkeyAction.clipboardToNote) expect(find.text('后台剪贴板内容'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
    });
  }
}
