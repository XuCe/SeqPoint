import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/shared/item_editor_page.dart';
import 'package:seqpoint_app/settings/hotkey_settings_page.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'global_hotkey_support.dart';

void main() {
  for (final action in [HotkeyAction.newNote, HotkeyAction.clipboardToNote, HotkeyAction.openSearch]) {
    testWidgets('$action不叠加在未保存的事项编辑器上', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      final hotkeys = TestHotkeys();
      addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
      final note = boot.noteService.capture('事项草稿原文');
      final item = boot.noteService.lineToItem(note.id, 0);
      const channel = MethodChannel('window_manager');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async =>
        call.method == 'isMinimized' ? false : null);
      var reads = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') { reads++; return {'text': '剪贴板'}; }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      await tester.pumpWidget(hotkeyApp(boot, hotkeys));
      await tester.tap(find.text('全部事项')); await tester.pumpAndSettle();
      await tester.tap(find.text('事项草稿原文')); await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '未保存事项草稿');
      hotkeys.events.add(action); await tester.pumpAndSettle();
      expect(find.byType(ItemEditorPage), findsOneWidget);
      expect(find.text('未保存事项草稿'), findsOneWidget);
      expect(reads, 0);
      await tester.tap(find.text('保存')); await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, '未保存事项草稿');
      expect(boot.notes.active(), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('注册尚未完成即销毁主面板，晚到的绑定仍会释放', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys()..gate = Completer<void>();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    await tester.pumpWidget(const SizedBox.shrink());
    hotkeys.gate!.complete();
    await tester.pumpAndSettle();
    expect(hotkeys.bound, isEmpty);
    expect(hotkeys.events.hasListener, isFalse);
    expect(hotkeys.releases, greaterThanOrEqualTo(2));
  });
  testWidgets('只注册四个全局动作，单项失败保留其他绑定，销毁后释放', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys()..failOn = HotkeyAction.clipboardToNote;
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    await tester.pumpAndSettle();
    expect(hotkeys.bound.keys.toSet(), {
      HotkeyAction.toggleQuickNote, HotkeyAction.newNote, HotkeyAction.openSearch,
    });
    expect(find.text('部分全局快捷键未能启用，请在设置中查看。'), findsOneWidget);
    await tester.tap(find.text('设置')); await tester.pumpAndSettle();
    await tester.tap(find.text('快捷键')); await tester.pumpAndSettle();
    final shown = tester.widget<HotkeySettingsPage>(find.byType(HotkeySettingsPage));
    expect(shown.bindings!.keys.toSet(), hotkeys.bound.keys.toSet());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(hotkeys.bound, isEmpty);
    expect(hotkeys.events.hasListener, isFalse);
    expect(hotkeys.releases, greaterThanOrEqualTo(1));
  });
  testWidgets('全局搜索自动聚焦并保留查询，可打开并保存命中的事项', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    final note = boot.noteService.capture('原始行');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.items.update(item.copyWith(title: '搜索结果事项'));
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async =>
      call.method == 'isMinimized' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    hotkeys.events.add(HotkeyAction.openSearch);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(find.byType(TextField), '结果');
    hotkeys.events.add(HotkeyAction.openSearch);
    await tester.pumpAndSettle();
    expect(find.text('结果'), findsOneWidget);
    await tester.tap(find.text('搜索结果事项'));
    await tester.pumpAndSettle();
    expect(tester.widget<ItemEditorPage>(find.byType(ItemEditorPage)).itemId, item.id);
    await tester.enterText(find.byType(TextFormField), '全局搜索编辑后');
    await tester.pump(); await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.title, '全局搜索编辑后');
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('剪贴板空内容不建便签，保留原文换行且重复触发不覆盖编辑', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    final messenger = tester.binding.defaultBinaryMessenger;
    const channel = MethodChannel('window_manager');
    messenger.setMockMethodCallHandler(channel, (call) async =>
      call.method == 'isMinimized' ? false : null);
    var text = '  \n';
    var fail = false;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method != 'Clipboard.getData') return null;
      if (fail) throw PlatformException(code: 'clipboard_failed');
      return {'text': text};
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    hotkeys.events.add(HotkeyAction.clipboardToNote);
    await tester.pumpAndSettle();
    expect(find.text('剪贴板中没有可用文字。'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    text = ' 剪贴板原文\n第二行 ';
    hotkeys.events.add(HotkeyAction.clipboardToNote);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, text);
    await tester.enterText(find.byType(TextField), '用户已修改');
    hotkeys.events.add(HotkeyAction.clipboardToNote);
    await tester.pumpAndSettle();
    expect(find.text('用户已修改'), findsOneWidget);
    await tester.tap(find.text('保存')); await tester.pumpAndSettle();
    expect(boot.notes.active().single.rawContent, '用户已修改');
    fail = true;
    hotkeys.events.add(HotkeyAction.clipboardToNote);
    await tester.pumpAndSettle();
    expect(find.text('全局快捷键执行失败，请重试。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('全局新建自动聚焦，重复触发保留输入，取消不落库，保存只建一份', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys();
    addTearDown(boot.dispose); addTearDown(hotkeys.events.close);
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async =>
      call.method == 'isMinimized' ? false : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    hotkeys.events.add(HotkeyAction.newNote);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isTrue);
    await tester.enterText(find.byType(TextField), '保留未保存输入');
    hotkeys.events.add(HotkeyAction.newNote);
    await tester.pumpAndSettle();
    expect(find.text('保留未保存输入'), findsOneWidget);
    expect(boot.notes.active(), isEmpty);
    await tester.pageBack(); await tester.pumpAndSettle();
    expect(boot.notes.active(), isEmpty);
    hotkeys.events.add(HotkeyAction.newNote);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '全局新建已保存');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.rawContent, '全局新建已保存');
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('全局唤起后台可见窗口，前台再次触发才收起，隐藏后可重新唤起', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys();
    addTearDown(boot.dispose);
    addTearDown(hotkeys.events.close);
    var visible = true;
    var focused = false;
    var fail = false;
    final calls = <String>[];
    const channel = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'show' && fail) throw PlatformException(code: 'show_failed');
      if (call.method == 'isVisible') return visible;
      if (call.method == 'isFocused') return focused;
      if (call.method == 'isMinimized') return false;
      if (call.method == 'show') visible = true;
      if (call.method == 'focus') focused = true;
      if (call.method == 'hide') { visible = false; focused = false; }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(hotkeyApp(boot, hotkeys));
    hotkeys.events.add(HotkeyAction.toggleQuickNote);
    await tester.pumpAndSettle();
    expect(calls, containsAllInOrder(['show', 'focus']));
    expect(calls, isNot(contains('hide')));
    hotkeys.events.add(HotkeyAction.toggleQuickNote);
    await tester.pumpAndSettle();
    expect(visible, isFalse);
    hotkeys.events.add(HotkeyAction.toggleQuickNote);
    await tester.pumpAndSettle();
    expect(visible && focused, isTrue);
    visible = false;
    fail = true;
    hotkeys.events.add(HotkeyAction.toggleQuickNote);
    await tester.pumpAndSettle();
    expect(find.text('全局快捷键执行失败，请重试。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
