import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'full_update_installer.dart';
import 'github_release.dart';

/// 完整版本自动更新开关，默认开启。
abstract final class FullUpdatePreferences {
  static const _key = 'update.full.auto';

  /// 只有桌面端能在应用内完成下载与安装；移动端仍需用户触发。
  static bool get supported =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS);

  static Future<bool> autoEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? true;

  static Future<void> setAutoEnabled(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setBool(_key, value)) {
      throw StateError('自动更新设置保存失败');
    }
  }
}

/// 桌面端完整版本自动更新：启动后及常驻期间定时检查，发现新版本即下载安装。
///
/// 用户正在编辑或开着便签窗时不打断，稍后再试。
class FullUpdateAutoChecker {
  FullUpdateAutoChecker({
    required this.installer,
    required this.canStart,
    Future<FullRelease> Function()? loadRelease,
    Future<String> Function()? installedVersion,
    Future<bool> Function()? enabled,
    this.firstDelay = const Duration(seconds: 30),
    this.interval = const Duration(hours: 6),
    this.retryDelay = const Duration(minutes: 10),
  }) : _loadRelease = loadRelease ?? fetchLatestRelease,
       _installedVersion = installedVersion ?? _readInstalledVersion,
       _enabled = enabled ?? FullUpdatePreferences.autoEnabled;

  final FullUpdateInstaller installer;

  /// 当前是否空闲到可以开始安装（安装会退出应用）。
  final bool Function() canStart;
  final Future<FullRelease> Function() _loadRelease;
  final Future<String> Function() _installedVersion;
  final Future<bool> Function() _enabled;
  final Duration firstDelay, interval, retryDelay;

  Timer? _timer;
  bool _running = false, _disposed = false;

  void start() => _schedule(firstDelay);

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed) return;
    _timer = Timer(delay, () async {
      final next = await runOnce();
      _schedule(next);
    });
  }

  /// 检查一次，返回距下次检查的间隔。
  @visibleForTesting
  Future<Duration> runOnce() async {
    if (_running || _disposed) return interval;
    _running = true;
    try {
      if (!await _enabled()) return interval;
      final installed = await _installedVersion();
      final release = await _loadRelease();
      if (_disposed) return interval;
      if (!release.isNewerThan(installed) || release.downloadUrl == null) {
        return interval;
      }
      if (installer.busy || !canStart()) return retryDelay;
      await installer.install(release);
      return interval;
    } catch (_) {
      // 网络失败，或便签窗尚未关闭等原因暂不能安装：稍后再试。
      return retryDelay;
    } finally {
      _running = false;
    }
  }

  static Future<String> _readInstalledVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }
}
