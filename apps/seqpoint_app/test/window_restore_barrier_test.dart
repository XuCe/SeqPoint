import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixin.one/desktop_multi_window');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowService service;
  final live = <Map<String, Object>>[];
  var creates = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    service = DesktopWindowService()..pauseStickyOpening(false);
    live.clear(); creates = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAllWindows') return List.of(live);
      if (call.method == 'createWindow') return 'sticky-${++creates}';
      return null;
    });
  });
  tearDown(() {
    service.pauseStickyOpening(false);
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('暂停后所有同引擎服务实例都拒绝开窗且不调用原生create', () async {
    service.pauseStickyOpening(true);
    await expectLater(service.openSticky('one'), throwsStateError);
    await expectLater(DesktopWindowService().openSticky('two'), throwsStateError);
    expect(creates, 0);
    service.pauseStickyOpening(false);
    expect(await service.openSticky('one'), 'sticky-1');
  });

  test('暂停后枚举等待在途原生创建，排除当前窗并拒绝未知子窗', () async {
    final entered = Completer<void>();
    final created = Completer<String>();
    var scans = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAllWindows') { scans++; return List.of(live); }
      if (call.method == 'createWindow') { entered.complete(); return created.future; }
      if (call.method == 'getWindowDefinition') {
        return {'windowId': 'main-7', 'windowArgument': ''};
      }
      return null;
    });
    final opening = DesktopWindowService().openSticky('pending');
    await entered.future;
    service.pauseStickyOpening(true);
    var enumerated = false;
    final checking = service.otherWindowIds().then((ids) { enumerated = true; return ids; });
    await Future<void>.delayed(Duration.zero);
    expect(enumerated, isFalse);
    expect(scans, 1);
    live.addAll([
      {'windowId': 'main-7', 'windowArgument': ''},
      {'windowId': 'child-9', 'windowArgument': 'unknown'},
    ]);
    created.complete('child-9');
    expect(await opening, 'child-9');
    expect(await checking, ['child-9']);
    expect(scans, 2);
  });

  test('暂停在getAll返回之前生效，旧开窗中止并使恢复检查失败关闭', () async {
    final entered = Completer<void>();
    final response = Completer<List<Map<String, Object>>>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getAllWindows') {
        entered.complete(); return response.future;
      }
      if (call.method == 'createWindow') creates++;
      return null;
    });
    final opening = service.openSticky('pending');
    final failedOpening = expectLater(opening, throwsStateError);
    await entered.future;
    service.pauseStickyOpening(true);
    final failedCheck = expectLater(service.otherWindowIds(), throwsStateError);
    response.complete([]);
    await failedOpening;
    await failedCheck;
    expect(creates, 0);
    await expectLater(DesktopWindowService().openSticky('new'), throwsStateError);
  });

  test('未暂停时不允许枚举恢复条件', () async {
    await expectLater(service.otherWindowIds(), throwsStateError);
  });
}
