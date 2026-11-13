import 'dart:async';
import 'package:flutter/foundation.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// 桌面系统通知（macOS / Windows / Linux）。
///
/// 与移动端共用 flutter_local_notifications：它已覆盖全部目标平台，
/// 省掉一套独立实现，也不必再依赖已停更的 local_notifier。
///
/// Windows 的通知动作按钮由 windows 子包提供，与 macOS 的写法不同，
/// 因此排程分平台处理。Linux 通知服务（freedesktop D-Bus）没有定时投递，
/// 未来时刻的提醒在应用运行期间由进程内定时器补齐。
class DesktopNotificationService implements NotificationService {
  DesktopNotificationService();

  final _plugin = FlutterLocalNotificationsPlugin();
  late final _windows = FlutterLocalNotificationsWindows();
  final _responses =
      StreamController<({String itemId, NotificationAction action})>.broadcast();

  /// Windows 侧没有内置的"按 itemId 取消"，自己记一份映射。
  final _itemOfId = <int, String>{};
  bool _launchRead = false;

  final _linuxTimers = <int, Timer>{};

  bool get _isWindows => defaultTargetPlatform == TargetPlatform.windows;
  bool get _isLinux => defaultTargetPlatform == TargetPlatform.linux;

  @override
  Stream<({String itemId, NotificationAction action})> get responses =>
      _responses.stream;

  Future<void> init({String appName = 'SeqPoint'}) async {
    tzdata.initializeTimeZones();

    if (_isWindows) {
      await _windows.initialize(
        settings: WindowsInitializationSettings(
          appName: appName,
          appUserModelId: 'com.seqpoint.app',
          // 通知的稳定标识，用于系统识别本应用的通知组。
          guid: '9f1a1f6e-2f5a-4a2e-9b3c-7d1e5a0c8b42',
        ),
        onDidReceiveNotificationResponse: _onResponse,
      );
      return;
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        macOS: DarwinInitializationSettings(
          requestAlertPermission: true,
          requestBadgePermission: false,
          requestSoundPermission: true,
        ),
        linux: LinuxInitializationSettings(defaultActionName: '查看'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
    );
  }

  void _onResponse(NotificationResponse response) {
    _responses.add((
      itemId: response.payload ?? '',
      action: switch (response.actionId) {
        'done' => NotificationAction.done,
        'snooze' => NotificationAction.snooze,
        _ => NotificationAction.open,
      },
    ));
  }

  @override
  Future<bool> requestPermission() async {
    if (_isWindows || _isLinux) return true; // Windows / Linux 无需申请
    final macos = _plugin.resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin>();
    return await macos?.requestPermissions(alert: true, sound: true) ?? true;
  }

  @override
  Future<void> schedule(NotificationRequest request) async {
    _itemOfId[request.id] = request.itemId ?? '';
    final when = tz.TZDateTime.from(request.fireAt, tz.UTC);
    final now = tz.TZDateTime.now(tz.UTC);
    final due = !when.isAfter(now);

    if (_isWindows) {
      final details = WindowsNotificationDetails(
        actions: [
          for (final a in request.actions)
            WindowsAction(content: _labelOf(a), arguments: a.name),
        ],
      );
      // Windows AddToSchedule 不按 Tag 替换已有计划。
      await _windows.cancel(id: request.id);
      if (due) {
        await _windows.show(
          id: request.id,
          title: request.title,
          body: request.body,
          notificationDetails: details,
          payload: request.itemId,
        );
      } else {
        await _windows.zonedSchedule(
          id: request.id,
          title: request.title,
          body: request.body,
          scheduledDate: when,
          notificationDetails: details,
          payload: request.itemId,
        );
      }
      return;
    }

    if (_isLinux) {
      _linuxTimers.remove(request.id)?.cancel();
      final details = NotificationDetails(
        linux: LinuxNotificationDetails(actions: [
          for (final a in request.actions)
            LinuxNotificationAction(key: a.name, label: _labelOf(a)),
        ]),
      );
      Future<void> show() => _plugin.show(
            id: request.id,
            title: request.title,
            body: request.body,
            notificationDetails: details,
            payload: request.itemId,
          );
      if (due) {
        await show();
        return;
      }
      _linuxTimers[request.id] = Timer(when.difference(now), () {
        _linuxTimers.remove(request.id);
        unawaited(show().catchError((Object _) {}));
      });
      return;
    }

    final details = NotificationDetails(
      macOS: DarwinNotificationDetails(
        categoryIdentifier: _categoryFor(request.actions),
      ),
    );
    if (due) {
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
      // 精确提醒是强约束，必须按时触发。
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      title: request.title,
      body: request.body,
      payload: request.itemId,
    );
  }

  @override
  Future<void> cancel(int id) async {
    _itemOfId.remove(id);
    _linuxTimers.remove(id)?.cancel();
    if (_isWindows) {
      await _windows.cancel(id: id);
      return;
    }
    await _plugin.cancel(id: id);
  }

  @override
  Future<void> cancelForItem(String itemId) async {
    final ids = _itemOfId.entries
        .where((e) => e.value == itemId)
        .map((e) => e.key)
        .toList();
    for (final id in ids) {
      await cancel(id);
    }
  }

  @override
  Future<String?> takeLaunchItem() async {
    if (_launchRead) return null;
    _launchRead = true;
    try {
      final details = _isWindows
          ? await _windows.getNotificationAppLaunchDetails()
          : await _plugin.getNotificationAppLaunchDetails();
      return details?.didNotificationLaunchApp == true
          ? details?.notificationResponse?.payload : null;
    } catch (_) {
      _launchRead = false;
      rethrow;
    }
  }

  Future<void> dispose() {
    for (final timer in _linuxTimers.values) {
      timer.cancel();
    }
    _linuxTimers.clear();
    return _responses.close();
  }

  /// macOS 的动作按钮通过 category 注册。这里按动作组合选类别名，
  /// 具体注册在原生侧完成（M1 接线时补）。
  static String _categoryFor(List<NotificationAction> actions) =>
      actions.contains(NotificationAction.snooze)
          ? 'seqpoint_reminder'
          : 'seqpoint_plain';

  static String _labelOf(NotificationAction a) => switch (a) {
        NotificationAction.done => '完成',
        NotificationAction.snooze => '稍后',
        NotificationAction.open => '查看',
      };
}
