import 'dart:io';

import 'package:seqpoint_platform/seqpoint_platform.dart';

import 'desktop_hotkeys.dart';
import 'desktop_notifications.dart';
import 'desktop_selected_text.dart';
import 'desktop_tray.dart';
import 'desktop_windows.dart';
import 'mobile_capture.dart';
import 'mobile_notifications.dart';
import 'secure_secret_store.dart';

/// 平台能力注册表。按运行平台装配具体实现。
///
/// 移动端没有全局快捷键与托盘，桌面端没有小组件——缺失的能力为 null，
/// 调用方据此隐藏对应界面，而不是抛异常。
class PlatformRegistry {
  const PlatformRegistry({
    required this.secrets,
    this.hotkeys,
    this.tray,
    this.autostart,
    this.windows,
    this.notifications,
    this.selectedText,
    this.widgets,
    this.shareIntake,
    this.quickActions,
    this.syncEngine,
  });

  final HotkeyService? hotkeys;
  final TrayService? tray;
  final AutostartService? autostart;
  final WindowService? windows;
  final NotificationService? notifications;
  final SelectedTextService? selectedText;
  final WidgetService? widgets;
  final ShareIntake? shareIntake;
  final QuickActionsService? quickActions;

  /// 安全存储是唯一各端都必须有的能力。
  final SecretStore secrets;

  /// 可选的 Syncthing 引擎宿主。按需下载，首装不含。
  final SyncEngineHost? syncEngine;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// 按当前平台装配。调用方随后按需 init 各服务。
  static Future<PlatformRegistry> forCurrentPlatform() async {
    const secrets = SecureSecretStore();

    if (isDesktop) {
      final notifications = DesktopNotificationService();
      await notifications.init();
      return PlatformRegistry(
        secrets: secrets,
        hotkeys: DesktopHotkeyService(isWindows: Platform.isWindows),
        tray: DesktopTrayService(),
        autostart: DesktopAutostartService(),
        windows: DesktopWindowService(),
        notifications: notifications,
        selectedText: const DesktopSelectedTextService(),
      );
    }

    final notifications = MobileNotificationService();
    await notifications.init();
    final share = MobileShareIntake();
    await share.init();
    final quickActions = MobileQuickActionsService();
    await quickActions.register();

    return PlatformRegistry(
      secrets: secrets,
      notifications: notifications,
      widgets: const MobileWidgetService(),
      shareIntake: share,
      quickActions: quickActions,
    );
  }
}
