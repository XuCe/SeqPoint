import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

void main() {
  testWidgets('恢复忙期间主壳不读已关闭数据库，热键和托盘不创建或退出', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    var closed = false;
    final hotkeys = TestHotkeys();
    final tray = TestTray();
    const native = MethodChannel('window_manager');
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native,
        (call) async { calls.add(call.method); return null; });
    addTearDown(() async {
      if (!closed) boot.dispose();
      await hotkeys.events.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    });
    Widget app(bool busy) => AppScope(database: boot.db, restoring: busy,
        noteService: boot.noteService, notes: boot.notes, items: boot.items,
        tags: boot.tags, search: boot.search, windows: DesktopWindowService(),
        child: MaterialApp(home: MainPanel(hotkeys: hotkeys, tray: tray)));
    await tester.pumpWidget(app(false));
    await tester.pumpAndSettle();
    boot.dispose(); closed = true;
    await tester.pumpWidget(app(true));
    hotkeys.events.add(HotkeyAction.newNote);
    tray.quick?.call(); tray.quit?.call();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(calls.where((c) => c == 'destroy' || c == 'show'), isEmpty);
    expect(find.byType(TextField), findsNothing);
    expect(hotkeys.releases, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('退出开始即向Root标记，异步清理完成后释放标记', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys();
    final tray = TestTray()..gate = Completer<void>();
    final states = <bool>[];
    const native = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, (_) async => null);
    addTearDown(() async {
      boot.dispose(); await hotkeys.events.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(native, null);
    });
    await tester.pumpWidget(AppScope(database: boot.db, onQuittingChanged: states.add,
        noteService: boot.noteService, notes: boot.notes, items: boot.items,
        tags: boot.tags, search: boot.search, windows: DesktopWindowService(),
        child: MaterialApp(home: MainPanel(hotkeys: hotkeys, tray: tray))));
    await tester.pumpAndSettle();
    tray.quit!.call();
    await tester.pump();
    expect(states, [true]);
    tray.gate!.complete();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(states, [true, false]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('移动壳恢复忙期间不构建读取旧库的数据页面', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    await tester.pumpWidget(_mobileApp(boot, false));
    await tester.pumpAndSettle();
    boot.dispose();
    await tester.pumpWidget(_mobileApp(boot, true));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

Widget _mobileApp(Bootstrap boot, bool busy, {GlobalKey<NavigatorState>? navigator}) =>
    MaterialApp(navigatorKey: navigator,
        builder: (_, child) => AppScope(database: boot.db, restoring: busy,
            noteService: boot.noteService, notes: boot.notes, items: boot.items,
            tags: boot.tags, search: boot.search, child: child!),
        home: const MobileShell());
