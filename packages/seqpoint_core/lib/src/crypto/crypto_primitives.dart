/// 加密原语约定。集中在此，便于安全评审与未来替换实现。
///
/// 与 PRD V1.1 附录 A 一致：
/// - 设备签名：Ed25519
/// - 密钥协商：X25519 + HKDF-SHA256
/// - 对象加密：XChaCha20-Poly1305（24 字节 nonce + 密文 + 16 字节 MAC）
abstract final class CryptoSpec {
  static const nonceBytes = 24;
  static const macBytes = 16;
  static const keyBytes = 32;

  /// 用途域，隔离签名、派生与密钥承诺。
  static const infoSegment = 'seqpoint-segment-v1';
  static const infoSession = 'seqpoint-session-v1';
  static const infoEpochCommitment = 'seqpoint-epoch-commit-v1';
  static const infoMembershipState = 'seqpoint-membership-state-v1';
  static const infoAttachment = 'seqpoint-attachment-v1';
  static const infoSnapshot = 'seqpoint-snapshot-v1';
  static const infoRecovery = 'seqpoint-recovery-v1';
}

/// 认证加密接口。
abstract interface class Aead {
  Future<List<int>> seal(List<int> plaintext, List<int> key, {List<int>? aad});
  Future<List<int>> open(List<int> frame, List<int> key, {List<int>? aad});
}

/// 签名接口。
abstract interface class Signer {
  Future<List<int>> sign(List<int> message);
  Future<bool> verify(List<int> message, List<int> signature, List<int> publicKey);
}
