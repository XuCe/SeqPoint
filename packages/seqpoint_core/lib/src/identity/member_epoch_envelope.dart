import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import '../crypto/vault_key.dart';
import '../crypto/xchacha20_aead.dart';
import 'device_keys.dart';
import 'member_keys.dart';
import 'pairing_transcript.dart' show parsePairingBytes;

final class MemberEpochEnvelope {
  MemberEpochEnvelope._(this.recipientDeviceId, this.salt, this.frame);
  final String recipientDeviceId;
  final List<int> salt, frame;
  Map<String, Object?> toJson() => {
    'recipient_id': recipientDeviceId,
    'salt': base64UrlEncode(salt).replaceAll('=', ''),
    'frame': base64UrlEncode(frame).replaceAll('=', ''),
  };
  factory MemberEpochEnvelope.fromJson(Map<String, Object?> json) {
    if (json.length != 3 || !json.keys.toSet().containsAll({'recipient_id', 'salt', 'frame'}) ||
        json['recipient_id'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(json['recipient_id'] as String)) {
      throw const FormatException('成员Epoch封装格式错误');
    }
    return MemberEpochEnvelope._(json['recipient_id'] as String,
        List.unmodifiable(parsePairingBytes(json['salt'], 32)),
        List.unmodifiable(parsePairingBytes(json['frame'], 72)));
  }
  static Future<MemberEpochEnvelope> seal({required DeviceKeys sender,
    required MemberKeys senderIdentity, required MemberKeys recipient,
    required List<int> context, required VaultKey epochKey,
  }) async {
    if (sender.deviceId != senderIdentity.deviceId ||
        base64Encode(sender.exchangePublicKey) != base64Encode(senderIdentity.exchangePublicKey)) {
      throw StateError('封装发送身份不匹配');
    }
    final bytes = List<int>.unmodifiable(epochKey.keyBytes);
    if (epochKey.epoch < 1 || bytes.length != 32 || bytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('Epoch密钥格式错误');
    }
    final aad = _aad(List<int>.of(context), senderIdentity, recipient, epochKey.epoch);
    await senderIdentity.verifyIdentity();
    await recipient.verifyIdentity();
    final salt = _random();
    final key = await _key(await sender.sharedSecret(recipient.exchangePublicKey), salt, aad);
    return MemberEpochEnvelope._(recipient.deviceId, List.unmodifiable(salt),
        List.unmodifiable(await _aead.seal(bytes, key, aad: aad)));
  }
  Future<VaultKey> open({required DeviceKeys recipient,
    required MemberKeys senderIdentity, required MemberKeys recipientIdentity,
    required List<int> context, required int epoch,
  }) async {
    if (recipient.deviceId != recipientDeviceId || recipientIdentity.deviceId != recipientDeviceId ||
        base64Encode(recipient.exchangePublicKey) != base64Encode(recipientIdentity.exchangePublicKey)) {
      throw StateError('封装接收身份不匹配');
    }
    final aad = _aad(List<int>.of(context), senderIdentity, recipientIdentity, epoch);
    final key = await _key(await recipient.sharedSecret(senderIdentity.exchangePublicKey), salt, aad);
    final bytes = await _aead.open(frame, key, aad: aad);
    return VaultKey(epoch: epoch, keyBytes: List.unmodifiable(bytes));
  }
  static List<int> _aad(List<int> context, MemberKeys sender, MemberKeys recipient, int epoch) =>
      utf8.encode(jsonEncode(['seqpoint-member-epoch-v1',
        epoch, base64UrlEncode(context), sender.toJson(), recipient.toJson()]));
  static Future<List<int>> _key(List<int> shared, List<int> salt, List<int> aad) async =>
      (await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
        secretKey: SecretKey(shared), nonce: salt, info: aad)).extractBytes();
  static List<int> _random() => List.generate(32, (_) => Random.secure().nextInt(256));
  static XChaCha20Aead get _aead => XChaCha20Aead();
}
