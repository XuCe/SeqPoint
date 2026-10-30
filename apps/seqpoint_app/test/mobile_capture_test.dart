import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/mobile/note_wall_page.dart';
import 'package:seqpoint_app/mobile/quick_capture_page.dart';
import 'package:seqpoint_app/shared/note_card.dart';

Widget _app(Bootstrap b) => MaterialApp(
  builder: (_, child) => AppScope(noteService: b.noteService, notes: b.notes,
    items: b.items, tags: b.tags, search: b.search, child: child!),
  home: const MobileShell());

void main() {
  for (final modifier in [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.metaLeft]) {
    testWidgets('${modifier.keyLabel}+Enter保存快速记录，普通回车不保存', (t) async {
      final b = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(b.dispose);
      await t.pumpWidget(_app(b));
      await t.tap(find.byTooltip('记一笔'));
      await t.pumpAndSettle();
      await t.tap(find.text('快速记录'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '键盘快速记录');
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(b.notes.active(), isEmpty);
      expect(find.byType(QuickCapturePage), findsOneWidget);
      await t.sendKeyDownEvent(modifier);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(modifier);
      await t.pumpAndSettle();
      expect(b.notes.active(), hasLength(1));
      expect(b.notes.active().single.rawContent, '键盘快速记录');
      expect(find.byType(NoteWallPage), findsOneWidget);
    });
  }
  testWidgets('确认语音草稿进入记录页，数据库失败仍保留全文并可重试', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    b.db.raw.execute("CREATE TRIGGER voice_save BEFORE INSERT ON notes BEGIN SELECT RAISE(ABORT, 'test'); END;");
    await t.pumpWidget(_app(b));
    t.state<NavigatorState>(find.byType(Navigator)).push<bool>(MaterialPageRoute(
        builder: (_) => const QuickCapturePage(initialText: '明天下午开会，带上报告')));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '明天下午开会，带上报告');
    await t.tap(find.text('保存'));
    await t.pump();
    expect(find.text('保存失败，请重试。输入的内容仍在。'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '明天下午开会，带上报告');
    expect(b.notes.active(), isEmpty);
    b.db.raw.execute('DROP TRIGGER voice_save');
    await t.tap(find.text('保存'));
    await t.pumpAndSettle();
    expect(b.notes.active().single.rawContent, '明天下午开会，带上报告');
  });
  for (final tab in ['今日', '便签', '全部事项']) {
    testWidgets('从$tab新建后立即显示便签列表，无需切换页面', (t) async {
      final b = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(b.dispose);
      final old = b.noteService.capture('已有便签');
      await t.pumpWidget(_app(b));
      await t.tap(find.text(tab == '全部事项' ? '便签' : tab));
      await t.pumpAndSettle();
      if (tab == '全部事项') {
        await t.tap(find.text(tab));
        await t.pumpAndSettle();
      }
      await t.tap(find.byTooltip('记一笔'));
      await t.pumpAndSettle();
      await t.tap(find.text('快速记录'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '移动新便签');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      final created = b.notes.active().singleWhere((n) => n.id != old.id);
      expect(find.byType(NoteWallPage), findsOneWidget);
      expect(find.byType(NoteCard), findsNWidgets(2));
      expect(t.widgetList<NoteCard>(find.byType(NoteCard)).map((c) => c.note.id),
        unorderedEquals([old.id, created.id]));
      expect(find.text('移动新便签'), findsWidgets);
      expect(created.rawContent, '移动新便签');
      expect(b.notes.active(), hasLength(2));
    });
  }

  for (final action in ['关闭面板', '放弃', '空白保存', '系统返回']) {
    testWidgets('$action不创建便签并保留原列表', (t) async {
      final b = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(b.dispose);
      final old = b.noteService.capture('取消前的便签');
      await t.pumpWidget(_app(b));
      await t.tap(find.text('便签'));
      await t.pumpAndSettle();
      await t.tap(find.byTooltip('记一笔'));
      await t.pumpAndSettle();
      if (action == '关闭面板') {
        await t.binding.handlePopRoute();
      } else {
        await t.tap(find.text('快速记录'));
        await t.pumpAndSettle();
        await t.enterText(find.byType(TextField),
          action == '空白保存' ? ' \n ' : '取消不应保存');
        if (action == '系统返回') {
          await t.binding.handlePopRoute();
        } else {
          await t.tap(action == '放弃' ? find.byTooltip('放弃') : find.text('保存'));
        }
      }
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(t.widget<NoteCard>(find.byType(NoteCard)).note.id, old.id);
      expect(b.notes.active().single.id, old.id);
      expect(b.db.raw.select('SELECT id FROM activities'), hasLength(1));
    });
  }

  for (final table in ['notes', 'activities']) {
    testWidgets('$table保存失败保留输入，重试后只显示一份新便签', (t) async {
      final b = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(b.dispose);
      b.db.raw.execute('CREATE TRIGGER reject_save BEFORE INSERT ON $table '
        "BEGIN SELECT RAISE(ABORT, 'test'); END;");
      await t.pumpWidget(_app(b));
      await t.tap(find.byTooltip('记一笔'));
      await t.pumpAndSettle();
      await t.tap(find.text('快速记录'));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), '失败后重试便签');
      await t.tap(find.text('保存'));
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text('保存失败，请重试。输入的内容仍在。'), findsOneWidget);
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text,
        '失败后重试便签');
      expect(b.notes.active(), isEmpty);
      expect(b.db.raw.select('SELECT id FROM activities'), isEmpty);
      b.db.raw.execute('DROP TRIGGER reject_save');
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      final note = b.notes.active().single;
      expect(find.byType(NoteWallPage), findsOneWidget);
      expect(t.widget<NoteCard>(find.byType(NoteCard)).note.id, note.id);
      expect(note.rawContent, '失败后重试便签');
      expect(b.db.raw.select('SELECT id FROM activities'), hasLength(1));
    });
  }
}
