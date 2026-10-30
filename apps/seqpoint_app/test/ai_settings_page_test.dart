import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:seqpoint_app/settings/ai_settings_store.dart';
import 'package:seqpoint_app/settings/ai_settings_page.dart';

void main() {
  late AiSettingsStore store;
  late _Secrets secrets;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    secrets = _Secrets();
    store = AiSettingsStore(await SharedPreferences.getInstance(), secrets);
    await store.save(mode: AiMode.off, baseUrl: '', model: '');
  });
  testWidgets('加载期间可见，完成后显示已保存隐私档位', (tester) async {
    final ready = Completer<AiSettingsStore>();
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () => ready.future)));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    ready.complete(store); await tester.pumpAndSettle();
    expect(tester.widget<RadioGroup<AiMode>>(find.byType(RadioGroup<AiMode>)).groupValue, AiMode.off);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
  testWidgets('配置加载失败可见且可以重试', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async {
      calls++; if (calls == 1) throw StateError('unavailable'); return store;
    })));
    await tester.pumpAndSettle();
    expect(find.text('无法读取AI设置'), findsOneWidget);
    await tester.tap(find.text('重试')); await tester.pumpAndSettle();
    expect(find.text('无法读取AI设置'), findsNothing); expect(calls, 2);
  });
  testWidgets('云端须告知去向；取消不保存，确认才保存，密钥输入遮盖且不读旧key', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端模型')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-base-url')), 'https://example.test/v1');
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'chosen');
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'test-secret');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-key'))).obscureText, isTrue);
    await tester.tap(find.text('保存配置')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('启用云端整理'), findsOneWidget);
    expect(find.textContaining('https://example.test/v1'), findsWidgets);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(store.mode, AiMode.off); expect(secrets.values, isEmpty);
    await tester.tap(find.text('保存配置')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('启用并保存')); await tester.pumpAndSettle();
    expect(store.mode, AiMode.cloud); expect(store.config.model, 'chosen');
    expect(secrets.values.values, ['test-secret']); expect(secrets.reads, 0);
    expect(find.text('配置已保存（未测试连接）'), findsOneWidget);
  });
  testWidgets('已保存密钥只显示配置状态，清除后仍不读取明文', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    expect(find.text('已保存服务的密钥：已配置'), findsOneWidget);
    expect(find.text('test-secret'), findsNothing);
    await tester.tap(find.text('清除已保存密钥')); await tester.pumpAndSettle();
    expect(secrets.values, isEmpty); expect(secrets.reads, 0);
    expect(find.text('已保存服务的密钥：未配置'), findsOneWidget);
  });
  testWidgets('保存失败显示错误且保留输入，可重试而不假称连接成功', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm');
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'new-secret');
    secrets.failWrite = true;
    await tester.tap(find.text('保存配置')); await tester.pumpAndSettle();
    expect(find.textContaining('无法保存AI配置'), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-key'))).controller!.text, 'new-secret');
    expect(find.text('配置已保存（未测试连接）'), findsNothing);
    secrets.failWrite = false;
    await tester.tap(find.text('保存配置')); await tester.pumpAndSettle();
    expect(secrets.values.values, ['new-secret']);
    expect(find.text('配置已保存（未测试连接）'), findsOneWidget);
  });
  testWidgets('保存等待期间禁用表单和重复保存，只写一次密钥', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm');
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ai-key')), 'new-secret');
    secrets.writeGate = Completer<void>();
    await tester.tap(find.text('保存配置')); await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('ai-key'))).enabled, isFalse);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存配置')).onPressed, isNull);
    await tester.tap(find.text('保存配置')); await tester.pump();
    expect(secrets.writes, 1);
    secrets.writeGate!.complete(); await tester.pumpAndSettle();
    expect(secrets.writes, 1); expect(find.text('配置已保存（未测试连接）'), findsOneWidget);
  });
  testWidgets('仅本地档位持久化且不读取或写入密钥', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅本地规则')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置')); await tester.pumpAndSettle();
    expect(store.mode, AiMode.localRulesOnly); expect(secrets.reads, 0); expect(secrets.writes, 0);
  });
  testWidgets('清除失败保留已配置状态且能重试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    secrets.failDelete = true;
    await tester.tap(find.text('清除已保存密钥')); await tester.pumpAndSettle();
    expect(find.text('无法清除密钥，请重试'), findsOneWidget);
    expect(find.text('已保存服务的密钥：已配置'), findsOneWidget); expect(secrets.values, isNotEmpty);
    secrets.failDelete = false;
    await tester.tap(find.text('清除已保存密钥')); await tester.pumpAndSettle();
    expect(secrets.values, isEmpty); expect(find.text('已清除当前服务密钥'), findsOneWidget);
  });
  testWidgets('窄屏带键盘时云端告知内容可滚动，取消按钮仍可操作', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 560));
    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(() { tester.view.resetViewInsets(); return tester.binding.setSurfaceSize(null); });
    await tester.pumpWidget(MaterialApp(home: AiSettingsPage(loadSettings: () async => store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端模型')); await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('ai-base-url')));
    await tester.enterText(find.byKey(const ValueKey('ai-base-url')), 'https://example.test/v1');
    await tester.ensureVisible(find.byKey(const ValueKey('ai-model')));
    await tester.enterText(find.byKey(const ValueKey('ai-model')), 'm');
    FocusManager.instance.primaryFocus?.unfocus(); await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('保存配置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存配置')); await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('取消').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); expect(store.mode, AiMode.off);
  });
}

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  int reads = 0;
  bool failWrite = false;
  bool failDelete = false;
  int writes = 0;
  Completer<void>? writeGate;
  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (writeGate != null) await writeGate!.future;
    if (failWrite) throw StateError(value);
    values[key] = value;
  }
  @override
  Future<String?> read(String key) async { reads++; return values[key]; }
  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('test-secret');
    values.remove(key);
  }
  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);
}
