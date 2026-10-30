import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/desktop/sticky/item_row.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  testWidgets('通过界面编辑事项后重启保留标题、今天期限、重要程度及完成状态', (tester) async {
    final root = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('seqpoint-persistence-'),
    ))!;
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider('${root.path}/data');
    Bootstrap? opened;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      opened?.dispose();
      PathProviderPlatform.instance = original;
      await tester.runAsync(() => root.delete(recursive: true));
    });
    var boot = await tester.runAsync(() async {
      await tester.pumpWidget(const SeqApp());
      return tester
          .widget<FutureBuilder<Bootstrap>>(
            find.byType(FutureBuilder<Bootstrap>),
          )
          .future!;
    });
    opened = boot;
    final note = boot!.noteService.capture('待办一\n待办二\n待清除期限', title: '持久化便签');
    final done = boot.noteService.lineToItem(note.id, 0);
    final todo = boot.noteService.lineToItem(note.id, 1);
    final cleared = boot.noteService.lineToItem(note.id, 2);
    boot.items.update(cleared.copyWith(dueAt: DateTime.now()));
    final completed = boot.noteService.toggleItem(done.id);
    final tag = boot.tags.upsert(
      name: '完整性复测',
      kind: TagKind.project,
      color: '#112233',
    );
    boot.items.setTags(todo.id, [tag.id]);
    boot.items.update(
      todo.copyWith(
        source: ItemSource.ai,
        sourceRef: SourceRef(noteId: note.id, timestampMs: 3456),
        hlc: 'retest-hlc',
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(SeqApp.sticky(noteId: note.id));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑事项').at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '重启后仍保留的标题');
    await tester.tap(find.text('今天到期'));
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final clearedRow = find.ancestor(
      of: find.text('待清除期限'),
      matching: find.byType(ItemRow),
    );
    await tester.tap(
      find.descendant(of: clearedRow, matching: find.byTooltip('编辑事项')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除截止时间'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final due = DateTime(now.year, now.month, now.day, 23, 59);
    final saved = boot.items.byId(todo.id)!;
    expect(saved.noteId, todo.noteId);
    expect(saved.lineIndex, todo.lineIndex);
    expect(saved.source, ItemSource.ai);
    expect(saved.sourceRef?.timestampMs, 3456);
    expect(saved.createdAt, todo.createdAt);
    final savedRows = boot.db.raw
        .select('SELECT * FROM items WHERE note_id = ? ORDER BY id', [note.id])
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    final savedNote = Map<String, Object?>.from(
      boot.db.raw.select('SELECT * FROM notes WHERE id = ?', [note.id]).single,
    );
    await tester.pumpWidget(const SeqApp());
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ItemTile>(find.byType(ItemTile))
          .map((tile) => tile.item.id),
      unorderedEquals([done.id, todo.id]),
    );
    expect(find.text('重启后仍保留的标题'), findsOneWidget);
    expect(find.text('待清除期限'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    boot.dispose();
    opened = null;
    boot = await tester.runAsync(() async {
      await tester.pumpWidget(const SeqApp());
      return tester
          .widget<FutureBuilder<Bootstrap>>(
            find.byType(FutureBuilder<Bootstrap>),
          )
          .future!;
    });
    opened = boot;
    expect(boot!.notes.byId(note.id)?.rawContent, note.rawContent);
    expect(boot.notes.byId(note.id)?.title, note.title);
    expect(boot.items.byNote(note.id), hasLength(3));
    expect(boot.items.byId(cleared.id)?.dueAt, isNull);
    expect(boot.items.byId(cleared.id)?.status, ItemStatus.todo);
    expect(boot.items.byId(done.id)?.status, ItemStatus.done);
    expect(boot.items.byId(todo.id)?.status, ItemStatus.todo);
    expect(boot.items.byId(todo.id)?.dueAt?.toLocal(), due);
    expect(boot.items.byId(todo.id)?.title, '重启后仍保留的标题');
    expect(boot.items.byId(todo.id)?.priority, Priority.p1);
    expect(boot.items.byId(done.id)?.completedAt?.toUtc(), completed.completedAt?.toUtc());
    expect(boot.items.byId(todo.id)?.sourceRef?.noteId, note.id);
    expect(boot.items.byId(todo.id)?.hlc, 'retest-hlc');
    expect(boot.items.tagIdsOf(todo.id), [tag.id]);
    expect(boot.tags.byId(tag.id)?.name, tag.name);
    expect(boot.tags.byId(tag.id)?.color, tag.color);
    expect(
      boot.db.raw
          .select('SELECT * FROM items WHERE note_id = ? ORDER BY id', [
            note.id,
          ])
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
      savedRows,
    );
    expect(
      Map<String, Object?>.from(
        boot.db.raw.select('SELECT * FROM notes WHERE id = ?', [
          note.id,
        ]).single,
      ),
      savedNote,
    );
    expect(boot.items.dueOn(now).map((i) => i.id), contains(todo.id));
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<ItemTile>(find.byType(ItemTile))
          .map((tile) => tile.item.id),
      unorderedEquals([done.id, todo.id]),
    );
    expect(find.text('重启后仍保留的标题'), findsOneWidget);
    expect(find.text('待清除期限'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
