import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:tray_manager/tray_manager.dart';

/// 托盘 / 菜单栏常驻。
///
/// 关键行为：关闭主窗口不退出进程，提醒照常触发。退出只能从这里。
class DesktopTrayService with TrayListener implements TrayService {
  DesktopTrayService();

  void Function()? _onOpenPanel;
  void Function()? _onQuickNote;
  void Function()? _onQuit;
  int _badge = 0;

  @override
  Future<void> init({
    required void Function() onOpenPanel,
    required void Function() onQuickNote,
    required void Function() onQuit,
  }) async {
    _onOpenPanel = onOpenPanel;
    _onQuickNote = onQuickNote;
    _onQuit = onQuit;

    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray_icon.ico'
          : 'assets/tray/tray_icon.png',
      isTemplate: false,
    );
    await _refreshMenu();
  }

  @override
  Future<void> setBadge(int count) async {
    if (count == _badge) return;
    _badge = count;
    await _refreshMenu();
  }

  Future<void> _refreshMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(
        key: 'open',
        label: _badge > 0 ? '打开序点（$_badge 件待办）' : '打开序点',
      ),
      MenuItem(key: 'quick', label: '快速记录'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _onOpenPanel?.call();
      case 'quick':
        _onQuickNote?.call();
      case 'quit':
        _onQuit?.call();
    }
  }

  @override
  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}

/// 开机自启。默认开启，可在设置中关闭。
class DesktopAutostartService implements AutostartService {
  DesktopAutostartService();

  /// 应用标识是编译期常量，不必为此引入 package_info_plus
  /// （它的新版与 launch_at_startup 有 win32 版本冲突）。
  static const _appName = 'SeqPoint';
  static const _packageName = 'com.seqpoint.app';

  bool _initialized = false;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    launchAtStartup.setup(
      appName: _appName,
      appPath: Platform.resolvedExecutable,
      packageName: _packageName,
    );
    _initialized = true;
  }

  @override
  Future<bool> isEnabled() async {
    await _ensureInit();
    return launchAtStartup.isEnabled();
  }

  @override
  Future<void> setEnabled(bool value) async {
    await _ensureInit();
    if (value) {
      await launchAtStartup.enable();
    } else {
      await launchAtStartup.disable();
    }
  }
}
