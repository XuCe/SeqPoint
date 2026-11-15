import 'dart:async';
import 'dart:ffi';
import 'dart:io';

/// 桌面主面板注册的“关闭并重新打开”入口。
final appRelauncher = AppRelauncher();

/// 关闭并重新打开应用。
///
/// 热更新补丁只在新进程启动时加载，所以“立即重启”必须真正结束当前进程。
/// 收尾（同步排空、释放快捷键与托盘）由主面板完成，这里只负责在本进程
/// 结束之后把应用再打开。
class AppRelauncher {
  AppRelauncher({bool? supported, Future<void> Function()? spawn})
    : supported = supported ?? (Platform.isWindows || Platform.isMacOS),
      _spawn = spawn ?? _spawnAfterExit;

  /// 当前平台能否自动重新打开；移动端由系统管理进程，不提供。
  final bool supported;
  final Future<void> Function() _spawn;

  /// 由主面板注册：完成与托盘退出相同的安全收尾，再退出并重新打开。
  Future<void> Function()? onRestart;

  bool get available => supported && onRestart != null;

  Future<void> restart() {
    final handler = onRestart;
    if (!supported || handler == null) {
      return Future.error(StateError('当前环境不能自动重启'));
    }
    return handler();
  }

  /// 在进程即将退出时调用：安排本进程结束后重新打开应用。
  Future<void> scheduleAfterExit() => _spawn();

  static const _flag = '--relaunch-after=';

  static Future<void> _spawnAfterExit() async {
    if (Platform.isWindows) {
      // 新进程先等本进程完全退出（见 waitForPreviousExit），避免两个实例同时打开数据库。
      await Process.start(
        Platform.resolvedExecutable,
        ['$_flag$pid'],
        mode: ProcessStartMode.detached,
      );
      return;
    }
    if (Platform.isMacOS) {
      // 本进程结束时系统关闭管道写端，cat 读到结尾后再打开应用。
      // 不需要查询或给其他进程发信号，沙盒内同样可用。
      final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
      await Process.start(
        '/bin/sh',
        [
          '-c',
          r'exec >/dev/null 2>&1; cat; exec /usr/bin/open "$1"',
          'seqpoint-relaunch',
          bundle,
        ],
        mode: ProcessStartMode.detachedWithStdio,
      );
      return;
    }
    throw UnsupportedError('当前平台不能自动重启');
  }

  /// 由重启拉起的新进程在启动最早处调用：等旧进程完全退出再继续。
  ///
  /// 超过 [limit] 仍未退出时照常启动：旧进程此时已停止同步并释放快捷键与托盘。
  static Future<void> waitForPreviousExit(
    List<String> args, {
    Duration limit = const Duration(seconds: 20),
  }) async {
    if (!Platform.isWindows) return;
    final previous = args
        .where((arg) => arg.startsWith(_flag))
        .map((arg) => int.tryParse(arg.substring(_flag.length)))
        .firstOrNull;
    if (previous == null || previous == pid) return;
    try {
      await _WindowsProcess.waitForExit(previous, limit);
    } on Object {
      // 无法等待时不阻止启动。
    }
  }
}

abstract final class _WindowsProcess {
  static const _synchronize = 0x00100000;
  static const _waitTimeout = 0x00000102;

  static Future<void> waitForExit(int processId, Duration limit) async {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel32.lookupFunction<
      IntPtr Function(Uint32, Int32, Uint32),
      int Function(int, int, int)
    >('OpenProcess');
    final waitForSingleObject = kernel32.lookupFunction<
      Uint32 Function(IntPtr, Uint32),
      int Function(int, int)
    >('WaitForSingleObject');
    final closeHandle = kernel32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'CloseHandle',
        );
    final handle = openProcess(_synchronize, 0, processId);
    if (handle == 0) return; // 旧进程已经退出。
    try {
      final deadline = DateTime.now().add(limit);
      while (waitForSingleObject(handle, 0) == _waitTimeout &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      closeHandle(handle);
    }
  }
}
