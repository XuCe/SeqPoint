import 'dart:async';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:ota_update/ota_update.dart';

import 'github_release.dart';
import 'win_sparkle.dart';

final fullUpdateInstaller = FullUpdateInstaller();

class FullUpdateInstaller extends ChangeNotifier with UpdaterListener {
  FullUpdateInstaller({
    TargetPlatform? platform,
    AutoUpdater? desktop,
    OtaUpdate Function()? otaFactory,
    WinSparkle? Function()? winSparkle,
  }) : platform = platform ?? defaultTargetPlatform,
       _desktop = desktop,
       _otaFactory = otaFactory ?? OtaUpdate.new,
       _openWinSparkle = winSparkle ?? WinSparkle.open;
  final TargetPlatform platform;
  AutoUpdater? _desktop;
  bool _listening = false;
  final WinSparkle? Function() _openWinSparkle;
  WinSparkle? _winSparkle;
  bool _winSparkleOpened = false;
  // 同一更新源只交给原生更新器一次：插件每次设置都会重新初始化 WinSparkle，
  // 而初始化会清理已下载的安装包。
  String? _feedUrl;
  final OtaUpdate Function() _otaFactory;
  OtaUpdate? _ota;
  StreamSubscription<OtaEvent>? _subscription;
  double? progress;
  bool downloading = false;
  bool busy = false;
  String message = '';
  Future<void> Function()? onQuit;
  Future<void> Function()? onPrepare;

  Future<void> install(FullRelease release) async {
    if (busy) return;
    if (platform == TargetPlatform.android) {
      await _installAndroid(release);
      return;
    }
    if (release.downloadUrl == null ||
        release.appcastUrl == null ||
        (platform != TargetPlatform.windows &&
            platform != TargetPlatform.macOS)) {
      throw StateError('此平台尚未提供可安装版本');
    }
    if (onQuit == null) throw StateError('安装退出回调尚未就绪');
    busy = true;
    notifyListeners();
    try {
      await onPrepare?.call();
      final desktop = _desktop ??= autoUpdater;
      if (!_listening) {
        desktop.addListener(this);
        _listening = true;
      }
      final sparkle = platform == TargetPlatform.windows ? _sparkle() : null;
      // 必须在插件初始化 WinSparkle 之前关闭自动检查，否则它会另弹询问。
      sparkle?.disableAutomaticChecks();
      final feed = release.appcastUrl.toString();
      if (feed != _feedUrl) {
        await desktop.setFeedURL(feed);
        _feedUrl = feed;
      }
      await desktop.setScheduledCheckInterval(0);
      if (sparkle != null) {
        sparkle.checkAndInstall();
        message = '正在下载新版本，完成后自动安装并重新打开';
      } else {
        await desktop.checkForUpdates(inBackground: false);
        message = '请在更新窗口中确认下载与安装';
      }
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  WinSparkle? _sparkle() {
    if (!_winSparkleOpened) {
      _winSparkle = _openWinSparkle();
      _winSparkleOpened = true;
    }
    return _winSparkle;
  }

  Future<void> _installAndroid(FullRelease release) async {
    if (release.downloadUrl == null || release.sha256 == null) {
      throw StateError('安装包或校验信息不完整');
    }
    busy = downloading = true;
    progress = null;
    message = '正在下载安装包…';
    notifyListeners();
    try {
      await _subscription?.cancel();
      _ota = _otaFactory();
      _subscription = _ota!
          .execute(
            release.downloadUrl.toString(),
            destinationFilename: 'seqpoint-${release.version}.apk',
            sha256checksum: release.sha256,
            usePackageInstaller: true,
          )
          .listen(
            _onOta,
            onError: (Object _) =>
                _onOta(OtaEvent(OtaStatus.INTERNAL_ERROR, null)),
          );
    } catch (_) {
      busy = downloading = false;
      notifyListeners();
      rethrow;
    }
  }

  void _onOta(OtaEvent event) {
    downloading = event.status == OtaStatus.DOWNLOADING;
    busy = downloading || event.status == OtaStatus.INSTALLING;
    progress = downloading
        ? (double.tryParse(event.value ?? '')?.clamp(0, 100) ?? 0) / 100
        : null;
    message = switch (event.status) {
      OtaStatus.DOWNLOADING => '正在下载 ${(progress! * 100).round()}%',
      OtaStatus.INSTALLING => '下载已校验，请按系统提示确认安装',
      OtaStatus.INSTALLATION_DONE => '安装完成，请重新打开应用',
      OtaStatus.PERMISSION_NOT_GRANTED_ERROR => '请允许此应用安装更新，再重试',
      OtaStatus.CHECKSUM_ERROR => '安装包校验失败，已停止安装，请重新下载',
      OtaStatus.CANCELED => '已取消下载',
      OtaStatus.INSTALLATION_ERROR => '安装未完成，请确认安装权限后重试',
      _ => '下载失败，请检查网络后重试',
    };
    notifyListeners();
  }

  Future<void> cancelDownload() async {
    if (!downloading) return;
    await _ota?.cancel();
    await _subscription?.cancel();
    _onOta(OtaEvent(OtaStatus.CANCELED, null));
  }

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? item) {
    unawaited(
      onQuit?.call().catchError((Object _) {
        message = '暂时无法安全退出，请稍后重试安装';
        notifyListeners();
      }),
    );
  }

  @override
  void onUpdaterError(UpdaterError? error) {
    message = '更新失败，请检查网络后重试';
    notifyListeners();
  }

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {}
  @override
  void onUpdaterUpdateAvailable(AppcastItem? item) {}
  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    message = '暂未发现可安装更新';
    notifyListeners();
  }

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? item) {
    message = '已下载，安装时将退出并重新打开应用';
    notifyListeners();
  }

  @override
  void dispose() {
    if (_listening) _desktop?.removeListener(this);
    unawaited(_subscription?.cancel());
    if (downloading) unawaited(_ota?.cancel());
    super.dispose();
  }
}
