import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:window_manager/window_manager.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/seq_app.dart';
import 'platform/desktop_windows.dart';
import 'platform/desktop_hotkeys.dart';
import 'platform/desktop_tray.dart';
import 'platform/desktop_notifications.dart';
import 'platform/mobile_notifications.dart';

/// 应用入口。
///
/// 桌面便签窗使用独立引擎，由窗口插件读取启动参数；
/// 移动端只有一个入口。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['Syncthing and native dependencies'],
      await rootBundle.loadString('assets/licenses/syncthing.txt'));
  });

  final info = await PackageInfo.fromPlatform();
  final title = '序点 ${info.version}';
  if (Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();
    final current = await WindowController.fromCurrentEngine();
    final noteId = await StickyWindowSetup.apply(current.arguments);
    if (noteId != null) {
      await current.setWindowMethodHandler((call) async {
        if (call.method != 'close_self') throw UnsupportedError(call.method);
        await windowManager.close();
      });
      runApp(
        SeqApp.sticky(
          noteId: noteId,
          title: title,
          windows: DesktopWindowService(),
          onClose: () => windowManager.close(),
        ),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await windowManager.show();
        await windowManager.focus();
      });
    } else {
      await windowManager.setTitle(title);
      await _runMainApp(
          title: title,
          windows: DesktopWindowService(),
          hotkeys: DesktopHotkeyService(isWindows: Platform.isWindows),
          tray: DesktopTrayService(),
      );
    }
    return;
  }

  await _runMainApp(title: title);
}

Future<void> _runMainApp({required String title, WindowService? windows, HotkeyService? hotkeys,
    TrayService? tray}) async {
  NotificationService? notifications;
  String? notificationError;
  try {
    if (isDesktop) {
      final service = DesktopNotificationService();
      await service.init();
      notifications = service;
    } else if (isMobile) {
      final service = MobileNotificationService();
      await service.init();
      notifications = service;
    }
  } catch (e) {
    notificationError = '通知初始化失败：$e';
  }
  runApp(SeqApp(title: title, windows: windows, hotkeys: hotkeys, tray: tray,
    notifications: notifications, notificationError: notificationError,
    notificationCapacity: Platform.isIOS ? 64 : null));
}

bool get isDesktop =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;
bool get isMobile => Platform.isAndroid || Platform.isIOS;
