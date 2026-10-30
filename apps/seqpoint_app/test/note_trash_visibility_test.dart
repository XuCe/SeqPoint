import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_app/shared/note_card.dart';
import 'package:window_manager/window_manager.dart';

Widget _app(Bootstrap b, Widget home) => MaterialApp(
  builder: (_, child) => AppScope(noteService: b.noteService, notes: b.notes,
    items: b.items, tags: b.tags, search: b.search, child: child!), home: home);

void main() {
  testWidgets('移动端删除菜单立即隐藏事项，从其他入口恢复后重新显示', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('移动删除待办\n移动删除完成');
    final todo = b.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    b.items.update(todo.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)));
    b.noteService.toggleItem(b.noteService.lineToItem(note.id, 1).id);
    await t.pumpWidget(_app(b, const MobileShell()));
    expect(find.byType(ItemTile), findsNWidgets(2));
    await t.tap(find.text('便签'));
    await t.pumpAndSettle();
    await t.tap(find.byType(NoteCard));
    await t.pumpAndSettle();
    await t.tap(find.byType(PopupMenuButton<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('删除'));
    await t.pumpAndSettle();
    expect(b.notes.byId(note.id)!.deletedAt, isNotNull);
    await t.tap(find.text('全部事项'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNothing);
    await t.tap(find.text('今日'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNothing);
    b.noteService.restore(note.id);
    await t.tap(find.text('便签'));
    await t.pumpAndSettle();
    await t.tap(find.text('全部事项'));
    await t.pumpAndSettle();
    expect(t.widget<ItemTile>(find.byType(ItemTile)).item.id, todo.id);
    await t.tap(find.text('今日'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNWidgets(2));
  });

  testWidgets('桌面删除便签后隐藏待办和完成事项，从回收站恢复后重新显示', (t) async {
    final b = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(b.dispose);
    final note = b.noteService.capture('删除恢复待办\n删除恢复完成');
    final todo = b.noteService.lineToItem(note.id, 0);
    final now = DateTime.now();
    b.items.update(todo.copyWith(dueAt: DateTime(now.year, now.month, now.day, 23, 59)));
    b.noteService.toggleItem(b.noteService.lineToItem(note.id, 1).id);
    await t.pumpWidget(_app(b, const MainPanel()));
    expect(find.byType(ItemTile), findsNWidgets(2));
    b.noteService.trash(note.id);
    (t.state(find.byType(MainPanel)) as WindowListener).onWindowFocus();
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNothing);
    await t.tap(find.text('全部事项'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNothing);
    await t.tap(find.text('回收站'));
    await t.pumpAndSettle();
    await t.tap(find.text('恢复'));
    await t.pumpAndSettle();
    await t.tap(find.text('今日'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsNWidgets(2));
    await t.tap(find.text('全部事项'));
    await t.pumpAndSettle();
    expect(find.byType(ItemTile), findsOneWidget);
    expect(t.widget<ItemTile>(find.byType(ItemTile)).item.id, todo.id);
  });
}
