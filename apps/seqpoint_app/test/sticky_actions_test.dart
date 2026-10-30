import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';

void main() {
  for (final action in ['归档', '移入回收站']) {
    for (final fail in [false, true]) {
      testWidgets('便签菜单$action：${fail ? '失败保留窗口并提示' : '成功关闭且可恢复'}', (tester) async {
        final boot = await Bootstrap.run(dbPath: ':memory:');
        addTearDown(boot.dispose);
        final note = boot.noteService.capture('菜单验收');
        if (fail) {
          boot.db.raw.execute("CREATE TRIGGER reject_action BEFORE UPDATE ON notes BEGIN SELECT RAISE(ABORT, 'test'); END;");
        }
        var closed = 0;
        await tester.pumpWidget(MaterialApp(
          home: AppScope(noteService: boot.noteService, notes: boot.notes,
            items: boot.items, tags: boot.tags, search: boot.search,
            child: StickyWindow(noteId: note.id, onClose: () => closed++)),
        ));
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await tester.pumpAndSettle();
        expect(closed, fail ? 0 : 1);
        if (fail) {
          expect(boot.notes.active().single.id, note.id);
          expect(find.text('$action失败，请重试。'), findsOneWidget);
        } else {
          final saved = action == '归档' ? boot.notes.closed() : boot.notes.trashed();
          expect(saved.single.id, note.id);
          expect(saved.single.rawContent, '菜单验收');
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('置顶成功后可取消，失败时保留原状态并提示', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('置顶测试');
    final values = <bool>[];
    var fail = false;
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setAlwaysOnTop') {
        if (fail) throw PlatformException(code: 'failed');
        values.add((call.arguments as Map)['isAlwaysOnTop'] as bool);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          noteService: boot.noteService,
          notes: boot.notes,
          items: boot.items,
          tags: boot.tags,
          search: boot.search,
          windows: DesktopWindowService(),
          child: StickyWindow(noteId: note.id),
        ),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(values, [true]);
    expect(find.byTooltip('取消置顶'), findsOneWidget);
    fail = true;
    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('取消置顶'), findsOneWidget);
    expect(find.text('置顶设置失败，请重试。'), findsOneWidget);
    fail = false;
    await tester.tap(find.byTooltip('取消置顶'));
    await tester.pumpAndSettle();
    expect(values, [true, false]);
  });
  for (final modifier in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.metaLeft,
  ]) {
    testWidgets('${modifier.keyLabel}快捷键操作当前行且完成不反向取消', (tester) async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      addTearDown(boot.dispose);
      final note = boot.noteService.capture('第一行\n第二行');
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AppScope(
            noteService: boot.noteService,
            notes: boot.notes,
            items: boot.items,
            tags: boot.tags,
            search: boot.search,
            child: StickyWindow(noteId: note.id, onClose: () => closed++),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.enter);
      expect(boot.items.byNote(note.id).single.title, '第一行');
      await press(LogicalKeyboardKey.keyD);
      await press(LogicalKeyboardKey.keyD);
      expect(boot.items.byNote(note.id).single.isDone, isTrue);
      await tester.tap(find.text('第二行'));
      await tester.pumpAndSettle();
      await press(LogicalKeyboardKey.enter);
      expect(boot.items.byNote(note.id).every((i) => i.isDone), isTrue);
      await press(LogicalKeyboardKey.keyW);
      expect(boot.notes.closed().single.id, note.id);
      expect(closed, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, 2);
    });
  }
  testWidgets('便签搜索快捷键能查出其他便签，返回后继续显示当前便签', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    addTearDown(boot.dispose);
    final note = boot.noteService.capture('当前便签');
    boot.noteService.capture('搜索目标苹果');
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScope(
          noteService: boot.noteService,
          notes: boot.notes,
          items: boot.items,
          tags: boot.tags,
          search: boot.search,
          child: child!,
        ),
        home: StickyWindow(noteId: note.id),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '苹果');
    await tester.pumpAndSettle();
    expect(find.text('搜索目标苹果'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('当前便签'), findsOneWidget);
  });
}
