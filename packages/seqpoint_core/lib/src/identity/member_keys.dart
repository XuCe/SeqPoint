import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/ed25519_signer.dart';
import 'pairing_transcript.dart' show parsePairingBytes;

/// 公开身份材料，不授予成员权限；授权必须由已验证父状态决定。
final class MemberKeys {
  MemberKeys({required this.deviceId, required List<int> signingPublicKey,
    required List<int> exchangePublicKey, required this.tlsFingerprint,
  }) : signingPublicKey = _bytes(signingPublicKey), exchangePublicKey = _bytes(exchangePublicKey) {
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').firstMatch(deviceId)?.end != deviceId.length ||
        RegExp(r'^[a-f0-9]{64}$').firstMatch(tlsFingerprint)?.end != tlsFingerprint.length) {
      throw ArgumentError('成员身份或TLS指纹格式错误');
    }
  }
  final String deviceId, tlsFingerprint;
  final List<int> signingPublicKey, exchangePublicKey;
  Future<void> verifyIdentity() async {
    final hash = await Sha256().hash(signingPublicKey);
    if (base64UrlEncode(hash.bytes).replaceAll('=', '') != deviceId) {
      throw StateError('成员身份与签名公钥不一致');
    }
  }
  Future<void> verifySignature(List<int> message, List<int> signature) async {
    final data = List<int>.unmodifiable(message), proof = List<int>.unmodifiable(signature);
    await verifyIdentity();
    try {
      if (await Ed25519Signer.verifyPublic(data, proof, signingPublicKey)) return;
    } catch (_) { throw StateError('成员签名无效'); }
    throw StateError('成员签名无效');
  }
  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'signing_pub': base64UrlEncode(signingPublicKey).replaceAll('=', ''),
    'exchange_pub': base64UrlEncode(exchangePublicKey).replaceAll('=', ''),
    'tls_sha256': tlsFingerprint,
  };
  factory MemberKeys.fromJson(Map<String, Object?> json) {
    const fields = {'device_id', 'signing_pub', 'exchange_pub', 'tls_sha256'};
    try {
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k))) {
        throw const FormatException();
      }
      return MemberKeys(deviceId: json['device_id'] as String,
          signingPublicKey: parsePairingBytes(json['signing_pub'], 32),
          exchangePublicKey: parsePairingBytes(json['exchange_pub'], 32),
          tlsFingerprint: json['tls_sha256'] as String);
    } catch (_) { throw const FormatException('成员公开材料格式错误'); }
  }
  static List<int> _bytes(List<int> bytes) {
    if (bytes.length != 32 || bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('成员公钥格式错误');
    }
    return List<int>.unmodifiable(bytes);
  }
}

/// 承诺不含Epoch号，使同Vault的重复密钥不会伪装成一次轮换。
Future<String> epochKeyCommitment({required String vaultPublicId, required List<int> keyBytes}) async {
  if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(vaultPublicId)?.end != vaultPublicId.length ||
      keyBytes.length != 32 || keyBytes.any((b) => b < 0 || b > 255)) {
    throw ArgumentError('密钥承诺参数格式错误');
  }
  final frozen = List<int>.unmodifiable(keyBytes);
  final context = utf8.encode(jsonEncode({
    'purpose': CryptoSpec.infoEpochCommitment, 'vault_id': vaultPublicId, 'v': 1,
  }));
  final digest = await Sha256().hash([...context, 0, ...frozen]);
  return base64UrlEncode(digest.bytes).replaceAll('=', '');
}
