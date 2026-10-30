import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/shared/item_tile.dart';

Widget app(Bootstrap boot) => MaterialApp(
  builder: (_, child) => AppScope(
    noteService: boot.noteService,
    notes: boot.notes,
    items: boot.items,
    tags: boot.tags,
    search: boot.search,
    child: child!,
  ),
  home: const MobileShell(),
);

void main() {
  testWidgets('我的可打开应用更新并返回', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    await tester.pumpWidget(app(boot));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('应用更新'));
    await tester.tap(find.text('应用更新'));
    await tester.pumpAndSettle();
    expect(find.text('热更新不可用'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('应用更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('回收站可恢复便签及关联事项，返回后数量和标签可见性刷新', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('回收站恢复目标');
    final item = boot.noteService.lineToItem(note.id, 0);
    final tag = boot.tags.all().firstWhere((t) => t.name == '开发');
    boot.items.setTags(item.id, [tag.id]);
    boot.noteService.trash(note.id);
    await tester.pumpWidget(app(boot));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.text('回收站恢复目标'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.id, note.id);
    expect(boot.items.byTag(tag.id).single.id, item.id);
    expect(find.text('回收站恢复目标'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('1 张'), findsNothing);
    await tester.tap(find.text('便签').last);
    await tester.pumpAndSettle();
    expect(find.text('回收站恢复目标'), findsOneWidget);
  });
  testWidgets('归档入口可恢复便签，返回后更新数量并出现在便签墙', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('恢复归档目标');
    boot.noteService.close(note.id);
    await tester.pumpWidget(app(boot));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(find.text('1 张'), findsOneWidget);
    await tester.ensureVisible(find.text('已归档'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已归档'));
    await tester.pumpAndSettle();
    expect(find.text('恢复归档目标'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await tester.pumpAndSettle();
    expect(boot.notes.active().single.id, note.id);
    expect(find.text('恢复归档目标'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('0 张'), findsOneWidget);
    await tester.tap(find.text('便签').last);
    await tester.pumpAndSettle();
    expect(find.text('恢复归档目标'), findsOneWidget);
  });
  testWidgets('标签筛选仅显示关联且未删除的事项，并可完成', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final tag = boot.tags.all().firstWhere((t) => t.name == '开发');
    final note = boot.noteService.capture('标签目标\n未关联事项');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.noteService.lineToItem(note.id, 1);
    boot.items.setTags(item.id, [tag.id]);
    final deleted = boot.noteService.capture('标签已删除');
    final hidden = boot.noteService.lineToItem(deleted.id, 0);
    boot.items.setTags(hidden.id, [tag.id]);
    boot.noteService.trash(deleted.id);
    await tester.pumpWidget(app(boot));
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('标签'));
    await tester.pumpAndSettle();
    expect(find.text('开发'), findsOneWidget);
    await tester.tap(find.text('开发'));
    await tester.pumpAndSettle();
    expect(find.text('标签目标'), findsOneWidget);
    expect(find.text('未关联事项'), findsNothing);
    expect(find.text('标签已删除'), findsNothing);
    expect(boot.tags.usageCount(tag.id), 1);
    tester.widget<ItemTile>(find.byType(ItemTile)).onToggle!();
    await tester.pumpAndSettle();
    expect(boot.items.byId(item.id)!.isDone, isTrue);
  });
  for (final tab in ['今日', '便签']) {
    testWidgets('$tab搜索可打开归档便签，删除便签不出现在结果中', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final archived = boot.noteService.capture('苹果已归档');
      boot.noteService.close(archived.id);
      final deleted = boot.noteService.capture('苹果已删除');
      boot.noteService.trash(deleted.id);
      await tester.pumpWidget(app(boot));
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '苹果');
      await tester.pumpAndSettle();
      expect(find.text('苹果已归档'), findsOneWidget);
      expect(find.text('苹果已删除'), findsNothing);
      await tester.tap(find.text('苹果已归档'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<NoteDetailPage>(find.byType(NoteDetailPage)).noteId,
        archived.id,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byTooltip('搜索'), findsOneWidget);
    });
  }
}
