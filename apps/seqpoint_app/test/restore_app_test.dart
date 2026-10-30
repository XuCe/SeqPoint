import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/desktop/sticky/note_editor.dart';
import 'package:seqpoint_app/platform/desktop_windows.dart';
import 'package:seqpoint_app/settings/backup_settings_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'notification_support.dart';
import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PathProviderPlatform old;
  const native = MethodChannel('mixin.one/desktop_multi_window');
  const manager = MethodChannel('window_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final live = <Map<String, Object>>[];
  setUp(() {
    directory = Directory.systemTemp.createTempSync('seqpoint_restore_app_');
    old = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _RestorePaths(directory.path);
    messenger.setMockMethodCallHandler(manager, (_) async => null);
    live..clear()..add({'windowId': 'main-7', 'windowArgument': ''});
    messenger.setMockMethodCallHandler(native, (call) async {
      if (call.method == 'getWindowDefinition') return {'windowId': 'main-7', 'windowArgument': ''};
      if (call.method == 'getAllWindows') return List.of(live);
      return null;
    });
  });
  tearDown(() {
      PathProviderPlatform.instance = old;
      messenger.setMockMethodCallHandler(native, null);
      messenger.setMockMethodCallHandler(manager, null);
      DesktopWindowService().pauseStickyOpening(false);
      directory.deleteSync(recursive: true);
  });
  testWidgets('损坏快照在停写前被拒绝且当前容器数据不变', (tester) async {
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    final bad = File('${directory.path}/bad.db')..writeAsStringSync('not a sqlite database');
    await expectLater(scope.restoreSnapshot!(bad), throwsA(predicate((error) =>
        error.toString().contains('not a database'))));
    expect(scope.notes.active().single.rawContent, '旧数据保留');
    expect(scope.restoring, isFalse);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('存在任意非当前窗口拒绝恢复，解除暂停且当前库不变', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    live.add({'windowId': 'unknown-child', 'windowArgument': 'not-json'});
    await expectLater(scope.restoreSnapshot!(source), throwsA(predicate((error) =>
        error.toString().contains('窗口'))));
    expect(scope.notes.active().single.rawContent, '旧数据保留');
    await expectLater(DesktopWindowService().otherWindowIds(), throwsStateError);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('已挂载编辑器的草稿不因恢复而被清空或关闭', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const NoteEditor())));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '不能丢失的未保存草稿');
    await expectLater(scope.restoreSnapshot!(source), throwsA(predicate((error) =>
        error.toString().contains('保存'))));
    expect(find.text('不能丢失的未保存草稿'), findsOneWidget);
    expect(find.byType(NoteEditor), findsOneWidget);
    expect(scope.notes.active(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('主窗已经开始退出时拒绝恢复', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    scope.onQuittingChanged!(true);
    await expectLater(scope.restoreSnapshot!(source), throwsA(predicate((error) =>
        error.toString().contains('正在退出'))));
    expect(scope.notes.active(), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('有效快照重建当前容器并保留可见旧库快照，源文件不变', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final sourceBytes = source.readAsBytesSync();
    final hotkeys = TestHotkeys(); final tray = TestTray();
    addTearDown(hotkeys.events.close);
    final scope = await _mountRoot(tester, app: SeqApp(
        windows: DesktopWindowService(), hotkeys: hotkeys, tray: tray));
    scope.noteService.capture('旧数据保留');
    final oldDatabase = scope.database!;
    expect(await _restoreAndPump(tester, scope, source), isNull);
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.database, isNot(same(oldDatabase)));
    expect(updated.notes.active().single.rawContent, '候选数据');
    expect(() => oldDatabase.raw.select('SELECT 1'), throwsStateError);
    final safety = Directory('${directory.path}/snapshots').listSync().whereType<File>().single;
    expect(SnapshotService.validate(safety), latestSchemaVersion);
    final oldCopy = SeqDatabase.open(safety.path);
    expect(NoteRepository(oldCopy).active().single.rawContent, '旧数据保留');
    oldCopy.close();
    expect(source.readAsBytesSync(), sourceBytes);
    expect(hotkeys.bound, hasLength(4));
    expect(hotkeys.releases, 0); expect(tray.disposals, 0);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('候选语义核验失败关闭候选并重开旧容器，保留保护快照', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory, invalidDate: true)))!;
    final sourceBytes = source.readAsBytesSync();
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    expect(await _restoreAndPump(tester, scope, source), isA<FormatException>());
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.notes.active().single.rawContent, '旧数据保留');
    expect(updated.restoring, isFalse);
    expect(File('${directory.path}/seqpoint.db.restore-pending').existsSync(), isFalse);
    expect(Directory('${directory.path}/snapshots').listSync().whereType<File>(), hasLength(1));
    expect(source.readAsBytesSync(), sourceBytes);
    await expectLater(DesktopWindowService().otherWindowIds(), throwsStateError);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('已完成事项中的坏时间同样阻止提交并恢复旧数据', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory, invalidItemDate: true)))!;
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    expect(await _restoreAndPump(tester, scope, source), isA<FormatException>());
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.notes.active().single.rawContent, '旧数据保留');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('撤销旧提醒失败时不关闭旧库，并重新启动原计划', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final notifications = TestNotifications()..failCancel = true;
    addTearDown(notifications.events.close);
    final scope = await _mountRoot(tester, app: SeqApp(
        windows: DesktopWindowService(), notifications: notifications));
    final note = scope.noteService.capture('旧数据保留');
    final item = scope.noteService.lineToItem(note.id, 0);
    scope.items.update(item.copyWith(dueAt: DateTime.now().add(const Duration(days: 1))));
    await scope.reminders!.reconcile();
    final id = scope.reminders!.plans.active().single.id;
    expect((await _restoreAndPump(tester, scope, source)).toString(), contains('cancel failed'));
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.database, same(scope.database));
    expect(updated.notes.active().single.rawContent, '旧数据保留');
    expect(notifications.scheduled.map((r) => r.id).toSet(), {id});
    expect(File('${directory.path}/seqpoint.db.restore-pending').existsSync(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('存在旧通知ID但通知服务不可用时不冒险换库', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    NotificationPlanRepository(scope.database!).ensure(key: 'old', itemId: 'old-item',
        fireAt: DateTime.now().add(const Duration(days: 1)));
    expect((await _restoreAndPump(tester, scope, source)).toString(), contains('无法撤销旧提醒'));
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.database, same(scope.database));
    expect(updated.notes.active().single.rawContent, '旧数据保留');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('撤销包括历史ID的旧提醒后，按恢复库期限重排', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory, withReminder: true)))!;
    final notifications = TestNotifications();
    addTearDown(notifications.events.close);
    final scope = await _mountRoot(tester, app: SeqApp(
        windows: DesktopWindowService(), notifications: notifications));
    final plans = NotificationPlanRepository(scope.database!);
    final history = plans.ensure(key: 'history', itemId: 'missing', fireAt: DateTime.utc(2020));
    plans.setState(history.id, 'retired');
    final note = scope.noteService.capture('旧数据');
    final item = scope.noteService.lineToItem(note.id, 0);
    scope.items.update(item.copyWith(dueAt: DateTime.now().add(const Duration(days: 1))));
    await scope.reminders!.reconcile();
    final oldId = plans.active().single.id;
    expect(await _restoreAndPump(tester, scope, source), isNull);
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    await tester.runAsync(updated.reminders!.reconcile);
    final restored = updated.items.byNote(updated.notes.active().single.id).single;
    expect(notifications.cancelled, containsAll([history.id, oldId]));
    expect(notifications.scheduled.last.itemId, restored.id);
    expect(updated.reminders, isNot(same(scope.reminders)));
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('等待撤销时Root卸载中止恢复，不在卸载后提交新容器', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final notifications = _GatedCancel();
    addTearDown(notifications.events.close);
    final scope = await _mountRoot(tester, app: SeqApp(
        windows: DesktopWindowService(), notifications: notifications));
    scope.noteService.capture('旧数据保留');
    final plans = NotificationPlanRepository(scope.database!);
    final plan = plans.ensure(key: 'history', itemId: 'missing', fireAt: DateTime.utc(2020));
    plans.setState(plan.id, 'retired');
    var removed = false;
    final error = await _restoreAndPump(tester, scope, source, step: () async {
      if (!removed && notifications.entered.isCompleted) {
        removed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        notifications.release.complete();
      }
    });
    expect(error.toString(), contains('关闭'));
    final old = (await tester.runAsync(() => Bootstrap.run(dbPath: '${directory.path}/seqpoint.db')))!;
    expect(old.notes.active().single.rawContent, '旧数据保留');
    old.dispose();
  });

  testWidgets('恢复成功清理旧路由并展示可见保护副本位置', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据');
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) =>
        const Scaffold(body: Text('旧恢复页')))));
    await tester.pumpAndSettle();
    expect(await _restoreAndPump(tester, scope, source), isNull);
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
    expect(find.text('旧恢复页'), findsNothing);
    final snapshots = Directory('${directory.path}/snapshots').resolveSymbolicLinksSync();
    expect(find.textContaining('原数据保护副本：$snapshots${Platform.pathSeparator}'), findsOneWidget,
        reason: tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join('\n'));
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('换库前已等待唤窗的通知点击返回后不查询旧容器', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final notifications = TestNotifications();
    addTearDown(notifications.events.close);
    final shown = Completer<void>(); final release = Completer<void>();
    var focused = false;
    messenger.setMockMethodCallHandler(manager, (call) async {
      if (call.method == 'isMinimized') return false;
      if (call.method == 'show') { shown.complete(); await release.future; }
      if (call.method == 'focus') focused = true;
      return null;
    });
    final scope = await _mountRoot(tester, app: SeqApp(
        windows: DesktopWindowService(), notifications: notifications));
    final note = scope.noteService.capture('旧任务');
    final item = scope.noteService.lineToItem(note.id, 0);
    notifications.events.add((itemId: item.id, action: NotificationAction.open));
    await tester.runAsync(() async {});
    await tester.pump();
    expect(shown.isCompleted, isTrue);
    expect(await _restoreAndPump(tester, scope, source), isNull);
    release.complete();
    await tester.runAsync(() async {}); await tester.pumpAndSettle();
    expect(focused, isTrue);
    expect(find.textContaining('打开提醒失败'), findsNothing);
    expect(tester.widget<AppScope>(find.byType(AppScope)).notes.active().single.rawContent, '候选数据');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  testWidgets('当前数据库不能作为恢复源，不关闭连接或生成保护副本', (tester) async {
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    final target = File('${directory.path}/seqpoint.db');
    final bytes = target.readAsBytesSync();
    final error = await _restoreAndPump(tester, scope, target);
    final updated = tester.widget<AppScope>(find.byType(AppScope));
    expect(updated.database, same(scope.database));
    expect(error.toString(), contains('当前数据库'));
    expect(target.readAsBytesSync(), bytes);
    expect(Directory('${directory.path}/snapshots').existsSync(), isFalse);
    expect(updated.notes.active().single.rawContent, '旧数据保留');
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });

  for (final damage in ['required', 'unique']) {
    testWidgets('结构缺陷$damage在Root停写前拒绝且不替换当前数据库', (tester) async {
      final source = _badSchemaSnapshot(directory, damage);
      final bytes = source.readAsBytesSync();
      final scope = await _mountRoot(tester);
      scope.noteService.capture('旧数据保留');
      expect((await _restoreAndPump(tester, scope, source)).toString(), contains('快照'));
      final updated = tester.widget<AppScope>(find.byType(AppScope));
      expect(updated.database, same(scope.database));
      expect(updated.notes.active().single.rawContent, '旧数据保留');
      expect(Directory('${directory.path}/snapshots').existsSync(), isFalse);
      expect(source.readAsBytesSync(), bytes);
      await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
    });
  }

  testWidgets('设置文件选择与确认串联真实Root事务，返回主路由显示新库', (tester) async {
    final source = (await tester.runAsync(() => _sourceSnapshot(directory)))!;
    final scope = await _mountRoot(tester);
    scope.noteService.capture('旧数据保留');
    const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
    var picks = 0;
    messenger.setMockMethodCallHandler(picker, (call) async {
      expect(call.method, 'any'); picks++;
      return [{'name': 'source.snapshot.db', 'path': source.path, 'size': source.lengthSync()}];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(picker, null));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push<void>(MaterialPageRoute(builder: (_) => const BackupSettingsPage())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从本机快照恢复')); await tester.pumpAndSettle();
    expect(scope.notes.active().single.rawContent, '旧数据保留');
    await tester.tap(find.widgetWithText(FilledButton, '确认恢复'));
    await tester.pump();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (identical(tester.widget<AppScope>(find.byType(AppScope)).database, scope.database)) {
        if (DateTime.now().isAfter(deadline)) fail('UI恢复未完成');
        await Future<void>.delayed(Duration.zero); await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(picks, 1); expect(navigator.canPop(), isFalse);
    expect(find.byType(BackupSettingsPage), findsNothing);
    expect(tester.widget<AppScope>(find.byType(AppScope)).notes.active().single.rawContent, '候选数据');
    expect(Directory('${directory.path}/snapshots').listSync().whereType<File>(), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });
}

class _RestorePaths extends PathProviderPlatform {
  _RestorePaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _GatedCancel extends TestNotifications {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> cancel(int id) async {
    entered.complete(); await release.future;
    await super.cancel(id);
  }
}

Future<AppScope> _mountRoot(WidgetTester tester, {SeqApp? app}) async {
  await tester.pumpWidget(app ?? SeqApp(windows: DesktopWindowService()));
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (find.byType(AppScope).evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('Root未装配完成');
      await Future<void>.delayed(Duration.zero); await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  return tester.widget<AppScope>(find.byType(AppScope));
}

File _badSchemaSnapshot(Directory directory, String damage) {
  final file = File('${directory.path}/incompatible.db');
  final db = SeqDatabase.open(file.path)..migrate();
  if (damage == 'required') {
    db.raw.execute('ALTER TABLE notes ADD COLUMN required_extension TEXT NOT NULL');
  } else {
    final sql = db.raw.select('SELECT sql FROM sqlite_master WHERE name = ?',
        ['notification_plans']).single['sql'] as String;
    db.raw.execute('DROP TABLE notification_plans');
    db.raw.execute(sql.replaceFirst(' UNIQUE', ''));
  }
  db.close(); return file;
}

Future<File> _sourceSnapshot(Directory directory, {bool invalidDate = false,
    bool invalidItemDate = false, bool withReminder = false}) async {
  final file = File('${directory.path}/source.snapshot.db');
  final boot = await Bootstrap.run(dbPath: file.path);
  final note = boot.noteService.capture('候选数据');
  if (invalidItemDate || withReminder) {
    final item = boot.noteService.lineToItem(note.id, 0);
    if (invalidItemDate) {
      boot.noteService.toggleItem(item.id);
      boot.db.raw.execute('UPDATE items SET created_at = ?', ['invalid-time']);
    } else {
      boot.items.update(item.copyWith(dueAt: DateTime.now().add(const Duration(days: 1))));
    }
  }
  if (invalidDate) boot.db.raw.execute('UPDATE notes SET created_at = ?', ['invalid-time']);
  boot.dispose();
  return file;
}

Future<Object?> _restoreAndPump(WidgetTester tester, AppScope scope, File source,
    {Future<void> Function()? step}) async {
  var done = false;
  Object? failure;
  await tester.runAsync(() async {
    unawaited(scope.restoreSnapshot!(source).then<void>((_) { done = true; },
        onError: (Object error, StackTrace stack) { failure = error; done = true; }));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done) {
      await step?.call();
      if (DateTime.now().isAfter(deadline)) fail('恢复未结束');
      await Future<void>.delayed(Duration.zero); await tester.pump();
    }
  });
  await tester.pump();
  return failure;
}
