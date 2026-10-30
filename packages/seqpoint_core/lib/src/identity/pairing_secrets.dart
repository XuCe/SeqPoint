import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../util/clock.dart';
import 'device_keys.dart';
import 'pairing_transcript.dart';

/// 仅会话内部驻内存材料；Epoch交换还必须经过双端确认状态机。
Future<({List<int> encryptionKey, List<int> confirmationKey, String shortCode})>
    derivePairingSecrets({required DeviceKeys localKeys, required PairingTranscript transcript,
      required List<int> pairingSecret, Clock clock = const SystemClock(),
    }) async {
  if (pairingSecret.length != 32 || pairingSecret.any((b) => b < 0 || b > 255)) {
    throw ArgumentError('一次性配对秘密格式错误');
  }
  final secret = List<int>.unmodifiable(pairingSecret);
  final isInitiator = localKeys.deviceId == transcript.initiator.deviceId;
  final local = isInitiator ? transcript.initiator : transcript.responder;
  final peer = isInitiator ? transcript.responder : transcript.initiator;
  if (local.deviceId != localKeys.deviceId ||
      base64Encode(local.signingPublicKey) != base64Encode(localKeys.signer.publicKey) ||
      base64Encode(local.exchangePublicKey) != base64Encode(localKeys.exchangePublicKey)) {
    throw StateError('本机配对身份或密钥不匹配');
  }
  await transcript.verify(clock: clock);
  final shared = await localKeys.sharedSecret(peer.exchangePublicKey);
  // 独立32字节AEAD/确认密钥与24bit短码，全部绑定同一规范transcript。
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 67).deriveKey(
      secretKey: SecretKey(shared), nonce: secret, info: transcript.canonicalBytes);
  final material = await key.extractBytes();
  await transcript.verify(clock: clock);
  return (
    encryptionKey: List<int>.unmodifiable(material.sublist(0, 32)),
    confirmationKey: List<int>.unmodifiable(material.sublist(32, 64)),
    shortCode: material.skip(64).map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join('-'),
  );
}
