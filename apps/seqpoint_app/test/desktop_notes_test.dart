import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'note_editor_test_support.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:seqpoint_app/shared/note_card.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_core/seqpoint_core.dart' show NoteStatus;
import 'package:seqpoint_platform/seqpoint_platform.dart' show WindowFrame;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

Widget _app(Bootstrap boot, Widget child, {DesktopWindowService? windows}) =>
    AppScope(
      noteService: boot.noteService,
      notes: boot.notes,
      items: boot.items,
      tags: boot.tags,
      search: boot.search,
      windows: windows,
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('语音填充新便签后立即可保存，清空后禁用保存', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, '保存');
    final controller = noteEditor(tester).controller;
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    controller.value = const TextEditingValue(
      text: '语音确认的便签', selection: TextSelection.collapsed(offset: 7));
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    controller.clear();
    await tester.pump();
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    controller.text = '语音确认的便签';
    await tester.pump();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.rawContent, '语音确认的便签');
    expect(find.byType(NoteCard), findsOneWidget);
  });
  for (final section in ['今日', '事项']) {
    testWidgets('切回主窗口后刷新$section中的待办状态', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('跨窗完成的事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      boot.items.update(
        item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
      );
      await tester.pumpWidget(_app(boot, const MainPanel()));
      await tester.tap(find.text(section));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ItemTile>(find.byType(ItemTile)).item.isDone,
        isFalse,
      );
      boot.noteService.toggleItem(item.id);
      (tester.state(find.byType(MainPanel)) as WindowListener).onWindowFocus();
      await tester.pumpAndSettle();
      if (section == '事项') {
        expect(find.byType(ItemTile), findsNothing);
      } else {
        expect(
          tester.widget<ItemTile>(find.byType(ItemTile)).item.isDone,
          isTrue,
        );
      }
    });
  }
  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('${modifier.keyLabel}+Enter保存桌面便签', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      await tester.pumpWidget(_app(boot, const MainPanel()));
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();
      await typeNote(tester, '快捷键保存');
      await tester.pump();
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(boot.notes.active().single.rawContent, '快捷键保存');
      expect(find.byType(NoteCard), findsOneWidget);
    });
  }
  testWidgets('空内容不能保存，取消输入不会留下空便签', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNull,
    );
    await typeNote(tester, '尚未保存');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(boot.notes.active(), isEmpty);
  });

  for (final table in ['notes', 'activities']) {
    testWidgets('$table写入失败时保留输入，重试后只保存一份', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      boot.db.raw.execute(
        'CREATE TRIGGER reject_save BEFORE INSERT ON $table '
        "BEGIN SELECT RAISE(ABORT, 'test'); END;",
      );
      await tester.pumpWidget(_app(boot, const MainPanel()));
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();
      await typeNote(tester, '失败后仍保留');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(
        noteEditor(tester).controller.text,
        '失败后仍保留',
      );
      expect(find.text('保存失败，请重试。输入的内容仍在。'), findsOneWidget);
      expect(boot.notes.active(), isEmpty);
      expect(boot.db.raw.select('SELECT id FROM activities'), isEmpty);
      boot.db.raw.execute('DROP TRIGGER reject_save');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.notes.active().single.rawContent, '失败后仍保留');
      expect(boot.db.raw.select('SELECT id FROM activities'), hasLength(1));
    });
  }
  testWidgets('打开已有便签后编辑保存，不新建副本也不丢待办', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('原始正文\n保留待办');
    final item = boot.noteService.lineToItem(note.id, 1);
    await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
    await tester.tapAt(const Offset(4, 4));
    await tester.pump();
    await tester.tap(find.byTooltip('编辑便签'));
    await tester.pumpAndSettle();
    expect(
      noteEditor(tester).controller.text,
      '原始正文\n保留待办',
    );
    await typeNote(tester, '修改后的正文\n保留待办');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.active(), hasLength(1));
    expect(boot.notes.byId(note.id)!.rawContent, '修改后的正文\n保留待办');
    expect(boot.items.byNote(note.id).single.id, item.id);
    expect(find.text('修改后的正文'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑便签'));
    await tester.pumpAndSettle();
    await typeNote(tester, '只保留一行正文');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.byId(note.id)!.rawContent, '只保留一行正文');
    // 正文里删掉了待办那一行，待办跟着删除，不留下正文里没有的一行。
    expect(find.text('保留待办'), findsNothing);
    expect(boot.items.byNote(note.id), isEmpty);
    expect(boot.items.byId(item.id)!.deletedAt, isNotNull);
  });
  testWidgets('点击便签卡片打开对应的独立窗口', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('需要打开的便签');
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('mixin.one/desktop_multi_window');
    const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channels, (call) async {
      throw PlatformException(code: 'CHANNEL_NOT_FOUND');
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channels, null));
    final calls = <MethodCall>[];
    final live = <Map<String, Object>>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'createWindow') {
        live.add({'windowId': 'sticky-1', 'windowArgument': ''});
        return 'sticky-1';
      }
      if (call.method == 'getAllWindows') return List.of(live);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      _app(boot, const MainPanel(), windows: DesktopWindowService()),
    );
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    final create = calls.where((c) => c.method == 'createWindow');
    expect(create, hasLength(1));
    final arguments = create.single.arguments as Map;
    expect(arguments['hiddenAtLaunch'], true);
    expect(jsonDecode(arguments['arguments'] as String)['noteId'], note.id);
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'createWindow'), hasLength(1));
    live.clear();
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'createWindow'), hasLength(2));
  });
  testWidgets('没有独立便签窗时，便签墙卡片在面板内打开并可归档', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('面板内打开\n第二行');
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('揭走（办完收起）'));
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsNothing);
    expect(boot.notes.byId(note.id)!.status, NoteStatus.closed);
    expect(find.byType(NoteCard), findsNothing, reason: '返回后便签墙应刷新');
  });

  for (final (platform, windows, hint) in [
    (TargetPlatform.linux, false, '今天还没有带时间的事。在上面写一句试试。'),
    (TargetPlatform.windows, true, '今天还没有带时间的事。按 Alt+Shift+Space 随时记一笔。'),
    (TargetPlatform.macOS, true, '今天还没有带时间的事。按 ⌥Space 随时记一笔。'),
  ]) {
    testWidgets('今日空状态按平台提示可用的记录方式 $platform', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      await tester.pumpWidget(_app(boot, const MainPanel(),
          windows: windows ? DesktopWindowService() : null));
      await tester.pump();
      expect(find.text(hint), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('桌面新建便签后保存并显示在便签墙', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('记一笔'));
    await tester.pumpAndSettle();
    await typeNote(tester, '桌面记录\n记得回复客户');
    await tester.enterText(find.widgetWithText(TextField, '标题（选填）'), '工作跟进');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.rawContent, '桌面记录\n记得回复客户');
    expect(find.text('工作跟进'), findsOneWidget);
    expect(find.byType(NoteCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('第一张开窗尚未完成时，第二张仍能从便签墙打开', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    boot.noteService.capture('第一张');
    boot.noteService.capture('第二张');
    final windows = _OpeningWindows();
    await tester.pumpWidget(_app(boot, const MainPanel(), windows: windows));
    await tester.tap(find.text('便签'));
    await tester.pumpAndSettle();
    for (final text in ['第一张', '第一张', '第二张']) {
      await tester.tap(find.text(text));
    }
    expect(windows.requests, hasLength(2));
    expect(windows.requests.toSet(), hasLength(2));
    windows.ready.complete('window');
    await tester.pump();
  });

  testWidgets('只为手动调过大小的新建便签记住草稿窗口尺寸', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    SharedPreferences.setMockInitialValues({});
    const native = MethodChannel('window_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(native, (call) async => call.method == 'getBounds'
        ? {'x': 36.0, 'y': 44.0, 'width': 712.0, 'height': 528.0} : null);
    addTearDown(() => messenger.setMockMethodCallHandler(native, null));
    final windows = DesktopWindowService();
    await tester.pumpWidget(_app(boot, const MainPanel(), windows: windows));
    for (final title in ['手动调过窗口', '保持默认窗口']) {
      await tester.tap(find.text('记一笔'));
      await tester.pumpAndSettle();
      await typeNote(tester, title);
      if (title == '手动调过窗口') {
        for (final listener in windowManager.listeners.toList()) {
          listener.onWindowResized();
        }
      }
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final note = boot.notes.active().firstWhere((note) => note.rawContent == title);
      final frame = await windows.loadFrame(note.id);
      if (title == '手动调过窗口') {
        expect(frame!.toJson(), {'x': 36.0, 'y': 44.0, 'w': 712.0, 'h': 528.0});
      } else {
        expect(frame, isNull);
      }
    }
  });
}

class _OpeningWindows extends DesktopWindowService {
  final ready = Completer<String>();
  final requests = <String>[];

  @override
  Future<String> openSticky(String noteId, {WindowFrame? frame}) {
    requests.add(noteId);
    return ready.future;
  }
}
