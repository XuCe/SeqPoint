import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';

Widget app(Bootstrap boot, Widget child) => MaterialApp(
  builder: (_, content) => AppScope(
    noteService: boot.noteService,
    notes: boot.notes,
    items: boot.items,
    tags: boot.tags,
    search: boot.search,
    child: content!,
  ),
  home: child,
);

void main() {
  testWidgets('⌘K 面板可搜索和清空，Esc 关闭后保留原页面并可再次打开', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    boot.noteService.capture('桌面搜索验收');
    await tester.pumpWidget(app(boot, const MainPanel()));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('palette-input'));
    await tester.enterText(input, '搜索验收');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    expect(find.text('桌面搜索验收'), findsOneWidget);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('桌面搜索验收'), findsNothing);
    expect(find.text('打开设置'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(input, findsNothing);
    expect(find.text('设备与同步'), findsWidgets);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(input, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('⌘K 面板选中命令可跳转页面', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(app(boot, const MainPanel()));
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('palette-input')), '已关闭');
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('已揭走'), findsOneWidget);
  });
  testWidgets('桌面设置左栏切换各分类，右侧直接显示内容', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app(boot, const MainPanel()));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    for (final title in ['AI 整理', '提醒', '快捷键', '设备与同步', '备份与恢复', '关于与更新']) {
      await tester.tap(find.text(title).first);
      await tester.pumpAndSettle();
      expect(find.text(title), findsNWidgets(2), reason: '左栏与右侧标题');
      expect(find.byType(BackButton), findsNothing);
      if (title == '快捷键') {
        expect(find.text('便签内'), findsOneWidget);
        expect(find.text('⌘/Ctrl + P'), findsOneWidget);
      }
    }
    expect(tester.takeException(), isNull);
  });
}
