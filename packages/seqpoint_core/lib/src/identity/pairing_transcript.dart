import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../crypto/crypto_primitives.dart';
import '../util/clock.dart';

List<int> parsePairingBytes(Object? value, int length) {
  if (value is! String || value.length != (length * 8 + 5) ~/ 6) {
    throw const FormatException('配对字节格式错误');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (bytes.length != length || base64UrlEncode(bytes).replaceAll('=', '') != value) {
    throw const FormatException('配对字节编码不规范');
  }
  return bytes;
}

/// 尚未授予信任的公开材料；身份核对和短码确认由会话执行。
class PairingParticipant {
  PairingParticipant({required this.deviceId, required List<int> signingPublicKey,
    required List<int> exchangePublicKey, required List<int> nonce, required this.tlsFingerprint,
  }) : signingPublicKey = _bytes(signingPublicKey),
       exchangePublicKey = _bytes(exchangePublicKey), nonce = _bytes(nonce) {
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').firstMatch(deviceId)?.end != deviceId.length ||
        RegExp(r'^[a-f0-9]{64}$').firstMatch(tlsFingerprint)?.end != tlsFingerprint.length) {
      throw ArgumentError('配对公开身份或TLS指纹格式错误');
    }
  }
  final String deviceId, tlsFingerprint;
  final List<int> signingPublicKey, exchangePublicKey, nonce;

  factory PairingParticipant.fromJson(Map<String, Object?> json) {
    const fields = {'device_id', 'signing_pub', 'exchange_pub', 'nonce', 'tls_sha256'};
    try {
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k))) {
        throw const FormatException();
      }
      return PairingParticipant(deviceId: json['device_id'] as String,
          signingPublicKey: parsePairingBytes(json['signing_pub'], 32),
          exchangePublicKey: parsePairingBytes(json['exchange_pub'], 32),
          nonce: parsePairingBytes(json['nonce'], 32), tlsFingerprint: json['tls_sha256'] as String);
    } catch (_) { throw const FormatException('配对公开材料格式错误'); }
  }

  Future<void> verifyIdentity() async {
    final hash = await Sha256().hash(signingPublicKey);
    if (base64UrlEncode(hash.bytes).replaceAll('=', '') != deviceId) {
      throw StateError('配对身份与签名公钥不一致');
    }
  }

  Future<void> verifySignature(List<int> message, List<int> signature) async {
    final data = List<int>.unmodifiable(message), proof = List<int>.unmodifiable(signature);
    if (proof.length != 64 || proof.any((b) => b < 0 || b > 255)) {
      throw StateError('配对签名格式错误');
    }
    await verifyIdentity();
    try {
      if (await Ed25519().verify(data, signature: Signature(proof,
          publicKey: SimplePublicKey(signingPublicKey, type: KeyPairType.ed25519)))) {
        return;
      }
    } catch (_) { throw StateError('配对签名无效'); }
    throw StateError('配对签名无效');
  }

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'signing_pub': base64UrlEncode(signingPublicKey).replaceAll('=', ''),
    'exchange_pub': base64UrlEncode(exchangePublicKey).replaceAll('=', ''),
    'nonce': base64UrlEncode(nonce).replaceAll('=', ''),
    'tls_sha256': tlsFingerprint,
  };

  static List<int> _bytes(List<int> bytes) {
    if (bytes.length != 32 || bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('配对公钥或随机数格式错误');
    }
    return List<int>.unmodifiable(bytes);
  }
}

/// 固定发起/应答角色顺序；这些公开材料通过短码确认后才可建立信任。
class PairingTranscript {
  PairingTranscript({required this.vaultPublicId, required this.sessionId,
    required this.initiator, required this.responder, required this.expiresAt,
  }) {
    for (final id in [vaultPublicId, sessionId]) {
      if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(id)?.end != id.length) {
        throw ArgumentError('配对会话或Vault标识格式错误');
      }
    }
    if (!expiresAt.isUtc || initiator.deviceId == responder.deviceId ||
        base64Encode(initiator.nonce) == base64Encode(responder.nonce)) {
      throw ArgumentError('配对参与方、随机数或期限格式错误');
    }
  }
  final String vaultPublicId, sessionId;
  final PairingParticipant initiator, responder;
  final DateTime expiresAt;
  static const maxLifetime = Duration(minutes: 10);

  factory PairingTranscript.fromJson(Map<String, Object?> json) {
    const fields = {'purpose', 'v', 'type', 'vault_id', 'session_id',
      'expires_at', 'initiator', 'responder'};
    try {
      final date = json['expires_at'];
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k)) ||
          json['purpose'] != CryptoSpec.infoSession || json['v'] is! int ||
          json['v'] != 1 || json['type'] != 'transcript' || date is! String || date.length > 32) {
        throw const FormatException();
      }
      final expires = DateTime.parse(date);
      if (expires.toIso8601String() != date) throw const FormatException();
      return PairingTranscript(vaultPublicId: json['vault_id'] as String,
          sessionId: json['session_id'] as String, expiresAt: expires,
          initiator: PairingParticipant.fromJson((json['initiator'] as Map).cast<String, Object?>()),
          responder: PairingParticipant.fromJson((json['responder'] as Map).cast<String, Object?>()));
    } catch (_) { throw const FormatException('配对上下文格式错误'); }
  }

  /// 仅验证公开身份绑定；不代表对端已确认短码或成为可信成员。
  Future<void> verify({Clock clock = const SystemClock()}) async {
    _checkTime(clock);
    for (final participant in [initiator, responder]) {
      await participant.verifyIdentity();
    }
    _checkTime(clock);
  }

  void _checkTime(Clock clock) {
    final now = clock.now().toUtc();
    if (!expiresAt.isAfter(now) || expiresAt.difference(now) > maxLifetime) {
      throw StateError('配对会话已过期或期限无效');
    }
  }

  List<int> get canonicalBytes => List<int>.unmodifiable(utf8.encode(jsonEncode(toJson())));

  Map<String, Object?> toJson() => {
    'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'transcript',
    'vault_id': vaultPublicId, 'session_id': sessionId,
    'expires_at': expiresAt.toIso8601String(),
    'initiator': initiator.toJson(), 'responder': responder.toJson(),
  };
}
