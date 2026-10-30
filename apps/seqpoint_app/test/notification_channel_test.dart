import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:seqpoint_app/platform/desktop_notifications.dart';
import 'package:seqpoint_app/platform/mobile_notifications.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final desktop in [true, false]) {
    test('单次通知用UTC绝对时刻调度 desktop=$desktop', () async {
      debugDefaultTargetPlatformOverride = desktop
        ? TargetPlatform.macOS : TargetPlatform.iOS;
      if (desktop) {
        MacOSFlutterLocalNotificationsPlugin.registerWith();
      } else {
        IOSFlutterLocalNotificationsPlugin.registerWith();
      }
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('dexterous.com/flutter/local_notifications');
      final calls = <MethodCall>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async { calls.add(call); return true; });
      addTearDown(() => binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
      final NotificationService service;
      if (desktop) {
        final native = DesktopNotificationService();
        await native.init(); addTearDown(native.dispose); service = native;
      } else {
        final native = MobileNotificationService();
        await native.init(); addTearDown(native.dispose); service = native;
      }
      tz.setLocalLocation(tz.getLocation('Pacific/Honolulu'));
      addTearDown(() => tz.setLocalLocation(tz.UTC));
      final at = DateTime.utc(2035, 1, 1, 20);
      await service.schedule(NotificationRequest(id: 7, title: '期限',
        body: '提醒', fireAt: at, itemId: 'i7', actions: const []));
      final args = calls.singleWhere((c) => c.method == 'zonedSchedule')
        .arguments as Map;
      expect(args['timeZoneName'], tz.UTC.name);
      expect(DateTime.parse('${args['scheduledDateTime']}Z'), at);
      await service.cancel(7);
      expect(calls.last.arguments, 7);
    });
  }

  test('移动通知可初始化且不注册未接线的后台动作', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
      (call) async => call.method == 'getNotificationAppLaunchDetails'
        ? null : true);
    addTearDown(() => binding.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
    final service = MobileNotificationService();
    addTearDown(service.dispose);
    await service.init();
    expect(await service.takeLaunchItem(), isNull);
  });

  test('冷启动点击在订阅后读取一次，使用真实原生payload格式', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    final calls = <MethodCall>[];
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {'notificationLaunchedApp': true, 'notificationResponse': {
          'notificationId': 42, 'payload': 'item-42', 'notificationResponseType': 0,
        }};
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final service = DesktopNotificationService();
    addTearDown(service.dispose);
    await service.init();
    expect(await service.takeLaunchItem(), 'item-42');
    expect(await service.takeLaunchItem(), isNull);
    expect(calls.where((c) => c.method == 'getNotificationAppLaunchDetails')
      .length, 1);
  });
}
