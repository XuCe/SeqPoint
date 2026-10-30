import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/settings/backup_settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  late Bootstrap boot;
  late Directory dir;
  String? selected;
  var calls = 0;
  Map<String, dynamic>? saved;
  Future<void> Function(File)? restore;
  final names = <String>[];
  var saveFails = false;
  late PathProviderPlatform oldPaths;
  setUp(() async {
    boot = await Bootstrap.run(dbPath: ':memory:');
    boot.noteService.capture('要导出的正文');
    dir = Directory.systemTemp.createTempSync('seqpoint_backup_ui_');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _BackupPaths(dir.path);
    saved = null;
    restore = null;
    names.clear(); saveFails = false;
    selected = null; calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
      calls++;
      if (call.method == 'save') {
        saved = Map<String, dynamic>.from(call.arguments as Map);
        names.add(saved!['fileName'] as String);
        if (defaultTargetPlatform == TargetPlatform.iOS) {
          File('${dir.path}/${saved!['fileName']}')
              .writeAsBytesSync(saved!['bytes'] as List<int>);
        }
        if (saveFails) throw PlatformException(code: 'save_failed', message: '故障注入');
      } else if (call.method == 'any') {
        return selected == null ? null : [
          {'name': 'selected.snapshot.db', 'path': selected, 'size': 0},
        ];
      } else {
        expect(call.method, 'dir');
      }
      return selected;
    });
  });
  tearDown(() {
    boot.dispose(); dir.deleteSync(recursive: true);
    PathProviderPlatform.instance = oldPaths;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
  });
  Future<void> show(WidgetTester tester) => tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppScope(database: boot.db,
          restoreSnapshot: restore,
          noteService: boot.noteService, notes: boot.notes, items: boot.items,
          tags: boot.tags, search: boot.search, child: child!),
      home: const BackupSettingsPage()));

  Future<void> waitForOperation(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('真实导出未结束');
        await Future<void>.delayed(Duration.zero);
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> export(WidgetTester tester, String format) async {
    await tester.tap(find.text('导出为 $format'));
    await waitForOperation(tester);
  }

  Future<File> inputSnapshot(WidgetTester tester) async =>
      (await tester.runAsync(() => SnapshotService(boot.db)
          .createManual(Directory('${dir.path}/input'))))!.file;

  testWidgets('取消位置选择不生成导出文件，也不显示成功', (tester) async {
    await show(tester);
    await tester.tap(find.text('导出为 JSON'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(dir.listSync(), isEmpty);
    expect(find.textContaining('已导出至'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('取消快照文件选择不确认、不调用恢复也不创建文件', (tester) async {
    var restores = 0;
    restore = (_) async { restores++; };
    await show(tester);
    await tester.tap(find.text('从本机快照恢复'));
    await tester.pumpAndSettle();
    expect(calls, 1); expect(restores, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(dir.listSync(), isEmpty);
    expect(boot.notes.active().single.rawContent, '要导出的正文');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('列表快照先显示确认范围，取消不调用恢复且源字节不变', (tester) async {
    var restores = 0;
    restore = (_) async { restores++; };
    await show(tester);
    await tester.tap(find.text('立即备份'));
    await waitForOperation(tester);
    final source = Directory('${dir.path}/snapshots').listSync().whereType<File>().single;
    final bytes = source.readAsBytesSync();
    await tester.tap(find.byIcon(Icons.restore));
    await tester.pumpAndSettle();
    expect(find.text('确认恢复本机快照'), findsOneWidget);
    expect(find.textContaining('未加密保护快照'), findsOneWidget);
    expect(find.textContaining('校验通过'), findsOneWidget);
    expect(find.textContaining('文件修改时间：${source.lastModifiedSync().toLocal()}'), findsOneWidget);
    expect(restores, 0);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(restores, 0); expect(source.readAsBytesSync(), bytes);
    expect(boot.notes.active().single.rawContent, '要导出的正文');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('选中文件须确认才恢复，等待回调时阻止再次操作', (tester) async {
    final source = await inputSnapshot(tester);
    final bytes = source.readAsBytesSync();
    selected = source.path;
    final received = <File>[]; final gate = Completer<void>();
    restore = (file) async { received.add(file); await gate.future; };
    await show(tester);
    await tester.tap(find.text('从本机快照恢复')); await tester.pumpAndSettle();
    expect(received, isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('格式 v$latestSchemaVersion'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确认恢复'));
    await tester.pump();
    expect(received.single.path, source.path);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    gate.complete(); await waitForOperation(tester);
    expect(received, hasLength(1)); expect(calls, 1);
    expect(source.readAsBytesSync(), bytes);
  }, variant: TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.iOS, TargetPlatform.android}));

  testWidgets('非快照文件在确认前拒绝，不触发恢复或创建保护文件', (tester) async {
    final source = File('${dir.path}/wrong.json')..writeAsStringSync('{}');
    selected = source.path;
    var restores = 0; restore = (_) async { restores++; };
    await show(tester);
    await tester.tap(find.text('从本机快照恢复')); await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('恢复失败'), findsOneWidget);
    expect(restores, 0); expect(source.readAsStringSync(), '{}');
    expect(Directory('${dir.path}/snapshots').existsSync(), isFalse);
    expect(boot.notes.active().single.rawContent, '要导出的正文');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('恢复回调失败显示原因并允许重试，旧数据和源文件保留', (tester) async {
    final source = await inputSnapshot(tester);
    selected = source.path;
    final bytes = source.readAsBytesSync();
    var attempts = 0;
    restore = (_) async { attempts++; if (attempts == 1) throw StateError('旧提醒撤销失败'); };
    await show(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('从本机快照恢复')); await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确认恢复'));
      await waitForOperation(tester);
      if (i == 0) expect(find.textContaining('旧提醒撤销失败'), findsOneWidget);
    }
    expect(attempts, 2); expect(source.readAsBytesSync(), bytes);
    expect(boot.notes.active().single.rawContent, '要导出的正文');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('立即备份生成有效未加密本机快照，重复操作保留旧文件并刷新列表', (tester) async {
    await show(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('立即备份'));
      await waitForOperation(tester);
      expect(find.textContaining('备份失败：'), findsNothing);
    }
    final files = Directory('${dir.path}/snapshots').listSync().whereType<File>().toList();
    expect(files, hasLength(2));
    for (final file in files) {
      expect(SnapshotService.validate(file), latestSchemaVersion);
      final copy = SeqDatabase.open(file.path);
      expect(NoteRepository(copy).active().single.rawContent, '要导出的正文');
      copy.close();
      expect(find.descendant(of: find.byType(FutureBuilder<List<Snapshot>>),
          matching: find.textContaining(file.path)), findsOneWidget);
    }
    expect(find.text('未加密本机快照'), findsOneWidget);
    expect(find.textContaining('SQLite · 未校验（恢复前校验）'), findsNWidgets(2));
    expect(find.text('查看恢复密钥'), findsNothing);
    expect(calls, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('支持目录获取失败可见，条件恢复后立即备份可重试', (tester) async {
    PathProviderPlatform.instance = _BackupPaths(dir.path, failSupport: true);
    await show(tester);
    await tester.pumpAndSettle();
    expect(find.text('无法读取本机快照'), findsOneWidget);
    PathProviderPlatform.instance = _BackupPaths(dir.path);
    await tester.tap(find.text('立即备份'));
    await waitForOperation(tester);
    expect(find.textContaining('已生成未加密本机快照：'), findsOneWidget,
        reason: tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join('\n'));
    expect(Directory('${dir.path}/snapshots').listSync().whereType<File>(), hasLength(1));
    expect(find.text('无法读取本机快照'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('新快照写失败保留旧快照和列表，显示失败原因', (tester) async {
    await show(tester);
    await tester.tap(find.text('立即备份'));
    await waitForOperation(tester);
    final folder = Directory('${dir.path}/snapshots');
    final old = folder.listSync().whereType<File>().single;
    final bytes = old.readAsBytesSync();
    boot.db.raw.execute('BEGIN IMMEDIATE');
    try {
      await tester.tap(find.text('立即备份'));
      await waitForOperation(tester);
      expect(find.textContaining('备份失败：'), findsOneWidget);
      expect(old.readAsBytesSync(), bytes);
      expect(folder.listSync().map((e) => e.path), [old.path]);
    } finally { boot.db.raw.execute('ROLLBACK'); }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('备份等待目录期间重复点击只创建一个快照', (tester) async {
    await show(tester);
    await tester.pumpAndSettle();
    final response = Completer<String?>();
    PathProviderPlatform.instance = _BackupPaths(dir.path, waitSupport: response.future);
    await tester.tap(find.text('立即备份'));
    await tester.pump();
    await tester.tap(find.text('立即备份'));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    response.complete(dir.path);
    await waitForOperation(tester);
    expect(Directory('${dir.path}/snapshots').listSync().whereType<File>(), hasLength(1));
    expect(calls, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final format in ['JSON', 'Markdown']) {
      for (final success in [false, true]) {
        testWidgets('$platform $format系统保存结果=$success且清理应用副本', (tester) async {
          selected = success ? '${dir.path}/selected-target' : null;
          final old = File('${dir.path}/old.json')..writeAsStringSync('旧导出保留');
          await show(tester);
          await export(tester, format);
          expect(saved, isNotNull);
          final bytes = saved!['bytes'] as List<int>;
          final content = format == 'JSON' ? utf8.decode(bytes) :
              ZipDecoder().decodeBytes(bytes).map((f) => utf8.decode(f.readBytes()!)).join('\n');
          expect(content, contains('要导出的正文'));
          expect(content, isNot(contains('"secrets"')));
          expect(dir.listSync().map((f) => f.path), [old.path]);
          expect(old.readAsStringSync(), '旧导出保留');
          expect(find.textContaining('已交由系统保存'), success ? findsOneWidget : findsNothing);
        }, variant: TargetPlatformVariant.only(platform));
      }
    }
  }

  testWidgets('iOS原生保存抛错也清理副本并保留旧文件', (tester) async {
    saveFails = true;
    final old = File('${dir.path}/old.json')..writeAsStringSync('保留旧文件');
    await show(tester);
    await export(tester, 'JSON');
    expect(find.textContaining('导出失败：'), findsOneWidget);
    expect(find.textContaining('故障注入'), findsOneWidget);
    expect(dir.listSync().map((e) => e.path), [old.path]);
    expect(old.readAsStringSync(), '保留旧文件');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS重复保存使用不同名字，不留下插件明文副本', (tester) async {
    selected = '${dir.path}/native-result';
    await show(tester);
    await export(tester, 'JSON');
    await export(tester, 'JSON');
    expect(names, hasLength(2));
    expect(names.toSet(), hasLength(2));
    expect(names.every((name) => name.endsWith('.json')), isTrue);
    expect(dir.listSync(), isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  for (final format in ['JSON', 'Markdown']) {
    testWidgets('$format保存到实际选择目录并显示生成位置', (tester) async {
      selected = dir.path;
      await show(tester);
      await export(tester, format);
      expect(calls, 1);
      expect(find.textContaining('已导出至 ${dir.path}'), findsOneWidget);
      final files = dir.listSync(recursive: true).whereType<File>();
      expect(files.any((f) => f.readAsStringSync().contains('要导出的正文')), isTrue);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('写入失败显示原因且不宣称成功', (tester) async {
    final file = File('${dir.path}/file')..writeAsStringSync('保留');
    selected = file.path;
    await show(tester);
    await export(tester, 'JSON');
    expect(find.textContaining('导出失败：'), findsOneWidget);
    expect(find.textContaining('已导出至'), findsNothing);
    expect(file.readAsStringSync(), '保留');
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('选择位置期间重复点击不启动第二次导出', (tester) async {
    final response = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async { calls++; return response.future; });
    await show(tester);
    await tester.tap(find.text('导出为 JSON'));
    await tester.pump();
    await tester.tap(find.text('导出为 Markdown'));
    expect(calls, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    response.complete(null);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

class _BackupPaths extends PathProviderPlatform {
  _BackupPaths(this.path, {this.failSupport = false, this.waitSupport});
  final String path;
  final bool failSupport;
  final Future<String?>? waitSupport;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async {
    if (failSupport) throw FileSystemException('支持目录不可用', path);
    if (waitSupport != null) return waitSupport!;
    return path;
  }
}
