import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 移动端本地通知。
///
/// 全部由设备本地调度，不依赖服务端推送——与"零服务端"原则一致。
/// 代价是：设备关机期间的提醒不会补发，重新开机后由应用重排。
class MobileNotificationService implements NotificationService {
  MobileNotificationService();

  final _plugin = FlutterLocalNotificationsPlugin();
  final _responses =
      StreamController<({String itemId, NotificationAction action})>.broadcast();

  static const _channelId = 'seqpoint_reminders';
  bool _launchRead = false;

  @override
  Stream<({String itemId, NotificationAction action})> get responses =>
      _responses.stream;

  Future<void> init() async {
    tzdata.initializeTimeZones();

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
  }

  /// 通知的 payload 里放 itemId，动作 id 对应 [NotificationAction]。
  void _onResponse(NotificationResponse response) {
    final itemId = response.payload ?? '';
    final action = switch (response.actionId) {
      'done' => NotificationAction.done,
      'snooze' => NotificationAction.snooze,
      _ => NotificationAction.open,
    };
    _responses.add((itemId: itemId, action: action));
  }

  @override
  Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    }
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final granted = await ios?.requestPermissions(alert: true, sound: true);
    return granted ?? false;
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    final when = tz.TZDateTime.from(request.fireAt, tz.UTC);
    final now = tz.TZDateTime.now(tz.UTC);

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '提醒',
        channelDescription: '事项到期与智能提醒',
        importance: Importance.high,
        priority: Priority.high,
        actions: [
          for (final a in request.actions)
            AndroidNotificationAction(a.name, _labelOf(a),
                showsUserInterface: a == NotificationAction.open),
        ],
      ),
      iOS: const DarwinNotificationDetails(categoryIdentifier: _channelId),
    );

    if (!when.isAfter(now)) {
      await _plugin.show(
        id: request.id,
        title: request.title,
        body: request.body,
        notificationDetails: details,
        payload: request.itemId,
      );
      return;
    }

    await _plugin.zonedSchedule(
      id: request.id,
      scheduledDate: when,
      notificationDetails: details,
      // 精确提醒是强约束，必须按时触发，不能被系统省电策略推迟。
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      title: request.title,
      body: request.body,
      payload: request.itemId,
    );
  }

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelForItem(String itemId) async {
    final pending = await _plugin.pendingNotificationRequests();
    for (final p in pending.where((p) => p.payload == itemId)) {
      await _plugin.cancel(id: p.id);
    }
  }

  @override
  Future<String?> takeLaunchItem() async {
    if (_launchRead) return null;
    _launchRead = true;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      return details?.didNotificationLaunchApp == true
          ? details?.notificationResponse?.payload : null;
    } catch (_) {
      _launchRead = false;
      rethrow;
    }
  }

  Future<void> dispose() => _responses.close();

  static String _labelOf(NotificationAction a) => switch (a) {
        NotificationAction.done => '完成',
        NotificationAction.snooze => '稍后',
        NotificationAction.open => '查看',
      };

}
