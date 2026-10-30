import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'desktop_residency_support.dart';
import 'global_hotkey_support.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _Secrets extends Fake implements SecretStore {}

class _Sync extends AppSyncService {
  _Sync(SeqDatabase db, Directory root, this.refresh)
      : super(db: db, root: root, secrets: _Secrets());
  final Future<void> Function() refresh;
  final gate = Completer<void>();
  int stops = 0;
  int stopFailures = 0;
  @override
  Future<void> stop() {
    stops++;
    if (stopFailures > 0) { stopFailures--; return Future.error(StateError('temporary-stop')); }
    return gate.future;
  }
}

Future<AppScope> _mount(WidgetTester tester, SeqApp app) async {
  await tester.pumpWidget(app);
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (find.byType(AppScope).evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('Root启动未完成');
      await Future<void>.delayed(Duration.zero); await tester.pump();
    }
  });
  await tester.pumpAndSettle();
  return tester.widget<AppScope>(find.byType(AppScope));
}

void main() {
  late Directory directory;
  late PathProviderPlatform old;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('root-sync-');
    old = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory.path);
  });
  tearDown(() { PathProviderPlatform.instance = old; directory.deleteSync(recursive: true); });
  testWidgets('Root排空临时失败不关库，错误消除后重新执行停止', (tester) async {
    late _Sync sync;
    final scope = await _mount(tester, SeqApp(syncFactory: (db, root, refresh) => sync = _Sync(db, root, refresh)));
    final db = scope.database!;
    addTearDown(db.close);
    sync.stopFailures = 1;
    await expectLater(scope.beforeQuit!(), throwsStateError);
    expect(db.raw.select('SELECT 1'), hasLength(1));
    sync.gate.complete();
    await scope.beforeQuit!();
    expect(sync.stops, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
    expect(() => db.raw.select('SELECT 1'), throwsStateError);
  });
  testWidgets('恢复等待旧同步排空后才备份换库，并重建新服务', (tester) async {
    final source = (await tester.runAsync(() async {
      final boot = await Bootstrap.run(dbPath: '${directory.path}/source.db');
      try {
        boot.noteService.capture('候选数据');
        return (await SnapshotService(boot.db).createManual(Directory('${directory.path}/source-snaps'))).file;
      } finally { boot.dispose(); }
    }))!;
    final syncs = <_Sync>[];
    final scope = await _mount(tester, SeqApp(syncFactory: (db, root, refresh) {
      final service = _Sync(db, root, refresh);
      if (syncs.isNotEmpty) service.gate.complete();
      syncs.add(service); return service;
    }));
    var done = false;
    Object? failure;
    final restoration = scope.restoreSnapshot!(source).then((_) { done = true; },
        onError: (Object e) { failure = e; done = true; });
    try {
      await tester.pump(); await tester.pump();
      expect(syncs.single.stops, greaterThan(0));
      expect(scope.database!.raw.select('SELECT 1'), hasLength(1));
      expect(Directory('${directory.path}/snapshots').existsSync(), isFalse);
    } finally { if (!syncs.first.gate.isCompleted) syncs.first.gate.complete(); }
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!done) {
        if (DateTime.now().isAfter(deadline)) fail('恢复未排空');
        await Future<void>.delayed(Duration.zero); await tester.pump();
      }
    });
    await restoration; await tester.pumpAndSettle();
    expect(failure, isNull);
    expect(syncs, hasLength(2));
    final current = tester.widget<AppScope>(find.byType(AppScope));
    expect(current.sync, same(syncs.last));
    expect(current.notes.active().single.rawContent, '候选数据');
    expect(() => scope.database!.raw.select('SELECT 1'), throwsStateError);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });
  testWidgets('退出等待同步排空，失败保留主窗且可重试', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final hotkeys = TestHotkeys(), tray = TestTray();
    final gate = Completer<void>(), calls = <String>[];
    var reject = true;
    const channel = MethodChannel('window_manager');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method); return null;
    });
    addTearDown(() async {
      boot.dispose(); await hotkeys.events.close();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });
    await tester.pumpWidget(AppScope(noteService: boot.noteService, notes: boot.notes,
      items: boot.items, tags: boot.tags, search: boot.search,
      beforeQuit: () async { if (reject) throw StateError('test'); await gate.future; },
      child: MaterialApp(home: MainPanel(hotkeys: hotkeys, tray: tray))));
    await tester.pumpAndSettle();
    tray.quit!.call(); await tester.pumpAndSettle();
    expect(calls, isNot(contains('destroy')));
    expect(find.text('同步仍在关闭中，请稍后重试退出'), findsOneWidget);
    reject = false;
    tray.quit!.call(); await tester.pump();
    expect(calls, isNot(contains('destroy')));
    gate.complete();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(calls.where((call) => call == 'destroy'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pumpAndSettle();
  });
  testWidgets('主Root通过Scope暴露服务，远端提交触发revision，销毁先排空再关DB', (tester) async {
    late _Sync sync;
    final scope = await _mount(tester, SeqApp(syncFactory: (db, root, refresh) => sync = _Sync(db, root, refresh)));
    final db = scope.database!;
    expect(scope.sync, same(sync));
    final previous = scope.syncRevision;
    await sync.refresh(); await tester.pump();
    expect(tester.widget<AppScope>(find.byType(AppScope)).syncRevision, previous + 1);
    await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
    expect(sync.stops, greaterThan(0));
    expect(db.raw.select('SELECT 1'), hasLength(1));
    sync.gate.complete(); await tester.pumpAndSettle();
    expect(() => db.raw.select('SELECT 1'), throwsStateError);
  });
}
