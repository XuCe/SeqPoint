import 'dart:ffi';
import 'dart:io';

/// 直接调用 auto_updater 随包附带的 WinSparkle.dll。
///
/// 插件只提供“检查后弹窗询问是否安装”，这里补上 WinSparkle 自带的
/// “找到更新即下载并安装”：只显示进度，不再逐步确认。
/// 安装包签名仍由 WinSparkle 按更新源校验。
class WinSparkle {
  WinSparkle({
    required void Function(int) setAutomaticChecks,
    required void Function() checkAndInstall,
  }) : _setAutomaticChecks = setAutomaticChecks,
       _checkAndInstall = checkAndInstall;

  final void Function(int) _setAutomaticChecks;
  final void Function() _checkAndInstall;

  /// 非 Windows 或找不到 WinSparkle 时返回 null，调用方回退到插件的标准流程。
  static WinSparkle? open() {
    if (!Platform.isWindows) return null;
    try {
      final library = DynamicLibrary.open('WinSparkle.dll');
      return WinSparkle(
        setAutomaticChecks: library
            .lookupFunction<Void Function(Int32), void Function(int)>(
              'win_sparkle_set_automatic_check_for_updates',
            ),
        checkAndInstall: library
            .lookupFunction<Void Function(), void Function()>(
              'win_sparkle_check_update_with_ui_and_install',
            ),
      );
    } on Object {
      return null;
    }
  }

  /// 检查由应用自己负责。显式关闭后，WinSparkle 不会再弹“是否自动检查更新”。
  void disableAutomaticChecks() => _setAutomaticChecks(0);

  /// 检查更新；找到即下载、校验并运行安装器，随后请求应用退出。
  void checkAndInstall() => _checkAndInstall();
}
