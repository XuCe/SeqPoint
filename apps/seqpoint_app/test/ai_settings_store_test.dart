import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:seqpoint_app/settings/ai_settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('默认本地，普通配置持久化，密钥只写安全存储', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _Secrets();
    final store = AiSettingsStore(prefs, secrets);
    expect(store.mode, AiMode.localRulesOnly); expect(await store.hasKey(), isFalse);
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test/v1/', model: 'chosen', apiKey: 'test-secret');
    final reopened = AiSettingsStore(prefs, secrets);
    expect(reopened.mode, AiMode.cloud); expect(reopened.config.model, 'chosen');
    expect(reopened.config.baseUrl, 'https://example.test/v1/');
    expect(await reopened.hasKey(), isTrue);
    expect(await reopened.readApiKey(reopened.config), 'test-secret');
    expect(prefs.getKeys().map(prefs.get).join(), isNot(contains('test-secret')));
    expect(secrets.values.values, ['test-secret']);
  });
  for (final url in ['http://example.test', 'https://user:pass@example.test',
    'https://example.test?token=secret', 'https://example.test#fragment', '']) {
    test('无效云端地址不保存普通配置或密钥：$url', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance(); final secrets = _Secrets();
      final store = AiSettingsStore(prefs, secrets);
      await expectLater(store.save(mode: AiMode.cloud, baseUrl: url, model: 'm', apiKey: 'test-secret'),
          throwsFormatException);
      expect(prefs.getKeys(), isEmpty); expect(secrets.values, isEmpty);
    });
  }
  test('缺模型或多行密钥不保存，安全存储失败不切换配置且错误不含key', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance(); final secrets = _Secrets();
    final store = AiSettingsStore(prefs, secrets);
    await expectLater(store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: ''), throwsFormatException);
    await expectLater(store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm',
        apiKey: 'test-secret\n'), throwsFormatException);
    secrets.failWrite = true;
    await expectLater(store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm',
        apiKey: 'test-secret'), throwsA(isA<StateError>().having((e) => e.toString(), 'message',
        isNot(contains('test-secret')))));
    expect(store.mode, AiMode.localRulesOnly); expect(prefs.getKeys(), isEmpty);
  });
  test('普通配置写失败且缓存已变化，旧目标仍只能读取原来的key', () async {
    final prefs = _Preferences(); final secrets = _Secrets(); final store = AiSettingsStore(prefs, secrets);
    await store.save(mode: AiMode.cloud, baseUrl: 'https://old.test/v1', model: 'old', apiKey: 'old-secret');
    final original = store.config;
    prefs.failWrite = true;
    await expectLater(store.save(mode: AiMode.cloud, baseUrl: 'https://new.test/v1', model: 'new',
        apiKey: 'new-secret'), throwsStateError);
    expect(await store.readApiKey(original), 'old-secret');
  });
  for (final raw in ['not json', '[]', '{"mode":"unknown"}',
      '{"mode":"cloud","baseUrl":42,"model":"m"}']) {
    test('损坏配置安全回到本地且不抛类型错误：$raw', () async {
      SharedPreferences.setMockInitialValues({'seqpoint.ai.config': raw});
      final prefs = await SharedPreferences.getInstance(); final store = AiSettingsStore(prefs, _Secrets());
      expect(store.mode, AiMode.localRulesOnly);
      expect(store.config.model, isNull); expect(await store.hasKey(), isFalse);
    });
  }
  test('密钥按地址隔离，清除当前密钥不碰其他地址，读取绑定确认时目标', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AiSettingsStore(await SharedPreferences.getInstance(), _Secrets());
    await store.save(mode: AiMode.cloud, baseUrl: 'https://first.test/v1', model: 'm', apiKey: 'first-secret');
    final first = store.config;
    await store.save(mode: AiMode.cloud, baseUrl: 'https://second.test/v1', model: 'm', apiKey: 'second-secret');
    final second = store.config;
    expect(await store.readApiKey(first), 'first-secret');
    expect(await store.readApiKey(second), 'second-secret');
    await store.clearApiKey(second);
    expect(await store.hasKey(), isFalse); expect(await store.readApiKey(first), 'first-secret');
    expect(await store.readApiKey(const ProviderConfig(id: 'openaiCompatible',
        baseUrl: 'https://first.test/v1/', model: 'different-model')), 'first-secret');
  });
  test('安全存储读/清除异常不能把密钥带进界面错误', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = _Secrets(); final store = AiSettingsStore(await SharedPreferences.getInstance(), secrets);
    await store.save(mode: AiMode.cloud, baseUrl: 'https://example.test', model: 'm', apiKey: 'test-secret');
    final safeError = throwsA(isA<StateError>().having((e) => e.toString(), 'message', isNot(contains('test-secret'))));
    secrets.failRead = true;
    await expectLater(store.hasKey(), safeError); await expectLater(store.readApiKey(store.config), safeError);
    secrets.failDelete = true;
    await expectLater(store.clearApiKey(store.config), safeError);
  });
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  bool failWrite = false;
  bool failRead = false, failDelete = false;
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('test-secret');
    values[key] = value;
  }
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('test-secret');
    return values[key];
  }
  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('test-secret');
    values.remove(key);
  }
  @override
  Future<bool> containsKey(String key) async {
    if (failRead) throw StateError('test-secret');
    return values.containsKey(key);
  }
}

class _Preferences extends Fake implements SharedPreferences {
  final data = <String, String>{};
  bool failWrite = false;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    // 模拟legacy缓存先变化、平台持久化随后失败。
    data[key] = value;
    if (failWrite) return false;
    return true;
  }
}
