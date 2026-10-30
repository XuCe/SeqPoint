import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../platform/secure_secret_store.dart';

class AiSettingsStore {
  AiSettingsStore(this._preferences, this._secrets);
  static Future<AiSettingsStore> open() async {
    final preferences = await SharedPreferences.getInstance();
    // sticky使用独立引擎，读取设置前刷新各自的preferences缓存。
    await preferences.reload();
    return AiSettingsStore(preferences, const SecureSecretStore());
  }
  final SharedPreferences _preferences;
  final SecretStore _secrets;
  static const _configKey = 'seqpoint.ai.config';
  Map<String, dynamic> get _data {
    try {
      final value = _preferences.getString(_configKey);
      final data = value == null ? <String, dynamic>{} : jsonDecode(value) as Map<String, dynamic>;
      if ((data['baseUrl'] != null && data['baseUrl'] is! String) ||
          (data['model'] != null && data['model'] is! String)) {
        return {};
      }
      return data;
    } catch (_) { return {}; }
  }
  AiMode get mode => AiMode.values.firstWhere((mode) => mode.name == _data['mode'],
      orElse: () => AiMode.localRulesOnly);
  ProviderConfig get config => ProviderConfig(id: 'openaiCompatible',
      baseUrl: _data['baseUrl'] as String?, model: _data['model'] as String?);

  String _keyFor(ProviderConfig target) {
    // 地址隔离：配置写失败或确认期间切换服务，不会串用其他服务的密钥。
    final uri = Uri.parse(target.baseUrl ?? '');
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return 'seqpoint.ai.key.${base64Url.encode(utf8.encode(uri.replace(path: path).toString()))}';
  }
  Future<bool> hasKey() async {
    if (config.baseUrl?.isNotEmpty != true) return false;
    try { return await _secrets.containsKey(_keyFor(config)); }
    catch (_) { throw StateError('无法读取系统安全存储状态'); }
  }
  Future<String?> readApiKey(ProviderConfig target) async {
    try { return await _secrets.read(_keyFor(target)); }
    catch (_) { throw StateError('无法读取系统安全存储密钥'); }
  }
  Future<void> clearApiKey(ProviderConfig target) async {
    try { await _secrets.delete(_keyFor(target)); }
    catch (_) { throw StateError('无法清除系统安全存储密钥'); }
  }

  Future<void> save({required AiMode mode, required String baseUrl, required String model,
    String? apiKey}) async {
    final target = ProviderConfig(id: 'openaiCompatible', baseUrl: baseUrl.trim(), model: model.trim());
    final uri = Uri.tryParse(target.baseUrl!);
    if ((mode == AiMode.cloud || target.baseUrl!.isNotEmpty || apiKey?.isNotEmpty == true) &&
        (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
            uri.hasQuery || uri.hasFragment)) {
      throw const FormatException('请填写不含凭据、查询或片段的HTTPS服务地址');
    }
    if ((mode == AiMode.cloud && target.model!.isEmpty) ||
        (apiKey != null && (apiKey.contains(RegExp(r'[\r\n]')) || (apiKey.isNotEmpty && apiKey.trim().isEmpty)))) {
      throw const FormatException('请填写模型名及有效单行密钥');
    }
    if (apiKey != null && apiKey.isNotEmpty) {
      try { await _secrets.write(_keyFor(target), apiKey); }
      catch (_) { throw StateError('无法保存系统安全存储密钥'); }
    }
    if (!await _preferences.setString(_configKey, jsonEncode({
      'mode': mode.name, 'baseUrl': target.baseUrl, 'model': target.model}))) {
      throw StateError('无法保存AI配置');
    }
  }
}
