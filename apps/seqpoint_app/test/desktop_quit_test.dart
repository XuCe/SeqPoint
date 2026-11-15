import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/updates/app_relaunch.dart';
import 'package:seqpoint_app/updates/full_update_installer.dart';

import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

void main() {
  late Bootstrap boot;
  late TestHotkeys hotkeys;
  late TestTray tray;
  late List<String> calls;

  setUp(() async {
    boot = await Bootstrap.run(dbPath: ':memory:');
    hotkeys = TestHotkeys();
    tray = TestTray();
    calls = [];
  });

  Future<void> mount(
    WidgetTester tester, {
    Future<void> Function()? beforeQuit,
    AppRelauncher? relauncher,
  }) async {
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'isMinimized' ? false : null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      boot.dispose();
      await hotkeys.events.close();
    });
    await tester.pumpWidget(AppScope(
      noteService: boot.noteService, notes: boot.notes, items: boot.items,
      tags: boot.tags, search: boot.search, beforeQuit: beforeQuit,
      child: MaterialApp(home: MainPanel(
        hotkeys: hotkeys, tray: tray, relauncher: relauncher)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('托盘退出立即隐藏主窗与托盘图标，同步卡住时最多等几秒', (tester) async {
    final stuck = Completer<void>();
    await mount(tester, beforeQuit: () => stuck.future);
    tray.quit!();
    await tester.pump();
    expect(calls, contains('hide'));
    expect(tray.disposals, 1);
    expect(calls, isNot(contains('destroy')));
    await tester.pump(const Duration(seconds: 3));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'destroy'), hasLength(1));
    expect(hotkeys.bound, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('同步关闭失败时恢复托盘与主窗，可再次退出', (tester) async {
    var reject = true;
    await mount(tester, beforeQuit: () async {
      if (reject) throw StateError('sync');
    });
    tray.quit!();
    await tester.pumpAndSettle();
    expect(calls, containsAllInOrder(['hide', 'show']));
    expect(calls, isNot(contains('destroy')));
    expect(find.text('同步仍在关闭中，请稍后重试退出'), findsOneWidget);
    reject = false;
    tray.quit!();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'destroy'), hasLength(1));
    expect(tray.disposals, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('立即重启：收尾完成后再拉起新进程并退出，普通退出不拉起', (tester) async {
    final spawned = <bool>[];
    final relauncher = AppRelauncher(supported: true, spawn: () async {
      spawned.add(hotkeys.bound.isEmpty && tray.disposals == 1 &&
          !calls.contains('destroy'));
    });
    await mount(tester, relauncher: relauncher);
    expect(relauncher.available, isTrue);
    unawaited(relauncher.restart());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(spawned, [true]);
    expect(calls.where((call) => call == 'destroy'), hasLength(1));
    tray.quit!();
    await tester.pumpAndSettle();
    expect(spawned, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(relauncher.available, isFalse);
  });

  testWidgets('安装更新请求退出时，正在编辑则不打断', (tester) async {
    await mount(tester);
    final navigator = Navigator.of(tester.element(find.byType(MainPanel)));
    unawaited(navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('编辑中')))));
    await tester.pumpAndSettle();
    await expectLater(fullUpdateInstaller.onQuit!(), throwsStateError);
    expect(calls, isNot(contains('destroy')));
    expect(tray.disposals, 0);
    navigator.pop();
    await tester.pumpAndSettle();
    final quit = fullUpdateInstaller.onQuit!();
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    await quit;
    expect(calls.where((call) => call == 'destroy'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('不支持的平台不提供重启', () async {
    final relauncher = AppRelauncher(supported: false, spawn: () async {})
      ..onRestart = () async {};
    expect(relauncher.available, isFalse);
    await expectLater(relauncher.restart(), throwsStateError);
  });
}
