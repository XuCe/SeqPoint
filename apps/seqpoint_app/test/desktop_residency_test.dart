import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:window_manager/window_manager.dart';
import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

void main() {
  testWidgets('注册未完成时退出会等候，晚到的快捷键也在销毁前注销', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys()..gate = Completer<void>();
    final tray = TestTray(); final calls = <String>[];
    var releasedAtDestroy = false;
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'destroy') {
        releasedAtDestroy = hotkeys.bound.isEmpty &&
          hotkeys.releases == 1 && tray.disposals == 1;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys, tray: tray));
    await tester.pumpAndSettle();
    tray.quit!(); await tester.pumpAndSettle();
    expect(calls.contains('destroy'), isFalse);
    expect(hotkeys.releases, 0);
    hotkeys.gate!.complete(); await tester.pumpAndSettle();
    await tester.runAsync(() async {}); await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'destroy'), hasLength(1));
    expect(releasedAtDestroy, isTrue);
    expect(hotkeys.events.hasListener, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final failed in [true, false]) {
    testWidgets('托盘${failed ? '初始化失败不拦截关闭' : '初始化晚于销毁时仍清理'}', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      final hotkeys = TestHotkeys(); final tray = TestTray()..failInit = failed;
      if (!failed) tray.gate = Completer<void>();
      addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
      final calls = <MethodCall>[];
      const channel = MethodChannel('window_manager');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call); return null; });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(hotkeyApp(boot, hotkeys, tray: tray));
      await tester.pumpAndSettle();
      if (failed) {
        expect(find.text('托盘未能启用，关闭窗口将退出应用。'), findsOneWidget);
        (tester.state(find.byType(MainPanel)) as WindowListener).onWindowClose();
        await tester.pumpAndSettle();
        await tester.runAsync(() async {}); await tester.pumpAndSettle();
        expect(calls.any((c) => c.method == 'hide'), isFalse);
        expect(calls.any((c) => c.method == 'destroy'), isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      if (!failed) tray.gate!.complete();
      await tester.pumpAndSettle();
      expect(calls.any((c) => c.method == 'setPreventClose' &&
        c.arguments['isPreventClose'] == true), isFalse);
      expect(tray.disposals, 1);
    });
  }

  testWidgets('托盘可唤起并保留草稿，退出先释放快捷键与托盘且只执行一次', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys(); final tray = TestTray();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    final calls = <String>[]; final releasedAtDestroy = <bool>[];
    final destroyed = Completer<void>();
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'destroy') {
        releasedAtDestroy.add(hotkeys.bound.isEmpty && tray.disposals == 1 &&
          !hotkeys.events.hasListener);
        destroyed.complete();
      }
      return call.method == 'isMinimized' ? false : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys, tray: tray));
    await tester.pumpAndSettle();
    tray.open!(); await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'show'), hasLength(1));
    expect(calls.where((c) => c == 'focus'), hasLength(1));
    tray.quick!(); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '托盘唤起保留的草稿');
    tray.open!(); tray.quick!(); await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('托盘唤起保留的草稿'), findsOneWidget);
    tray.quit!(); tray.quit!(); await tester.pumpAndSettle();
    // Stream.cancel 的已完成共享 Future 使用根 Zone，需同时推进真实微任务。
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(destroyed.isCompleted, isTrue);
    expect(releasedAtDestroy, [true]);
    final shown = calls.where((c) => c == 'show').length;
    hotkeys.events.add(HotkeyAction.newNote); await tester.pumpAndSettle();
    expect(calls.where((c) => c == 'show'), hasLength(shown));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tray.disposals, 1);
  });

  testWidgets('关闭主窗口仅隐藏，保留草稿及四项全局快捷键', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys(); final tray = TestTray();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    final calls = <MethodCall>[];
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'isMinimized' ? false : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys, tray: tray));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'setPreventClose'), hasLength(1));
    expect(calls.where((c) => c.method == 'setPreventClose').single.arguments,
      {'isPreventClose': true});
    final listener = tester.state(find.byType(MainPanel)) as WindowListener;
    hotkeys.events.add(HotkeyAction.newNote); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '关闭后仍保留的草稿');
    listener.onWindowClose(); await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'hide'), hasLength(1));
    expect(calls.any((c) => c.method == 'destroy'), isFalse);
    expect(hotkeys.bound, hasLength(4));
    expect(hotkeys.releases, 0);
    expect(find.text('关闭后仍保留的草稿'), findsOneWidget);
    expect(boot.notes.active(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tray.disposals, 1);
  });
}
