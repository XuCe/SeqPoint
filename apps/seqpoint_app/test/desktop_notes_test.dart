import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:seqpoint_app/shared/note_card.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
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
    await tester.tap(find.text('新建便签'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(TextButton, '保存');
    final controller = tester.widget<TextField>(find.byType(TextField)).controller!;
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
  for (final section in ['今日', '全部事项']) {
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
      if (section == '全部事项') {
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
      await tester.tap(find.text('新建便签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '快捷键保存');
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
    await tester.tap(find.text('新建便签'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), '尚未保存');
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
      await tester.tap(find.text('新建便签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '失败后仍保留');
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
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
    await tester.tap(find.byTooltip('编辑便签'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '原始正文\n保留待办',
    );
    await tester.enterText(find.byType(TextField), '修改后的正文\n保留待办');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.active(), hasLength(1));
    expect(boot.notes.byId(note.id)!.rawContent, '修改后的正文\n保留待办');
    expect(boot.items.byNote(note.id).single.id, item.id);
    expect(find.text('修改后的正文'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑便签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '只保留一行正文');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.byId(note.id)!.rawContent, '只保留一行正文');
    expect(find.text('保留待办'), findsOneWidget);
    await tester.tap(find.text('保留待办'));
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.isDone, isTrue);
  });
  testWidgets('点击便签卡片打开对应的独立窗口', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('需要打开的便签');
    SharedPreferences.setMockInitialValues({});
    const channel = MethodChannel('mixin.one/desktop_multi_window');
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
    await tester.tap(find.text('便签墙'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    final create = calls.where((c) => c.method == 'createWindow');
    expect(create, hasLength(1));
    final arguments = create.single.arguments as Map;
    expect(jsonDecode(arguments['arguments'] as String)['noteId'], note.id);
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'createWindow'), hasLength(1));
    live.clear();
    await tester.tap(find.byType(NoteCard));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'createWindow'), hasLength(2));
  });
  testWidgets('桌面新建便签后保存并显示在便签墙', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('新建便签'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '桌面记录\n记得回复客户');
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.rawContent, '桌面记录\n记得回复客户');
    expect(find.byType(NoteCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
