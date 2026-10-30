import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/platform/desktop_hotkeys.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'global_hotkey_support.dart';

void main() {
  test('Windows唤起默认避开系统Alt+Space，其余三项保持Alt+Shift组合', () {
    final defaults = DesktopHotkeyService(isWindows: true).defaults();
    expect(defaults[HotkeyAction.toggleQuickNote]!.key, 'space');
    expect(defaults[HotkeyAction.toggleQuickNote]!.modifiers, {'alt', 'shift'});
    for (final action in [HotkeyAction.newNote, HotkeyAction.clipboardToNote, HotkeyAction.openSearch]) {
      expect(defaults[action]!.modifiers, {'alt', 'shift'});
    }
  });
  testWidgets('原生注册四项system绑定，事件可打开编辑器，销毁后注销', (tester) async {
    const name = 'dev.leanflutter.plugins/hotkey_manager';
    const events = '${name}_event';
    final calls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    for (final channel in [name, events, 'window_manager']) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        if (channel == name) calls.add(call);
        return call.method == 'isMinimized' ? false : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(MethodChannel(channel), null));
    }
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final hotkeys = DesktopHotkeyService(isWindows: false);
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    await tester.pumpAndSettle();
    final registered = calls.where((c) => c.method == 'register').toList();
    expect(registered, hasLength(4));
    expect(registered.map((c) => (c.arguments as Map)['scope']).toSet(), {'system'});
    expect((registered.first.arguments as Map)['modifiers'], ['alt']);
    final id = (registered[1].arguments as Map)['identifier'];
    tester.binding.channelBuffers.push(events,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'onKeyDown', 'data': {'identifier': id},
      }), (_) {});
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'unregisterAll'), hasLength(1));
    await hotkeys.dispose();
  });
}
