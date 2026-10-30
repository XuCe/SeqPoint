/// 系统安全存储。
///
/// 铁律：AI 密钥、Vault Key、设备私钥、Recovery Seed 只存这里。
/// 绝不进 SQLite、配置文件、日志、崩溃报告或导出文件。
///
/// 各平台实现：iOS/macOS Keychain、Android Keystore、Windows DPAPI。
abstract interface class SecretStore {
  Future<void> write(String key, String value);

  Future<String?> read(String key);

  Future<void> delete(String key);

  Future<bool> containsKey(String key);

  /// 界面展示用的脱敏形式，如 `sk-…ab12`。
  static String mask(String? value) {
    if (value == null || value.length < 8) return '(未配置)';
    return '${value.substring(0, 3)}…${value.substring(value.length - 4)}';
  }
}
