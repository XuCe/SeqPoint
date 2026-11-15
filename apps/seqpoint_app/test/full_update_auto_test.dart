import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/updates/full_update_auto.dart';
import 'package:seqpoint_app/updates/full_update_installer.dart';
import 'package:seqpoint_app/updates/github_release.dart';

import 'github_release_test.dart' show release;

class _Installer extends FullUpdateInstaller {
  final installed = <String>[];
  Object? failure;
  @override
  Future<void> install(FullRelease release) async {
    installed.add(release.version.toString());
    if (failure case final error?) throw error;
  }
}

void main() {
  late _Installer installer;
  var idle = true, enabled = true;
  var tag = 'v0.2.0';
  Object? offline;

  FullUpdateAutoChecker checker() => FullUpdateAutoChecker(
    installer: installer,
    canStart: () => idle,
    enabled: () async => enabled,
    installedVersion: () async => '0.1.0+1',
    loadRelease: () async {
      if (offline case final error?) throw error;
      return FullRelease.fromJson(release(tag: tag), Abi.windowsX64);
    },
  );

  setUp(() {
    installer = _Installer();
    idle = enabled = true;
    tag = 'v0.2.0';
    offline = null;
  });
  tearDown(() => installer.dispose());

  test('发现新版本即安装，已是最新或关闭开关时不安装', () async {
    final auto = checker();
    expect(await auto.runOnce(), auto.interval);
    expect(installer.installed, ['0.2.0']);
    tag = 'v0.1.0';
    expect(await auto.runOnce(), auto.interval);
    enabled = false;
    tag = 'v0.3.0';
    expect(await auto.runOnce(), auto.interval);
    expect(installer.installed, ['0.2.0']);
  });

  test('正在编辑、网络失败或暂不能退出时稍后重试', () async {
    final auto = checker();
    idle = false;
    expect(await auto.runOnce(), auto.retryDelay);
    expect(installer.installed, isEmpty);
    idle = true;
    offline = Exception('offline');
    expect(await auto.runOnce(), auto.retryDelay);
    offline = null;
    installer.failure = StateError('请先保存并关闭所有便签窗口');
    expect(await auto.runOnce(), auto.retryDelay);
    installer.failure = null;
    expect(await auto.runOnce(), auto.interval);
    expect(installer.installed, ['0.2.0', '0.2.0']);
  });

  testWidgets('启动后延迟检查，常驻期间按间隔复查，释放后停止', (tester) async {
    tag = 'v0.1.0';
    final auto = checker()..start();
    await tester.pump(auto.firstDelay - const Duration(seconds: 1));
    expect(installer.installed, isEmpty);
    tag = 'v0.2.0';
    await tester.pump(const Duration(seconds: 1));
    expect(installer.installed, ['0.2.0']);
    await tester.pump(auto.interval);
    expect(installer.installed, ['0.2.0', '0.2.0']);
    auto.dispose();
    await tester.pump(auto.interval * 2);
    expect(installer.installed, hasLength(2));
  });
}
