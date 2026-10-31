import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

/// 系统安全存储的真实实现。
///
/// AI 密钥、Vault Key、设备私钥、Recovery Seed 只走这里——
/// 绝不进 SQLite、配置文件、日志、崩溃报告或导出文件。
class SecureSecretStore implements SecretStore {
  const SecureSecretStore();

  // Android 侧的加密由插件内部处理（旧的 encryptedSharedPreferences 参数
  // 已废弃且会被忽略）；iOS/macOS 用 first_unlock，保证设备解锁后
  // 后台调度的提醒也能读到密钥。
  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock,
      usesDataProtectionKeychain: false,
    ),
  );

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
}
