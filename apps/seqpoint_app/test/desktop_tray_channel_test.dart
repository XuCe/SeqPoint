import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/desktop_tray.dart';

void main() {
  testWidgets('真实托盘资产可加载，原生菜单事件只触发对应动作，销毁后移除监听', (tester) async {
    const channel = MethodChannel('tray_manager');
    const codec = StandardMethodCodec();
    final calls = <MethodCall>[]; final actions = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call); return null; });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final tray = DesktopTrayService();
    await tray.init(onOpenPanel: () => actions.add('open'),
      onQuickNote: () => actions.add('quick'), onQuit: () => actions.add('quit'));
    expect((await rootBundle.load('assets/tray/tray_icon.ico')).lengthInBytes, greaterThan(0));
    expect(calls.singleWhere((c) => c.method == 'setIcon').arguments['isTemplate'], isFalse);
    final items = calls.singleWhere((c) => c.method == 'setContextMenu')
      .arguments['menu']['items'] as List;
    for (final label in ['打开序点', '快速记录', '退出']) {
      final item = items.singleWhere((i) => i['label'] == label);
      tester.binding.channelBuffers.push('tray_manager', codec.encodeMethodCall(
        MethodCall('onTrayMenuItemClick', {'id': item['id']})), (_) {});
      await tester.pump();
    }
    expect(actions, ['open', 'quick', 'quit']);
    await tray.dispose();
    expect(calls.last.method, 'destroy');
    final open = items.firstWhere((i) => i['label'] == '打开序点');
    tester.binding.channelBuffers.push('tray_manager', codec.encodeMethodCall(
      MethodCall('onTrayMenuItemClick', {'id': open['id']})), (_) {});
    await tester.pump();
    expect(actions, ['open', 'quick', 'quit']);
  });
}
