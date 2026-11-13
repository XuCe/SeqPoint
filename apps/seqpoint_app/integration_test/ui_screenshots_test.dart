import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/theme/seq_theme.dart';
import 'package:window_manager/window_manager.dart';

/// 界面截图：用演示数据渲染主要页面，写入 SEQ_SHOTS 指定的目录。
///
///   SEQ_SHOTS=/tmp/shots flutter test integration_test/ui_screenshots_test.dart -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['SEQ_SHOTS'];

  Future<Bootstrap> seeded() async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final now = DateTime.now();
    DateTime at(int dayOffset, int h, int m) =>
        DateTime(now.year, now.month, now.day + dayOffset, h, m);
    void due(String noteId, int line, DateTime when, {bool done = false}) {
      final item = boot.noteService.lineToItem(noteId, line);
      boot.items.update(item.copyWith(dueAt: when));
      if (done) boot.noteService.toggleItem(item.id);
    }

    final migrate = boot.noteService.capture(
        '确认迁移窗口\n通知业务方停机时间\n备份生产库\n切换 DNS', title: '服务器迁移', color: 'blue');
    due(migrate.id, 0, at(0, 9, 30), done: true);
    due(migrate.id, 1, at(0, now.hour + 1, 0));
    due(migrate.id, 2, at(0, now.hour + 3, 30));
    due(migrate.id, 3, at(1, 10, 0));
    final weekly = boot.noteService.capture('回复张三报价\n周五前发周报\n订下周会议室', title: '会后待办');
    due(weekly.id, 0, at(-1, 17, 0));
    due(weekly.id, 1, at(3, 18, 0));
    due(weekly.id, 2, at(0, now.hour + 5, 0));
    boot.noteService.capture('早上的语音速记：报销发票还没交，年会节目要报名，顺便问一下团建预算',
        color: 'pink');
    boot.noteService.capture('读书笔记\n《深度工作》第三章：拥抱无聊', color: 'green');
    final done = boot.noteService.capture('买牛奶\n取快递', title: '下班路上', color: 'yellow');
    due(done.id, 0, at(0, 8, 0), done: true);
    due(done.id, 1, at(0, 8, 30), done: true);
    return boot;
  }

  Future<void> shot(WidgetTester tester, GlobalKey key, String name) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    if (dir == null) return;
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$dir/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  Widget frame(Bootstrap boot, Size size, Widget child, GlobalKey key) => OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: size.width, maxWidth: size.width,
        minHeight: size.height, maxHeight: size.height,
        child: RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: seqLightTheme(),
            builder: (context, content) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: AppScope(
                noteService: boot.noteService, notes: boot.notes, items: boot.items,
                tags: boot.tags, search: boot.search, database: boot.db,
                child: content!,
              ),
            ),
            home: child,
          ),
        ),
      );

  setUpAll(() async {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1440, 900));
  });

  testWidgets('桌面主窗口截图', (tester) async {
    final boot = await seeded();
    addTearDown(boot.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(frame(boot, const Size(1440, 900), const MainPanel(), key));
    await shot(tester, key, 'desktop-today');
    await tester.enterText(find.byKey(const ValueKey('quick-composer')),
        '明天上午 10 点 和设计评审新首页 !P1\n记得带上次的反馈记录');
    await shot(tester, key, 'desktop-composer');
    await tester.enterText(find.byKey(const ValueKey('quick-composer')), '');
    await tester.tap(find.text('便签').first);
    await shot(tester, key, 'desktop-notes');
    await tester.tap(find.text('服务器迁移').first);
    await shot(tester, key, 'desktop-note-panel');
    await tester.tap(find.byTooltip('关闭'));
    await tester.tap(find.text('事项').first);
    await shot(tester, key, 'desktop-items');
    await tester.tap(find.text('已关闭').first);
    await shot(tester, key, 'desktop-closed');
    await tester.tap(find.text('设置').first);
    await shot(tester, key, 'desktop-settings');
    for (final (title, name) in const [('AI 整理', 'ai'), ('提醒', 'reminders'),
        ('备份与恢复', 'backup'), ('快捷键', 'hotkeys'), ('关于与更新', 'about')]) {
      await tester.tap(find.text(title).first);
      await shot(tester, key, 'settings-$name');
    }
    await tester.tap(find.text('AI 整理').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端模型'));
    await shot(tester, key, 'settings-ai-cloud');
    await tester.tap(find.text('今日').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '周报');
    await tester.pump(const Duration(milliseconds: 300));
    await shot(tester, key, 'desktop-palette');
  });

  testWidgets('手机截图', (tester) async {
    final boot = await seeded();
    addTearDown(boot.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(frame(boot, const Size(390, 844), const MobileShell(), key));
    await shot(tester, key, 'mobile-today');
    await tester.tap(find.text('便签').last);
    await shot(tester, key, 'mobile-notes');
    await tester.tap(find.text('我的').last);
    await shot(tester, key, 'mobile-me');
  });
}
