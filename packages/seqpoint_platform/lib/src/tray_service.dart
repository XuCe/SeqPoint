/// 托盘 / 菜单栏常驻。
///
/// 关键行为：关闭主窗口不退出进程，提醒照常触发。
abstract interface class TrayService {
  Future<void> init({
    required void Function() onOpenPanel,
    required void Function() onQuickNote,
    required void Function() onQuit,
  });

  /// 角标显示今日剩余数量。
  Future<void> setBadge(int count);

  Future<void> dispose();
}

/// 开机自启，可在设置中关闭。
abstract interface class AutostartService {
  Future<bool> isEnabled();
  Future<void> setEnabled(bool value);
}
