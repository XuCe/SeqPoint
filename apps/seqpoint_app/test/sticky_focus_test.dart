import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/item_row.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:window_manager/window_manager.dart';

Widget _app(Bootstrap b, String id) => AppScope(
  noteService: b.noteService, notes: b.notes, items: b.items,
  tags: b.tags, search: b.search,
  child: MaterialApp(home: StickyWindow(noteId: id)));

Future<(Bootstrap, Bootstrap)> _openWindows() async {
  final dir = Directory.systemTemp.createTempSync('seqpoint_sticky_focus_');
  final local = await Bootstrap.run(dbPath: '${dir.path}/notes.db');
  final other = await Bootstrap.run(dbPath: '${dir.path}/notes.db');
  addTearDown(() {
    other.dispose();
    local.dispose();
    dir.deleteSync(recursive: true);
  });
  return (local, other);
}

void _focusWindow() {
  for (final listener in windowManager.listeners) {
    listener.onWindowFocus();
  }
}

void main() {
  testWidgets('便签获得焦点后显示另一个数据库连接保存的正文', (t) async {
    final (local, other) = await _openWindows();
    final note = local.noteService.capture('原始正文');
    await t.pumpWidget(_app(local, note.id));
    other.noteService.editContent(note.id, '其他窗口保存的正文');
    _focusWindow();
    await t.pumpAndSettle();
    expect(find.text('其他窗口保存的正文'), findsOneWidget);
    expect(find.text('原始正文'), findsNothing);
  });

  testWidgets('重复获得焦点刷新标题与事项完成状态，不重复注册监听', (t) async {
    final (local, other) = await _openWindows();
    final note = local.noteService.capture('关联事项', title: '旧标题');
    final item = local.noteService.lineToItem(note.id, 0);
    await t.pumpWidget(_app(local, note.id));
    final state = t.state(find.byType(StickyWindow));
    other.notes.update(other.notes.byId(note.id)!.copyWith(title: '外部新标题'));
    other.noteService.toggleItem(item.id);
    for (var i = 0; i < 3; i++) {
      _focusWindow();
      await t.pumpAndSettle();
    }
    expect(find.text('外部新标题'), findsOneWidget);
    expect(find.text('旧标题'), findsNothing);
    expect(t.widget<ItemRow>(find.byType(ItemRow)).isDone, isTrue);
    expect(windowManager.listeners.where((l) => identical(l, state)), hasLength(1));
  });

  testWidgets('便签销毁时移除监听，迟到的焦点回调不读库或更新界面', (t) async {
    final (local, _) = await _openWindows();
    final note = local.noteService.capture('监听释放');
    await t.pumpWidget(_app(local, note.id));
    final state = t.state(find.byType(StickyWindow));
    expect(windowManager.listeners, contains(state));
    await t.pumpWidget(const SizedBox.shrink());
    expect(windowManager.listeners, isNot(contains(state)));
    (state as WindowListener).onWindowFocus();
    _focusWindow();
    expect(t.takeException(), isNull);
  });

  testWidgets('获得焦点保留正文草稿和选区，取消后显示外部已保存内容', (t) async {
    final (local, other) = await _openWindows();
    final note = local.noteService.capture('原始正文');
    await t.pumpWidget(_app(local, note.id));
    await t.tap(find.byTooltip('编辑便签'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '本地未保存草稿');
    final controller = t.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection(baseOffset: 1, extentOffset: 4);
    final draft = controller.value;
    other.noteService.editContent(note.id, '其他窗口最新正文');
    _focusWindow();
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField)).controller, same(controller));
    expect(controller.value, draft);
    expect(local.notes.byId(note.id)!.rawContent, '其他窗口最新正文');
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('其他窗口最新正文'), findsOneWidget);
    expect(find.text('原始正文'), findsNothing);
    expect(local.notes.byId(note.id)!.rawContent, '其他窗口最新正文');
  });

  testWidgets('事项编辑中获得焦点保留草稿，取消后刷新外部事项状态', (t) async {
    final (local, other) = await _openWindows();
    final note = local.noteService.capture('原始事项');
    final item = local.noteService.lineToItem(note.id, 0);
    await t.pumpWidget(_app(local, note.id));
    await t.tap(find.byTooltip('编辑事项'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextFormField), '本地未保存事项');
    await t.tap(find.byType(SwitchListTile));
    final controller = t.widget<TextField>(find.byType(TextField)).controller!;
    controller.selection = const TextSelection.collapsed(offset: 3);
    final draft = controller.value;
    other.items.update(other.items.byId(item.id)!.copyWith(title: '外部事项修改'));
    other.noteService.toggleItem(item.id);
    _focusWindow();
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField)).controller, same(controller));
    expect(controller.value, draft);
    expect(t.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('外部事项修改'), findsOneWidget);
    expect(local.items.byId(item.id)!.title, '外部事项修改');
    expect(t.widget<ItemRow>(find.widgetWithText(ItemRow, '外部事项修改')).isDone, isTrue);
  });

  for (final mode in ['正文', '事项']) {
    testWidgets('$mode草稿在重新聚焦后可继续编辑保存，保留外部标题与完成状态', (t) async {
      final (local, other) = await _openWindows();
      final note = local.noteService.capture('原始事项', title: '原始标题');
      final item = local.noteService.lineToItem(note.id, 0);
      await t.pumpWidget(_app(local, note.id));
      await t.tap(find.byTooltip(mode == '正文' ? '编辑便签' : '编辑事项'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '正在输入的草稿');
      other.notes.update(other.notes.byId(note.id)!.copyWith(title: '外部标题'));
      other.noteService.toggleItem(item.id);
      _focusWindow();
      await t.pumpAndSettle();
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '正在输入的草稿');
      await t.enterText(find.byType(TextField), '继续完成并保存');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(find.text('外部标题'), findsOneWidget);
      expect(find.text('继续完成并保存'), findsOneWidget);
      expect(other.notes.byId(note.id)!.rawContent,
        mode == '正文' ? '继续完成并保存' : '原始事项');
      expect(other.items.byId(item.id)!.title,
        mode == '事项' ? '继续完成并保存' : '原始事项');
      expect(other.items.byId(item.id)!.isDone, isTrue);
      expect(local.notes.active(), hasLength(1));
      expect(local.items.byNote(note.id), hasLength(1));
    });
  }

  testWidgets('保存失败后聚焦不丢草稿，取消后仍显示他窗已保存数据', (t) async {
    final (local, other) = await _openWindows();
    final note = local.noteService.capture('原始正文');
    await t.pumpWidget(_app(local, note.id));
    await t.tap(find.byTooltip('编辑便签'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), '失败后保留的草稿');
    final controller = t.widget<TextField>(find.byType(TextField)).controller!;
    final draft = controller.value;
    other.noteService.editContent(note.id, '他窗已保存数据');
    final activityCount = local.db.raw.select('SELECT id FROM activities').length;
    local.db.raw.execute('CREATE TRIGGER reject_save BEFORE INSERT ON activities '
      "BEGIN SELECT RAISE(ABORT, 'test'); END;");
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    _focusWindow();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(controller.value, draft);
    expect(find.text('保存失败，请重试。输入的内容仍在。'), findsOneWidget);
    expect(other.notes.byId(note.id)!.rawContent, '他窗已保存数据');
    expect(local.db.raw.select('SELECT id FROM activities'), hasLength(activityCount));
    local.db.raw.execute('DROP TRIGGER reject_save');
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(find.text('他窗已保存数据'), findsOneWidget);
    expect(local.notes.active(), hasLength(1));
  });
}
