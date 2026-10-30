import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:seqpoint_app/theme/seq_theme.dart';

/// 装配真实核心层后挂载界面。等价于"把应用跑起来看一眼"。
Future<Widget> _mount(Widget child) async {
  final boot = await Bootstrap.run();
  return MaterialApp(
    theme: seqLightTheme(),
    home: AppScope(
      noteService: boot.noteService,
      notes: boot.notes,
      items: boot.items,
      tags: boot.tags,
      search: boot.search,
      child: child,
    ),
  );
}

void main() {
  testWidgets('主面板渲染今日视图与演示数据', (tester) async {
    await tester.pumpWidget(await _mount(const MainPanel()));
    await tester.pumpAndSettle();

    // 左导航
    expect(find.text('序点'), findsOneWidget);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('便签墙'), findsOneWidget);

    // 同步状态诚实展示
    expect(find.text('仅本机'), findsOneWidget);

    // 今日视图：演示数据里两件未完成（一件今天 18:00 到期）、一件已完成
    expect(find.textContaining('今天还有'), findsOneWidget);
    expect(find.text('回复张三报价'), findsOneWidget);
    expect(find.text('周五前发周报'), findsOneWidget);
    expect(find.textContaining('晚间汇总'), findsOneWidget);
  });

  testWidgets('今天到期但时刻已过的事项只出现一次，不在两个区重复', (tester) async {
    final boot = await Bootstrap.run();
    // 造一条"今天 00:05 到期"的事项——现在一定已经过了这个时刻，
    // 它既满足"今天到期"也满足"已逾期"，是重复渲染的触发条件。
    final note = boot.noteService.capture('早上就该做的事');
    final item = boot.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    boot.items.update(item.copyWith(
      dueAt: DateTime(now.year, now.month, now.day, 0, 5),
    ));

    await tester.pumpWidget(MaterialApp(
      theme: seqLightTheme(),
      home: AppScope(
        noteService: boot.noteService,
        notes: boot.notes,
        items: boot.items,
        tags: boot.tags,
        search: boot.search,
        child: const MainPanel(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('早上就该做的事'), findsOneWidget);
  });

  testWidgets('切换到便签墙不报错', (tester) async {
    await tester.pumpWidget(await _mount(const MainPanel()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('便签墙'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('便签窗渲染三行，其中一行已勾选划线', (tester) async {
    final boot = await Bootstrap.run();
    final note = boot.notes.active().first;

    await tester.pumpWidget(MaterialApp(
      theme: seqLightTheme(),
      home: AppScope(
        noteService: boot.noteService,
        notes: boot.notes,
        items: boot.items,
        tags: boot.tags,
        search: boot.search,
        child: StickyWindow(noteId: note.id),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('会后待办'), findsOneWidget);
    expect(find.text('回复张三报价'), findsOneWidget);
    expect(find.text('检查生产 nginx 证书'), findsOneWidget);
    expect(find.text('1 / 3 完成'), findsOneWidget);

    // 已完成的那行带删除线
    final doneText = tester.widget<Text>(find.text('周五前发周报'));
    expect(doneText.style?.decoration, TextDecoration.lineThrough);
  });

  testWidgets('点击圈可勾选事项，进度随之变化', (tester) async {
    final boot = await Bootstrap.run();
    final note = boot.notes.active().first;

    await tester.pumpWidget(MaterialApp(
      theme: seqLightTheme(),
      home: AppScope(
        noteService: boot.noteService,
        notes: boot.notes,
        items: boot.items,
        tags: boot.tags,
        search: boot.search,
        child: StickyWindow(noteId: note.id),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('1 / 3 完成'), findsOneWidget);
    await tester.tap(find.text('回复张三报价'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3 完成'), findsOneWidget);
  });
}
