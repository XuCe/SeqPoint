import 'package:flutter/material.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import 'panel/main_panel.dart';

/// 桌面壳：托盘常驻 + 主面板 + 若干独立便签窗。
///
/// 主窗口关闭不退出进程（由 TrayService 保证），提醒照常触发。
class DesktopShell extends StatelessWidget {
  const DesktopShell({super.key, this.hotkeys, this.tray});
  final HotkeyService? hotkeys;
  final TrayService? tray;

  @override
  Widget build(BuildContext context) => MainPanel(hotkeys: hotkeys, tray: tray);
}
