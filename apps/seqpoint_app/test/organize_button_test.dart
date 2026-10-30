import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/settings/ai_settings_store.dart';
import 'package:seqpoint_app/shared/organize_button.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/desktop/sticky/sticky_window.dart';

void main() {
  late Bootstrap boot; late Note note; late AiSettingsStore settings;
  late _Secrets secrets; late _Provider provider;
  var refreshed = 0;
  setUp(() async {
    boot = await Bootstrap.run(dbPath: ':memory:'); refreshed = 0;
    note = boot.noteService.capture('[ ] 回复客户\n[ ] 整理文档');
    SharedPreferences.setMockInitialValues({});
    secrets = _Secrets(); provider = _Provider();
    settings = AiSettingsStore(await SharedPreferences.getInstance(), secrets);
  });
  tearDown(() => boot.dispose());
  Widget app({bool restoring = false, Future<AiSettingsStore> Function()? load, Widget? body}) =>
      AppScope(database: boot.db, restoring: restoring, noteService: boot.noteService,
      notes: boot.notes, items: boot.items, tags: boot.tags, search: boot.search,
      child: MaterialApp(home: body ?? Scaffold(body: OrganizeButton(noteId: note.id,
          loadSettings: load ?? () async => settings, provider: provider, onApplied: () { refreshed++; }))));
  testWidgets('本地整理先预览不写库，确认后持久化并刷新，保留原文', (tester) async {
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    expect(find.text('整理预览'), findsOneWidget);
    expect(find.text('回复客户'), findsOneWidget);
    expect(boot.items.byNote(note.id), isEmpty); expect(refreshed, 0);
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(boot.items.byNote(note.id).map((e) => e.title), ['回复客户', '整理文档']);
    expect(boot.notes.byId(note.id)!.rawContent, note.rawContent); expect(refreshed, 1);
    expect(find.text('整理预览'), findsNothing);
  });
  testWidgets('云端展示确切去向和原文，取消不读key、不请求、不落库', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test/v1', model: 'chosen', apiKey: 'test-secret');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('发送当前便签整理'), findsOneWidget);
    expect(find.textContaining('https://example.test/v1'), findsWidgets);
    expect(find.textContaining(note.rawContent), findsWidgets);
    expect(provider.calls, 0); expect(secrets.reads, 0);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(provider.calls, 0); expect(secrets.reads, 0);
    expect(boot.items.byNote(note.id), isEmpty); expect(refreshed, 0);
  });
  testWidgets('云端确认后单次请求，响应仅预览，选择采纳后保存', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test/v1', model: 'chosen', apiKey: 'test-secret');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pumpAndSettle();
    expect(provider.calls, 1); expect(provider.prompt, note.rawContent); expect(provider.key, 'test-secret');
    expect(secrets.reads, 1); expect(boot.items.byNote(note.id), isEmpty);
    expect(find.text('模型建议'), findsOneWidget);
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(boot.items.byNote(note.id).single.title, '模型建议');
    expect(boot.notes.byId(note.id)!.rawContent, note.rawContent); expect(refreshed, 1);
  });
  testWidgets('关闭档位明确指引设置，不请求也不读取key', (tester) async {
    await settings.save(mode: AiMode.off, baseUrl: '', model: '');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    expect(find.text('请先在AI设置中启用整理'), findsOneWidget);
    expect(provider.calls, 0); expect(secrets.reads, 0); expect(boot.items.byNote(note.id), isEmpty);
  });
  testWidgets('无新建议明确提示，不打开空预览', (tester) async {
    boot.notes.update(note.copyWith(rawContent: '一条想法'));
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    expect(find.text('没有可采纳的新事项'), findsOneWidget); expect(find.text('整理预览'), findsNothing);
    expect(refreshed, 0); expect(boot.items.byNote(note.id), isEmpty);
  });
  testWidgets('配置读取异常只显示可重试错误，不暴露原始异常', (tester) async {
    await tester.pumpWidget(app(load: () async => throw StateError('private-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    expect(find.text('整理失败，请重试'), findsOneWidget); expect(find.textContaining('private-key'), findsNothing);
    expect(tester.takeException(), isNull); expect(provider.calls, 0);
  });
  testWidgets('确认期间原文已改变，发送前拒绝且不读key', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test/v1', model: 'm', apiKey: 'test-secret');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    boot.notes.update(note.copyWith(rawContent: '新的已保存原文'));
    await tester.tap(find.text('发送并整理')); await tester.pumpAndSettle();
    expect(provider.calls, 0); expect(secrets.reads, 0);
    expect(find.text('便签已变化，请重新整理'), findsOneWidget);
    expect(boot.items.byNote(note.id), isEmpty);
  });
  testWidgets('请求期间原文改变，迟到建议不进入预览也不落库', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test/v1', model: 'm', apiKey: 'test-secret');
    provider.gate = Completer<Result<Map<String, Object?>>>();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pump();
    expect(provider.calls, 1);
    boot.notes.update(note.copyWith(rawContent: '新的已保存原文'));
    provider.gate!.complete(Ok(provider.response)); await tester.pumpAndSettle();
    expect(find.text('整理预览'), findsNothing); expect(find.text('便签已变化，请重新整理'), findsOneWidget);
    expect(boot.items.byNote(note.id), isEmpty); expect(refreshed, 0);
  });
  testWidgets('设置等待期间换库并关闭旧库，迟到完成不访问旧库或刷新', (tester) async {
    final ready = Completer<AiSettingsStore>();
    await tester.pumpWidget(app(load: () => ready.future)); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    final old = boot; boot = await Bootstrap.run(dbPath: ':memory:'); old.dispose();
    await tester.pumpWidget(app(load: () => ready.future)); await tester.pump();
    ready.complete(settings); await tester.pumpAndSettle();
    expect(provider.calls, 0); expect(secrets.reads, 0); expect(refreshed, 0);
    expect(find.text('整理预览'), findsNothing); expect(tester.takeException(), isNull);
  });
  testWidgets('恢复忙并关闭旧库时忽略迟到模型响应', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    provider.gate = Completer<Result<Map<String, Object?>>>();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pump();
    boot.dispose();
    await tester.pumpWidget(app(restoring: true)); await tester.pump();
    provider.gate!.complete(Ok(provider.response)); await tester.pumpAndSettle();
    expect(find.text('整理预览'), findsNothing); expect(refreshed, 0); expect(tester.takeException(), isNull);
  });
  testWidgets('请求中离开页面，迟到响应不弹预览或写库', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    provider.gate = Completer<Result<Map<String, Object?>>>();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    provider.gate!.complete(Ok(provider.response)); await tester.pumpAndSettle();
    expect(find.text('整理预览'), findsNothing); expect(refreshed, 0);
    expect(boot.items.byNote(note.id), isEmpty); expect(tester.takeException(), isNull);
  });
  testWidgets('读取密钥等待中开始恢复，不再发送请求', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    secrets.readGate = Completer<String?>();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pump();
    expect(secrets.reads, 1); boot.dispose();
    await tester.pumpWidget(app(restoring: true)); await tester.pump();
    secrets.readGate!.complete('test-secret'); await tester.pumpAndSettle();
    expect(provider.calls, 0); expect(refreshed, 0); expect(tester.takeException(), isNull);
  });
  testWidgets('预览后换库关闭旧连接，旧采纳回调被拒绝', (tester) async {
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    final old = boot; boot = await Bootstrap.run(dbPath: ':memory:'); old.dispose();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(find.text('数据已切换，请重新整理'), findsOneWidget);
    expect(boot.items.openAll(), isEmpty); expect(refreshed, 0); expect(tester.takeException(), isNull);
  });
  testWidgets('请求失败不假成功，可重新确认后重试，旧错误不遮住新预览', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    provider.gate = Completer<Result<Map<String, Object?>>>();
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pump();
    provider.gate!.complete(const Err('request_failed', message: 'private-key', cause: 'private-key'));
    await tester.pumpAndSettle();
    expect(find.text('整理请求失败，请检查网络和配置'), findsOneWidget);
    expect(find.textContaining('private-key'), findsNothing); expect(boot.items.byNote(note.id), isEmpty);
    provider.gate = null;
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pumpAndSettle();
    expect(find.text('整理预览'), findsOneWidget); expect(provider.calls, 2);
    expect(find.text('整理请求失败，请检查网络和配置'), findsNothing);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(boot.items.byNote(note.id), isEmpty); expect(refreshed, 0);
  });
  testWidgets('云端缺密钥显示配置指引，不请求或写入', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('发送并整理')); await tester.pumpAndSettle();
    expect(find.text('请先在AI设置中配置该服务的密钥'), findsOneWidget);
    expect(provider.calls, 0); expect(boot.items.byNote(note.id), isEmpty);
  });
  testWidgets('预览期间原文改变，最终采纳拒绝且保留新原文', (tester) async {
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    boot.notes.update(note.copyWith(rawContent: '新的原文'));
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    expect(find.text('便签已变化，请重新整理'), findsOneWidget);
    expect(boot.items.byNote(note.id), isEmpty); expect(boot.notes.byId(note.id)!.rawContent, '新的原文');
    await tester.tap(find.text('取消')); await tester.pumpAndSettle(); expect(refreshed, 0);
  });
  testWidgets('再次整理已有行无新增，原事项身份与活动不重复', (tester) async {
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
    final ids = boot.items.byNote(note.id).map((item) => item.id).toList();
    await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
    expect(find.text('没有可采纳的新事项'), findsOneWidget);
    expect(boot.items.byNote(note.id).map((item) => item.id), ids); expect(refreshed, 1);
    expect(ActivityRepository(boot.db).forObject('note', note.id)
        .where((activity) => activity.action == ActivityAction.aiOrganizeApplied), hasLength(1));
  });
  testWidgets('确认期间切换配置仍绑定已展示的目标与专属key', (tester) async {
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://first.test', model: 'first', apiKey: 'first-secret');
    await tester.pumpWidget(app()); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('整理')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await settings.save(mode: AiMode.cloud, baseUrl: 'https://second.test', model: 'second', apiKey: 'second-secret');
    await tester.tap(find.text('发送并整理')); await tester.pumpAndSettle();
    expect(provider.target!.baseUrl, 'https://first.test'); expect(provider.target!.model, 'first');
    expect(provider.key, 'first-secret'); expect(provider.calls, 1);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(boot.items.byNote(note.id), isEmpty);
  });
  for (final desktop in [false, true]) {
    testWidgets('${desktop ? '桌面便签' : '移动详情'}实际入口先预览，采纳后刷新已保存便签', (tester) async {
      await tester.pumpWidget(app(body: desktop ? StickyWindow(noteId: note.id) : NoteDetailPage(noteId: note.id)));
      await tester.pumpAndSettle();
      expect(find.byType(OrganizeButton), findsOneWidget);
      await tester.tap(find.byTooltip('整理')); await tester.pumpAndSettle();
      expect(find.text('整理预览'), findsOneWidget); expect(boot.items.byNote(note.id), isEmpty);
      await tester.tap(find.text('采纳勾选项')); await tester.pumpAndSettle();
      expect(boot.items.byNote(note.id), hasLength(2)); expect(find.text('0 / 2 完成'), findsOneWidget);
      expect(boot.notes.byId(note.id)!.rawContent, note.rawContent); expect(tester.takeException(), isNull);
    });
  }
}

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{}; int reads = 0;
  Completer<String?>? readGate;
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);
  @override
  Future<String?> read(String key) async { reads++; return readGate == null ? values[key] : readGate!.future; }
}

class _Provider implements AiProvider {
  int calls = 0; String? prompt, key;
  ProviderConfig? target;
  Map<String, Object?> response = {'items': [{'title': '模型建议', 'lineIndex': 0}]};
  Completer<Result<Map<String, Object?>>>? gate;
  @override
  String get id => 'openaiCompatible';
  @override
  Future<Result<Map<String, Object?>>> complete({required String prompt, required String schemaHint,
      required String apiKey, ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async {
    calls++; this.prompt = prompt; key = apiKey; target = config;
    return gate == null ? Ok(response) : gate!.future;
  }
  @override
  Future<Result<void>> ping({required String apiKey,
      ProviderConfig config = const ProviderConfig(id: 'openaiCompatible')}) async => const Ok(null);
}
