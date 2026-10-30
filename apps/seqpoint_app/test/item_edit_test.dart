import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/desktop/panel/today_view.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:seqpoint_app/mobile/today_page.dart';
import 'package:seqpoint_app/mobile/note_wall_page.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_app/shared/item_editor_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:window_manager/window_manager.dart';

Widget _app(Bootstrap boot, Widget home) => MaterialApp(
  builder: (context, child) => AppScope(
    noteService: boot.noteService,
    notes: boot.notes,
    items: boot.items,
    tags: boot.tags,
    search: boot.search,
    child: child!,
  ),
  home: home,
);

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('未确认候选直接保存不落库且确认后可重试：$platform', (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = previous);
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('未提交输入法测试');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextFormField));
      const composing = TextEditingValue(text: '下周一',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3));
      tester.testTextInput.updateEditingValue(composing);
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemEditorPage), findsOneWidget);
      expect(boot.items.byId(item.id)!.title, item.title);
      expect(boot.items.byId(item.id)!.dueAt, isNull);
      expect(find.text('请先确认输入法候选词后再保存'), findsOneWidget);
      tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, '下周一');
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(),
          const TimeParser().parse('下周一', DateTime.now())!.dateTime);
      debugDefaultTargetPlatformOverride = previous;
    });
  }

  for (final title in ['下周一', '今晚八点']) {
    testWidgets('候选词$title上屏保存后重开数据库保留完整期限', (tester) async {
      final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('seqpoint-ime-')))!;
      final path = '${root.path}/notes.db';
      var boot = await Bootstrap.run(dbPath: path);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        boot.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      final note = boot.noteService.capture('输入法持久化测试');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextFormField));
      final composing = TextEditingValue(text: title,
          selection: TextSelection.collapsed(offset: title.length),
          composing: TextRange(start: 0, end: title.length));
      tester.testTextInput.updateEditingValue(composing);
      await tester.pumpAndSettle();
      expect(find.text('未设置'), findsOneWidget);
      tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final due = const TimeParser().parse(title, DateTime.now())!.dateTime;
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
      final before = Map<String, Object?>.from(boot.db.raw.select(
          'SELECT * FROM items WHERE id = ?', [item.id]).single);
      await tester.pumpWidget(const SizedBox.shrink());
      boot.dispose();
      boot = await Bootstrap.run(dbPath: path);
      expect(boot.items.byId(item.id)!.title, title);
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
      expect(boot.db.raw.select('SELECT * FROM items WHERE id = ?', [item.id]).single, before);
    });
  }

  for (final cancel in [true, false]) {
    testWidgets(cancel ? '取消候选保留已保存期限' : '仅移动光标不恢复已清除的期限', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture(cancel ? '取消候选测试' : '今晚八点');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      final due = cancel ? DateTime(now.year, now.month, now.day + 3, 21, 15) : null;
      expect(boot.items.saveEdits(item, title: item.title,
          priority: item.priority, dueAt: due), isTrue);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextFormField));
      if (cancel) {
        tester.testTextInput.updateEditingValue(const TextEditingValue(
            text: '下周一', selection: TextSelection.collapsed(offset: 3),
            composing: TextRange(start: 0, end: 3)));
        await tester.pumpAndSettle();
        expect(find.text('${due!.year}/${due.month}/${due.day}'), findsOneWidget);
      }
      tester.testTextInput.updateEditingValue(TextEditingValue(
          text: item.title, selection: const TextSelection.collapsed(offset: 1)));
      await tester.pumpAndSettle();
      expect(find.text(due == null ? '未设置'
          : '${due.year}/${due.month}/${due.day}'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, item.title);
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
    });
  }

  for (final action in ['今天到期', '清除截止时间']) {
    testWidgets('组合输入上屏不会覆盖手动$action', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('输入法手动测试');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '今晚八点');
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.showKeyboard(find.byType(TextFormField));
      const composing = TextEditingValue(text: '下周一',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3));
      tester.testTextInput.updateEditingValue(composing);
      await tester.pumpAndSettle();
      final now = DateTime.now();
      expect(find.text(action == '今天到期'
          ? '${now.year}/${now.month}/${now.day}' : '未设置'), findsOneWidget);
      tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, '下周一');
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), action == '今天到期'
          ? DateTime(now.year, now.month, now.day, 23, 59) : isNull);
    });
  }

  for (final title in ['下周一', '今晚八点']) {
    testWidgets('候选词$title提交前不填期限，组合状态提交后立即识别', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('输入法测试');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextFormField));
      final composing = TextEditingValue(text: title,
          selection: TextSelection.collapsed(offset: title.length),
          composing: TextRange(start: 0, end: title.length));
      tester.testTextInput.updateEditingValue(composing);
      await tester.pumpAndSettle();
      expect(find.text('未设置'), findsOneWidget);
      expect(find.text('截止时间'), findsNothing);
      expect(boot.items.byId(item.id)!.dueAt, isNull);
      tester.testTextInput.updateEditingValue(
          composing.copyWith(composing: TextRange.empty));
      await tester.pumpAndSettle();
      final due = const TimeParser().parse(title, DateTime.now())!.dateTime;
      expect(find.text('${due.year}/${due.month}/${due.day}'), findsOneWidget);
      expect(find.text('截止时间'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, title);
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
    });
  }

  for (final changeTime in [false, true]) {
    testWidgets('已有期限${changeTime ? '随明确的新表达更新' : '不因普通改名重新计算'}', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('今晚八点开会');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      final savedDue = DateTime(now.year, now.month, now.day, 23, 15);
      boot.items.update(item.copyWith(dueAt: savedDue));
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      final title = changeTime ? '下周一开会' : '今晚八点开会并记录';
      await tester.enterText(find.byType(TextFormField), title);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), changeTime
          ? const TimeParser().parse(title, now)!.dateTime : savedDue);
    });
  }

  for (final viaLine in [true, false]) {
    testWidgets('${viaLine ? '便签行创建' : '标题输入'}的中文期限重启后完整保留', (tester) async {
      final root = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('seqpoint-auto-deadline-')))!;
      final path = '${root.path}/notes.db';
      var boot = await Bootstrap.run(dbPath: path);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        boot.dispose();
        await tester.runAsync(() => root.delete(recursive: true));
      });
      final title = viaLine ? '下周一提交报告' : '今晚八点开会';
      final due = const TimeParser().parse(title, DateTime.now())!.dateTime;
      final note = boot.noteService.capture(viaLine ? title : '普通事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      if (!viaLine) {
        await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
        await tester.tap(find.byTooltip('编辑事项'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), title);
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
      }
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
      final before = Map<String, Object?>.from(boot.db.raw.select(
          'SELECT * FROM items WHERE id = ?', [item.id]).single);
      await tester.pumpWidget(const SizedBox.shrink());
      boot.dispose();
      boot = await Bootstrap.run(dbPath: path);
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), due);
      expect(boot.items.byId(item.id)!.title, title);
      expect(boot.notes.byId(note.id)!.rawContent, note.rawContent);
      expect(boot.db.raw.select('SELECT * FROM items WHERE id = ?', [item.id]).single, before);
      if (!viaLine) {
        await tester.pumpWidget(_app(boot, const Scaffold(body: TodayView())));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
      }
    });
  }

  for (final pickDate in [true, false]) {
    testWidgets('手动${pickDate ? '日期' : '时刻'}优先于标题识别', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('普通事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '今晚八点开会');
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final picked = DateTime(now.year, now.month, now.day + 3, 20);
      await tester.tap(find.text(pickDate ? '截止日期' : '截止时间'));
      await tester.pumpAndSettle();
      if (pickDate) {
        tester.widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .onDateChanged(picked);
      } else {
        await tester.tap(find.byIcon(Icons.keyboard_outlined));
        await tester.pumpAndSettle();
        final fields = find.descendant(of: find.byType(TimePickerDialog),
            matching: find.byType(TextFormField));
        await tester.enterText(fields.at(0), '10');
        await tester.enterText(fields.at(1), '15');
      }
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '下周一提交报告');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), pickDate
          ? picked : DateTime(now.year, now.month, now.day, 22, 15));
    });
  }

  for (final action in ['今天到期', '清除截止时间', '取消']) {
    testWidgets('自动识别期限后$action不被后续标题输入覆盖', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('普通事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '今晚八点开会');
      await tester.pumpAndSettle();
      if (action == '取消') {
        await tester.pageBack();
      } else {
        await tester.tap(find.text(action));
        await tester.enterText(find.byType(TextFormField), '下周一提交报告');
        await tester.tap(find.text('保存'));
      }
      await tester.pumpAndSettle();
      final now = DateTime.now();
      final saved = boot.items.byId(item.id)!;
      expect(saved.dueAt?.toLocal(), action == '今天到期'
          ? DateTime(now.year, now.month, now.day, 23, 59) : isNull);
      expect(saved.title, action == '取消' ? '普通事项' : '下周一提交报告');
    });
  }

  for (final mobile in [false, true]) {
    for (final title in ['下周一提交报告', '今晚八点开会']) {
      testWidgets('${mobile ? '移动' : '桌面便签'}标题自动填写并保存期限：$title', (tester) async {
        final boot = await Bootstrap.run(dbPath: ':memory:');
        addTearDown(boot.dispose);
        final note = boot.noteService.capture('普通事项');
        final item = boot.noteService.lineToItem(note.id, 0);
        final home = mobile
            ? NoteDetailPage(noteId: note.id)
            : StickyWindow(noteId: note.id);
        await tester.pumpWidget(_app(boot, home));
        await tester.tap(find.byTooltip('编辑事项'));
        await tester.pumpAndSettle();
        final expected = const TimeParser().parse(title, DateTime.now())!.dateTime;
        await tester.enterText(find.byType(TextFormField), title);
        await tester.pumpAndSettle();
        expect(find.text('${expected.year}/${expected.month}/${expected.day}'), findsOneWidget);
        expect(find.text('截止时间'), findsOneWidget);
        expect(boot.items.byId(item.id)!.dueAt, isNull);
        await tester.enterText(find.byType(TextFormField), '普通事项');
        await tester.pumpAndSettle();
        expect(find.text('未设置'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), title);
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(boot.items.byId(item.id)!.dueAt?.toLocal(), expected);
        expect(boot.items.byId(item.id)!.title, title);
        expect(boot.notes.byId(note.id)!.rawContent, '普通事项');
        if (title.startsWith('今晚')) {
          expect(boot.items.dueOn(DateTime.now()).map((i) => i.id), [item.id]);
          await tester.pumpWidget(_app(boot,
              Scaffold(body: mobile ? const TodayPage() : const TodayView())));
          await tester.pumpAndSettle();
          expect(tester.widget<ItemTile>(find.byType(ItemTile)).item.dueAt?.toLocal(), expected);
        }
      });
    }
  }

  for (final conflict in [false, true]) {
    testWidgets('跨窗口保存${conflict ? '拒绝同字段冲突并保留输入' : '合并各自修改的字段'}', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('原始标题');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, Builder(builder: (context) =>
        TextButton(onPressed: () => ItemEditorPage.open(context, item.id),
          child: const Text('打开编辑')))));
      await tester.tap(find.text('打开编辑'));
      await tester.pumpAndSettle();
      final due = DateTime(2026, 10, 25, 12);
      boot.items.update(item.copyWith(title: conflict ? '其他窗口标题' : item.title,
        dueAt: due, priority: Priority.p1));
      await tester.enterText(find.byType(TextFormField), '本窗口标题');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = boot.items.byId(item.id)!;
      expect(saved.title, conflict ? '其他窗口标题' : '本窗口标题');
      expect(saved.dueAt?.toLocal(), due);
      expect(saved.priority, Priority.p1);
      if (conflict) {
        expect(find.text('事项已在其他窗口修改，请重新打开后核对'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, '本窗口标题'), findsOneWidget);
        await tester.tap(find.text('保存'));
        await tester.pump();
        expect(boot.items.byId(item.id)!.title, '其他窗口标题');
      } else {
        expect(find.byType(ItemEditorPage), findsNothing);
      }
    });
  }

  for (final mobile in [false, true]) {
    testWidgets('${mobile ? '移动' : '桌面'}今日不显示软删除的已完成事项', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('保留的完成事项\n已删除的完成事项');
      final kept = boot.noteService.lineToItem(note.id, 0);
      final removed = boot.noteService.lineToItem(note.id, 1);
      boot.noteService.toggleItem(kept.id);
      final done = boot.noteService.toggleItem(removed.id);
      boot.items.update(done.copyWith(deletedAt: DateTime.now()));
      await tester.pumpWidget(
        _app(
          boot,
          Scaffold(body: mobile ? const TodayPage() : const TodayView()),
        ),
      );
      expect(find.text('今日已完成'), findsOneWidget);
      expect(find.byType(ItemTile), findsOneWidget);
      expect(tester.widget<ItemTile>(find.byType(ItemTile)).item.id, kept.id);
      expect(find.text('已删除的完成事项'), findsNothing);
      expect(boot.items.byId(removed.id)!.isDone, isTrue);
    });
  }

  for (final section in ['今日', '全部事项']) {
    testWidgets('编辑$section事项时窗口重新聚焦，保存后列表显示最新内容', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('焦点刷新事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      boot.items.update(
        item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
      );
      await tester.pumpWidget(_app(boot, const MainPanel()));
      await tester.tap(find.text(section));
      await tester.pumpAndSettle();
      await tester.tap(find.text('焦点刷新事项'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '焦点切换后保存');
      (tester.state(
        find.byType(MainPanel, skipOffstage: false),
      ) as WindowListener).onWindowFocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, '焦点切换后保存');
      final shown = tester.widget<ItemTile>(find.byType(ItemTile)).item;
      expect(shown.title, '焦点切换后保存');
      expect(shown.isImportant, isTrue);
      expect(find.text('焦点刷新事项'), findsNothing);
    });
  }

  for (final mobile in [false, true]) {
    testWidgets('${mobile ? '移动' : '桌面'}今日事项改为今天已过时刻后只在逾期显示一次', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('今天逾期事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      boot.items.update(
        item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
      );
      await tester.pumpWidget(
        _app(
          boot,
          Scaffold(body: mobile ? const TodayPage() : const TodayView()),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ItemTile),
          matching: find.text('今天逾期事项'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('截止时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), '12');
      await tester.enterText(fields.at(1), '00');
      await tester.tap(find.text('AM'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemTile), findsOneWidget);
      expect(find.text('逾期'), findsOneWidget);
      expect(tester.widget<ItemTile>(find.byType(ItemTile)).item.id, item.id);
      expect(
        boot.items.byId(item.id)!.dueAt?.toLocal(),
        DateTime(now.year, now.month, now.day),
      );
      expect(boot.items.dueOn(now).where((i) => i.id == item.id), hasLength(1));
    });
  }

  testWidgets('清除截止时间后仍在全部事项，重新设为今天后回到今日', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('今日往返事项');
    final item = boot.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    boot.items.update(
      item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
    );
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('今日往返事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除截止时间'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemTile), findsNothing);
    await tester.tap(find.text('全部事项'));
    await tester.pumpAndSettle();
    expect(find.byType(ItemTile), findsOneWidget);
    await tester.tap(find.text('今日往返事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();
    expect(tester.widget<ItemTile>(find.byType(ItemTile)).item.id, item.id);
    expect(boot.items.byNote(note.id), hasLength(1));
  });

  for (final mobile in [false, true]) {
    for (final clear in [false, true]) {
      testWidgets(
        '${mobile ? '移动' : '桌面'}今日事项${clear ? '清除期限' : '改到明天'}后立即移出',
        (tester) async {
          final boot = await Bootstrap.run(dbPath: ':memory:');
          addTearDown(boot.dispose);
          final note = boot.noteService.capture('待移出今日');
          final item = boot.noteService.lineToItem(note.id, 0);
          final now = DateTime.now();
          final tomorrow = DateTime(now.year, now.month, now.day + 1, 23, 59);
          boot.items.update(
            item.copyWith(
              dueAt: DateTime(now.year, now.month, now.day, 23, 59),
            ),
          );
          await tester.pumpWidget(
            _app(
              boot,
              Scaffold(body: mobile ? const TodayPage() : const TodayView()),
            ),
          );
          await tester.tap(
            find.descendant(
              of: find.byType(ItemTile),
              matching: find.text('待移出今日'),
            ),
          );
          await tester.pumpAndSettle();
          if (clear) {
            await tester.tap(find.text('清除截止时间'));
          } else {
            await tester.tap(find.text('截止日期'));
            await tester.pumpAndSettle();
            tester
                .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
                .onDateChanged(tomorrow);
            await tester.tap(find.text('OK'));
            await tester.pumpAndSettle();
          }
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(find.byType(ItemTile), findsNothing);
          expect(boot.items.dueOn(now), isEmpty);
          final saved = boot.items.byId(item.id)!;
          expect(saved.dueAt?.toLocal(), clear ? isNull : tomorrow);
          expect(saved.status, ItemStatus.todo);
          expect(boot.items.byNote(note.id), hasLength(1));
        },
      );
    }
  }

  for (final mobile in [false, true]) {
    testWidgets('${mobile ? '移动' : '桌面'}今日中修改标题和重要程度立即刷新且无重复', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('今日原事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      boot.items.update(
        item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
      );
      await tester.pumpWidget(
        _app(
          boot,
          Scaffold(body: mobile ? const TodayPage() : const TodayView()),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byType(ItemTile),
          matching: find.text('今日原事项'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '今日已修改');
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.byType(ItemTile), findsOneWidget);
      final shown = tester.widget<ItemTile>(find.byType(ItemTile)).item;
      expect(shown.id, item.id);
      expect(shown.title, '今日已修改');
      expect(shown.priority, Priority.p1);
      expect(shown.status, ItemStatus.todo);
      expect(shown.dueAt?.toLocal(), DateTime(now.year, now.month, now.day, 23, 59));
      expect(find.text('今日原事项'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(ItemTile),
          matching: find.text('今日已修改'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ItemTile>(find.byType(ItemTile)).item.isImportant,
        isFalse,
      );
      expect(find.byType(ItemTile), findsOneWidget);
    });
  }

  testWidgets('移动便签正文缩短后旧事项仍可编辑与勾选', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('保留的原文\n末行事项');
    final item = boot.noteService.lineToItem(note.id, 1);
    boot.noteService.editContent(note.id, '保留的原文');
    await tester.pumpWidget(_app(boot, NoteDetailPage(noteId: note.id)));
    expect(find.text('末行事项'), findsOneWidget);
    await tester.tap(find.byTooltip('编辑事项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '保留下来的事项');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保留的原文'), findsOneWidget);
    await tester.tap(find.text('保留下来的事项'));
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.isDone, isTrue);
  });

  testWidgets('事项写入失败保留输入并可重试', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('写入失败测试');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.db.raw.execute(
      'CREATE TRIGGER reject_items BEFORE UPDATE ON items '
      "BEGIN SELECT RAISE(ABORT, 'test'); END;",
    );
    await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
    await tester.tap(find.byTooltip('编辑事项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '失败后仍保留');
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      '失败后仍保留',
    );
    expect(boot.items.byId(item.id)!.title, item.title);
    boot.db.raw.execute('DROP TRIGGER reject_items');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.title, '失败后仍保留');
    expect(boot.items.byId(item.id)!.dueAt, isNotNull);
    expect(boot.items.byNote(note.id), hasLength(1));
  });

  for (final entry in ['移动今日', '移动全部事项', '移动便签详情']) {
    testWidgets('$entry可以打开事项编辑并刷新', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('移动编辑事项');
      final item = boot.noteService.lineToItem(note.id, 0);
      final now = DateTime.now();
      boot.items.update(
        item.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)),
      );
      final home = switch (entry) {
        '移动今日' => const TodayPage(),
        '移动全部事项' => const NoteWallPage(),
        _ => NoteDetailPage(noteId: note.id),
      };
      await tester.pumpWidget(_app(boot, Scaffold(body: home)));
      if (entry == '移动全部事项') await tester.tap(find.text('全部事项'));
      await tester.pumpAndSettle();
      if (entry == '移动便签详情') {
        await tester.tap(find.byTooltip('编辑事项'));
      } else {
        await tester.tap(
          find.descendant(
            of: find.byType(ItemTile),
            matching: find.text('移动编辑事项'),
          ),
        );
      }
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '移动修改后的标题');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.title, '移动修改后的标题');
      expect(find.text('移动修改后的标题'), findsWidgets);
      if (entry == '移动便签详情') {
        expect(find.text('移动编辑事项'), findsOneWidget);
      }
    });
  }

  for (final compact in [true, false]) {
    testWidgets('${compact ? '小便签窗' : '主窗口'}日期和时间选择器可保存具体的本地截止时刻', (
      tester,
    ) async {
      tester.view.physicalSize = compact
          ? const Size(360, 300)
          : const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('具体截止时间');
      final item = boot.noteService.lineToItem(note.id, 0);
      await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
      await tester.tap(find.byTooltip('编辑事项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('截止日期'));
      await tester.pumpAndSettle();
      if (compact) {
        await tester.enterText(
          find.descendant(
            of: find.byType(DatePickerDialog),
            matching: find.byType(TextFormField),
          ),
          '03/15/2027',
        );
      } else {
        tester
            .widget<CalendarDatePicker>(find.byType(CalendarDatePicker))
            .onDateChanged(DateTime(2027, 3, 15));
      }
      expect(find.text('OK').hitTestable(), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('截止时间'));
      await tester.pumpAndSettle();
      if (!compact) {
        await tester.tap(find.byIcon(Icons.keyboard_outlined));
        await tester.pumpAndSettle();
      }
      final timeFields = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(timeFields.at(0), '10');
      await tester.enterText(timeFields.at(1), '30');
      expect(find.text('OK').hitTestable(), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(boot.items.byId(item.id)!.dueAt?.toLocal(), DateTime(2027, 3, 15, 22, 30));
    });
  }

  testWidgets('空标题显示校验，取消不会提交已修改的事项', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('取消编辑');
    final item = boot.noteService.lineToItem(note.id, 0);
    await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
    await tester.tap(find.byTooltip('编辑事项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '   ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入事项标题'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '不保存的标题');
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pageBack();
    await tester.pumpAndSettle();
    final saved = boot.items.byId(item.id)!;
    expect(saved.title, '取消编辑');
    expect(saved.dueAt, isNull);
    expect(saved.priority, item.priority);
  });

  testWidgets('清除期限并保存不会覆盖编辑期间的完成状态或原有优先级', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('保留完成状态');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.items.update(
      item.copyWith(dueAt: DateTime.now(), priority: Priority.p0),
    );
    await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
    await tester.tap(find.byTooltip('编辑事项'));
    await tester.pumpAndSettle();
    final completed = boot.noteService.toggleItem(item.id);
    await tester.tap(find.text('清除截止时间'));
    await tester.enterText(find.byType(TextFormField), '完成后编辑');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = boot.items.byId(item.id)!;
    expect(saved.title, '完成后编辑');
    expect(saved.dueAt, isNull);
    expect(saved.priority, Priority.p0);
    expect(saved.status, ItemStatus.done);
    expect(saved.completedAt?.toUtc(), completed.completedAt?.toUtc());
    expect(saved.noteId, note.id);
    expect(saved.source, item.source);
  });

  testWidgets('便签事项可编辑且勾选操作仍有效', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('便签中的事项');
    final item = boot.noteService.lineToItem(note.id, 0);
    await tester.pumpWidget(_app(boot, StickyWindow(noteId: note.id)));
    await tester.tap(find.byTooltip('编辑事项'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '已改名的事项');
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('已改名的事项'), findsOneWidget);
    await tester.tap(find.text('已改名的事项'));
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.isDone, isTrue);
    expect(boot.items.byNote(note.id), hasLength(1));
  });

  testWidgets('编辑标题、今天到期和重要程度后出现在今日', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('原事项');
    final item = boot.noteService.lineToItem(note.id, 0);
    await tester.pumpWidget(_app(boot, const MainPanel()));
    await tester.tap(find.text('全部事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原事项'));
    await tester.pumpAndSettle();
    expect(find.text('编辑事项'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '修改后的事项');
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = boot.items.byId(item.id)!;
    expect(saved.title, '修改后的事项');
    expect(saved.priority, Priority.p1);
    final now = DateTime.now();
    expect(saved.dueAt?.toLocal(), DateTime(now.year, now.month, now.day, 23, 59));
    expect(boot.notes.byId(note.id)!.rawContent, '原事项');
    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();
    expect(tester.widget<ItemTile>(find.byType(ItemTile)).item.id, item.id);
    expect(find.text('修改后的事项'), findsOneWidget);
  });
}
