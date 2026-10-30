import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/desktop/panel/side_nav.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:window_manager/window_manager.dart';

Widget _app(Bootstrap b) => AppScope(
  noteService: b.noteService, notes: b.notes, items: b.items,
  tags: b.tags, search: b.search, child: const MaterialApp(home: MainPanel()));

void main() {
  testWidgets('回收站恢复便签后立即更新今日角标', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('待恢复的今日事项');
    final item = b.noteService.lineToItem(note.id, 0);
    b.items.update(item.copyWith(dueAt: DateTime.now()));
    b.noteService.trash(note.id);
    await t.pumpWidget(_app(b));
    await t.tap(find.text('回收站'));
    await t.pumpAndSettle();
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 0);
    await t.tap(find.text('恢复'));
    await t.pumpAndSettle();
    expect(find.text('回收站是空的。'), findsOneWidget);
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 1);
    expect(t.takeException(), isNull);
  });
  for (final section in ['今日', '全部事项']) {
    for (final action in ['完成', '修改期限']) {
      testWidgets('$section中$action后角标立即刷新', (t) async {
        final b = await Bootstrap.run(dbPath: ':memory:');
        addTearDown(b.dispose);
        final note = b.noteService.capture('角标交互事项');
        final item = b.noteService.lineToItem(note.id, 0);
        b.items.update(item.copyWith(dueAt: DateTime.now()));
        await t.pumpWidget(_app(b));
        await t.tap(find.text(section));
        await t.pumpAndSettle();
        expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 1);
        if (action == '完成') {
          await t.tap(find.descendant(of: find.byType(ItemTile),
            matching: find.byType(GestureDetector)).last);
        } else {
          await t.tap(find.text('角标交互事项'));
          await t.pumpAndSettle();
          await t.ensureVisible(find.text('清除截止时间'));
          await t.tap(find.text('清除截止时间'));
          await t.tap(find.text('保存'));
        }
        await t.pumpAndSettle();
        expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 0);
        expect(t.takeException(), isNull);
        if (section == '今日' && action == '完成') {
          await t.tap(find.descendant(of: find.byType(ItemTile),
            matching: find.byType(GestureDetector)).last);
          await t.pumpAndSettle();
          expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 1);
        }
      });
    }
  }
  testWidgets('今天已到期的事项在今日角标只统计一次', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('今天已到期事项');
    final item = b.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    b.items.update(item.copyWith(dueAt: DateTime(now.year, now.month, now.day)));
    await t.pumpWidget(_app(b));
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 1);
    expect(find.descendant(of: find.byType(SideNav), matching: find.text('1')),
      findsOneWidget);
    expect(t.widget<ItemTile>(find.byType(ItemTile)).item.id, item.id);
    expect(find.text('早上好，今天还有 1 件事'), findsOneWidget);
  });

  testWidgets('同名不同事项各计一次，跨日逾期计入，明日无期限和已完成不计入', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('同名事项\n同名事项\n昨日逾期\n明日事项\n无期限\n已完成');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final laterToday = DateTime(now.year, now.month, now.day + 1)
      .subtract(const Duration(microseconds: 1));
    final dates = [today, laterToday, DateTime(now.year, now.month, now.day - 1),
      DateTime(now.year, now.month, now.day + 1), null, today];
    final items = [for (var i = 0; i < dates.length; i++)
      b.noteService.lineToItem(note.id, i)];
    for (var i = 0; i < items.length; i++) {
      b.items.update(items[i].copyWith(dueAt: dates[i]));
    }
    b.noteService.toggleItem(items.last.id);
    await t.pumpWidget(_app(b));
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 3);
    expect(find.descendant(of: find.byType(SideNav), matching: find.text('3')),
      findsOneWidget);
    expect(t.widgetList<ItemTile>(find.byType(ItemTile))
      .where((tile) => tile.item.isOpen).map((tile) => tile.item.id),
      unorderedEquals(items.take(3).map((item) => item.id)));
    expect(find.text('同名事项'), findsNWidgets(2));
    expect(find.text('早上好，今天还有 3 件事'), findsOneWidget);
  });

  testWidgets('修改截止时间、完成或重新打开后刷新角标，事项始终只计一次', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('角标修改事项');
    final item = b.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    b.items.update(item.copyWith(dueAt: tomorrow));
    await t.pumpWidget(_app(b));
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 0);
    for (final (due, count) in [(today, 1), (tomorrow, 0),
      (yesterday, 1), (null, 0), (today, 1)]) {
      b.items.update(b.items.byId(item.id)!.copyWith(dueAt: due, clearDueAt: due == null));
      (t.state(find.byType(MainPanel)) as WindowListener).onWindowFocus();
      await t.pumpAndSettle();
      expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, count,
        reason: '修改截止时间为 $due');
    }
    for (final count in [0, 1]) {
      b.noteService.toggleItem(item.id);
      (t.state(find.byType(MainPanel)) as WindowListener).onWindowFocus();
      await t.pumpAndSettle();
      expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, count);
      expect(find.descendant(of: find.byType(SideNav), matching: find.text('$count')),
        count == 0 ? findsNothing : findsOneWidget);
    }
  });

  testWidgets('删除和恢复便签后角标按可见事项重新计算，零值不显示角标', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final first = b.noteService.capture('第一张便签事项');
    final second = b.noteService.capture('第二张便签事项');
    final now = DateTime.now();
    for (final note in [first, second]) {
      final item = b.noteService.lineToItem(note.id, 0);
      b.items.update(item.copyWith(dueAt: DateTime(now.year, now.month, now.day)));
    }
    await t.pumpWidget(_app(b));
    expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, 2);
    for (final (id, restore, count) in [(first.id, false, 1),
      (second.id, false, 0), (first.id, true, 1), (second.id, true, 2)]) {
      if (restore) {
        b.noteService.restore(id);
      } else {
        b.noteService.trash(id);
      }
      (t.state(find.byType(MainPanel)) as WindowListener).onWindowFocus();
      await t.pumpAndSettle();
      expect(t.widget<SideNav>(find.byType(SideNav)).todayCount, count);
      expect(find.descendant(of: find.byType(SideNav), matching: find.text('$count')),
        count == 0 ? findsNothing : findsOneWidget);
    }
  });
}
