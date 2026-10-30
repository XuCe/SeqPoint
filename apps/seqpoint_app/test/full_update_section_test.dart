import 'dart:ffi';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:seqpoint_app/settings/full_update_section.dart';
import 'package:seqpoint_app/updates/full_update_installer.dart';
import 'package:seqpoint_app/updates/github_release.dart';

import 'github_release_test.dart' show release;

class Installer extends FullUpdateInstaller {
  int installs = 0;
  @override
  Future<void> install(FullRelease release) async {
    installs++;
  }
}

void main() {
  testWidgets('failed checks retry, unsupported packages never show install', (
    tester,
  ) async {
    var failed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FullUpdateSection(
            loadRelease: () async {
              if (failed) throw Exception('offline');
              return FullRelease.fromJson(release(), Abi.iosArm64);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查完整版本'));
    await tester.pumpAndSettle();
    expect(find.text('检查失败，请检查网络后重试'), findsOneWidget);
    failed = false;
    await tester.tap(find.text('检查完整版本'));
    await tester.pumpAndSettle();
    expect(find.text('此平台暂未提供可安装版本'), findsOneWidget);
    expect(find.text('下载并安装'), findsNothing);
  });
  testWidgets(
    'pending check disables duplicate requests and survives leaving',
    (tester) async {
      final pending = Completer<FullRelease>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FullUpdateSection(loadRelease: () => pending.future),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('检查完整版本'));
      await tester.pump();
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      pending.complete(FullRelease.fromJson(release(), Abi.windowsX64));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'SeqPoint',
      packageName: 'com.seqpoint.app',
      version: '0.1.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );
  testWidgets(
    'checks full version and invokes the installer without a browser',
    (tester) async {
      final installer = Installer();
      addTearDown(installer.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FullUpdateSection(
                installer: installer,
                loadRelease: () async =>
                    FullRelease.fromJson(release(), Abi.androidArm64),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前版本 0.1.0+1'), findsOneWidget);
      await tester.tap(find.text('检查完整版本'));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 0.2.0'), findsOneWidget);
      expect(find.text('新增同步功能'), findsOneWidget);
      await tester.tap(find.text('下载并安装'));
      await tester.pumpAndSettle();
      expect(installer.installs, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
