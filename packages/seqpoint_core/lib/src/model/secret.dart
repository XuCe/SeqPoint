/// 私密配置的种类。
enum SecretKind { aiApiKey, providerAuth }

/// AI 服务商标识。
enum AiProviderId { claude, openaiCompatible, local }

/// 需要跨设备但绝不能被云端读到的配置（AI 密钥等）。
///
/// 明文只存在各设备的系统安全存储（Keychain / Keystore / DPAPI）；
/// 跨设备时整条内容用 Vault Key 加密后作为普通同步对象流转。
/// 这里的 [ciphertext] 就是同步用的密文形态，本机使用时另从安全存储读取。
class Secret {
  const Secret({
    required this.id,
    required this.kind,
    required this.provider,
    required this.ciphertext,
    required this.updatedAt,
    this.hlc,
  });

  final String id;
  final SecretKind kind;
  final AiProviderId provider;

  /// Vault Key 加密后的内容。永不落明文。
  final String ciphertext;

  final DateTime updatedAt;
  final String? hlc;
}

/// 安全存储中的键名约定。绝不出现在数据库、日志与导出文件中。
abstract final class SecretKeys {
  static String apiKey(AiProviderId p) => 'ai.provider.${p.name}.apiKey';
  static String baseUrl(AiProviderId p) => 'ai.provider.${p.name}.baseUrl';
  static const vaultKey = 'vault.epochKey';
  static const deviceSigningKey = 'device.signing.privateKey';
  static const deviceExchangeKey = 'device.exchange.privateKey';
  static const recoverySeed = 'vault.recoverySeed';
}
