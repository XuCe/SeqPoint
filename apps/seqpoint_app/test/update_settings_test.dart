import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/update_settings_page.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class FakeUpdater implements ShorebirdUpdater {
  @override
  bool isAvailable = true;
  UpdateStatus status = UpdateStatus.outdated;
  int downloads = 0;
  bool failCheck = false;
  bool failDownload = false;
  bool staged = true;
  Completer<UpdateStatus>? pending;

  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async {
    if (failCheck) throw Exception('offline');
    return pending?.future ?? status;
  }
  @override
  Future<void> update({UpdateTrack? track}) async {
    downloads++;
    if (failDownload) throw Exception('offline');
    if (staged) status = UpdateStatus.restartRequired;
  }

  @override
  Future<Patch?> readCurrentPatch() async => null;
  @override
  Future<Patch?> readNextPatch() async => Patch(number: 1);
}

void main() {
  testWidgets('检查失败后可以重试', (tester) async {
    final updater = FakeUpdater()..failCheck = true;
    await tester.pumpWidget(MaterialApp(home: UpdateSettingsPage(updater: updater)));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('检查失败，请检查网络后重试'), findsOneWidget);
    updater.failCheck = false;
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现可用更新'), findsOneWidget);
  });
  for (final fails in [true, false]) {
    testWidgets('下载未就绪时不误报成功，异常=$fails', (tester) async {
      final updater = FakeUpdater()..failDownload = fails..staged = false;
      await tester.pumpWidget(MaterialApp(home: UpdateSettingsPage(updater: updater)));
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载更新'));
      await tester.pumpAndSettle();
      expect(find.text('更新已就绪，下次启动生效'), findsNothing);
      expect(find.text(fails ? '下载失败，请检查网络后重试' : '更新尚未就绪，请稍后重试'), findsOneWidget);
      updater.failDownload = false;
      updater.staged = true;
      await tester.tap(find.text('下载更新'));
      await tester.pumpAndSettle();
      expect(find.text('更新已就绪，下次启动生效'), findsOneWidget);
    });
  }
  testWidgets('检查中禁用按钮，离开页面后完成不报错', (tester) async {
    final pending = Completer<UpdateStatus>();
    final updater = FakeUpdater()..pending = pending;
    await tester.pumpWidget(MaterialApp(home: UpdateSettingsPage(updater: updater)));
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
    pending.complete(UpdateStatus.outdated);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  for (final entry in {
    UpdateStatus.upToDate: '当前已是最新补丁',
    UpdateStatus.restartRequired: '更新已就绪，下次启动生效',
    UpdateStatus.unavailable: '此安装包暂不支持热更新',
  }.entries) {
    testWidgets('显示 ${entry.key.name} 且不下载', (tester) async {
      final updater = FakeUpdater()..status = entry.key;
      await tester.pumpWidget(MaterialApp(
        home: UpdateSettingsPage(updater: updater),
      ));
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(updater.downloads, 0);
    });
  }
  testWidgets('普通构建禁用热更新', (tester) async {
    final updater = FakeUpdater()..isAvailable = false;
    await tester.pumpWidget(MaterialApp(
      home: UpdateSettingsPage(updater: updater),
    ));
    expect(find.text('热更新不可用'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
  testWidgets('补丁需确认下载，下载成功后提示重启', (tester) async {
    final updater = FakeUpdater();
    await tester.pumpWidget(MaterialApp(
      home: UpdateSettingsPage(updater: updater),
    ));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(find.text('发现可用更新'), findsOneWidget);
    expect(updater.downloads, 0);
    await tester.tap(find.text('下载更新'));
    await tester.pumpAndSettle();
    expect(updater.downloads, 1);
    expect(find.text('更新已就绪，下次启动生效'), findsOneWidget);
  });
}

