import 'dart:ffi';
import 'dart:async';

import 'package:ota_update/ota_update.dart';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/updates/full_update_installer.dart';
import 'package:seqpoint_app/updates/github_release.dart';

import 'github_release_test.dart' show release;

class DesktopUpdater extends Fake implements AutoUpdater {
  final calls = <String>[];
  UpdaterListener? listener;
  @override
  void addListener(UpdaterListener listener) => this.listener = listener;
  @override
  void removeListener(UpdaterListener listener) => this.listener = null;
  @override
  Future<void> setFeedURL(String url) async {
    calls.add(url);
  }

  @override
  Future<void> setScheduledCheckInterval(int interval) async {
    calls.add('$interval');
  }

  @override
  Future<void> checkForUpdates({bool? inBackground}) async {
    calls.add('check:$inBackground');
  }
}

class AndroidUpdater extends Fake implements OtaUpdate {
  final events = StreamController<OtaEvent>.broadcast(sync: true);
  String? checksum;
  bool packageInstaller = false, cancelled = false;
  @override
  Stream<OtaEvent> execute(
    String url, {
    Map<String, String> headers = const {},
    String? androidProviderAuthority,
    String? destinationFilename,
    String? sha256checksum,
    bool usePackageInstaller = false,
  }) {
    checksum = sha256checksum;
    packageInstaller = usePackageInstaller;
    return events.stream;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

void main() {
  test('desktop preparation serializes repeated install clicks', () async {
    final native = DesktopUpdater();
    final installer = FullUpdateInstaller(
      platform: TargetPlatform.windows,
      desktop: native,
    );
    addTearDown(installer.dispose);
    final ready = Completer<void>();
    var preparations = 0;
    installer.onQuit = () async {};
    installer.onPrepare = () {
      preparations++;
      return ready.future;
    };
    final update = FullRelease.fromJson(release(), Abi.windowsX64);
    final first = installer.install(update);
    final second = installer.install(update);
    ready.complete();
    await Future.wait([first, second]);
    expect(preparations, 1);
    expect(native.calls.where((call) => call == 'check:false').length, 1);
  });

  test('Android installation waits for confirmation and retries with a fresh operation', () async {
    final natives = <AndroidUpdater>[];
    final installer = FullUpdateInstaller(
      platform: TargetPlatform.android,
      otaFactory: () {
        final n = AndroidUpdater();
        natives.add(n);
        return n;
      },
    );
    addTearDown(() async {
      installer.dispose();
      for (final n in natives) {
        await n.events.close();
      }
    });
    final update = FullRelease.fromJson(release(), Abi.androidArm64);
    await installer.install(update);
    natives.last.events.add(OtaEvent(OtaStatus.INSTALLING, null));
    expect(installer.busy, isTrue);
    expect(installer.downloading, isFalse);
    expect(installer.message, contains('确认安装'));
    await installer.cancelDownload();
    expect(natives.last.cancelled, isFalse);
    natives.last.events.add(OtaEvent(OtaStatus.CHECKSUM_ERROR, null));
    expect(installer.busy, isFalse);
    expect(installer.message, contains('校验失败'));
    await installer.install(update);
    expect(natives.length, 2);
    natives.last.events.add(OtaEvent(OtaStatus.INSTALLATION_DONE, null));
    expect(installer.message, contains('安装完成'));
  });
  test(
    'unsupported platforms and missing packages never launch an installer',
    () async {
      final installer = FullUpdateInstaller(platform: TargetPlatform.iOS);
      addTearDown(installer.dispose);
      await expectLater(
        installer.install(FullRelease.fromJson(release(), Abi.iosArm64)),
        throwsStateError,
      );
    },
  );

  test(
    'Android verifies the package, shows progress, and cancels native download',
    () async {
      final native = AndroidUpdater();
      addTearDown(native.events.close);
      final installer = FullUpdateInstaller(
        platform: TargetPlatform.android,
        otaFactory: () => native,
      );
      addTearDown(installer.dispose);
      await installer.install(
        FullRelease.fromJson(release(), Abi.androidArm64),
      );
      expect(native.checksum, 'a' * 64);
      expect(native.packageInstaller, isTrue);
      native.events.add(OtaEvent(OtaStatus.DOWNLOADING, '35'));
      expect(installer.progress, 0.35);
      expect(installer.busy, isTrue);
      await installer.cancelDownload();
      expect(native.cancelled, isTrue);
      expect(installer.busy, isFalse);
    },
  );

  test(
    'desktop uses the signed native installer feed and safe quit callback',
    () async {
      final native = DesktopUpdater();
      final installer = FullUpdateInstaller(
        platform: TargetPlatform.windows,
        desktop: native,
      );
      addTearDown(installer.dispose);
      var quits = 0;
      installer.onQuit = () async {
        quits++;
      };
      final update = FullRelease.fromJson(release(), Abi.windowsX64);
      await installer.install(update);
      expect(native.calls, [update.appcastUrl.toString(), '0', 'check:false']);
      expect(quits, 0);
      native.listener!.onUpdaterBeforeQuitForUpdate(null);
      await Future<void>.delayed(Duration.zero);
      expect(quits, 1);
    },
  );
}
