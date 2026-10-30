import 'package:flutter/material.dart';
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
  testWidgets('侧栏搜索可查询和清空，返回保留原页面并可再次打开', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    boot.noteService.capture('桌面搜索验收');
    await tester.pumpWidget(app(boot, const MainPanel()));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '搜索验收');
    await tester.pumpAndSettle();
    expect(find.text('桌面搜索验收'), findsOneWidget);
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('输入关键词搜索便签和事项'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('AI 整理'), findsOneWidget);
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('桌面设置可打开各分类，返回后仍在设置列表', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(app(boot, const MainPanel()));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    for (final title in ['AI 整理', '提醒', '快捷键', '同步', '备份与导出', '应用更新']) {
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      if (title == '快捷键') {
        expect(find.text('便签内'), findsOneWidget);
        expect(find.text('⌘/Ctrl + P'), findsOneWidget);
      }
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('AI 整理'), findsOneWidget);
    }
  });
}
