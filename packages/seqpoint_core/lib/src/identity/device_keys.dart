import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../crypto/ed25519_signer.dart';

/// 私钥仅驻内存；持久化由调用方的系统安全存储负责。
class DeviceKeys {
  DeviceKeys._(this.signer, this._exchangePair, List<int> publicKey, this.deviceId)
      : exchangePublicKey = List.unmodifiable(publicKey);

  final Ed25519Signer signer;
  final SimpleKeyPair _exchangePair;
  final List<int> exchangePublicKey;
  final String deviceId;
  static final _exchange = X25519();

  static Future<DeviceKeys> fromSeeds(List<int> signing, List<int> exchange) async {
    if (exchange.length != 32 || exchange.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('协商种子格式错误');
    }
    final signer = await Ed25519Signer.fromSeed(signing);
    final pair = await _exchange.newKeyPairFromSeed(List<int>.of(exchange));
    final fingerprint = await Sha256().hash(signer.publicKey);
    return DeviceKeys._(signer, pair, (await pair.extractPublicKey()).bytes,
        base64UrlEncode(fingerprint.bytes).replaceAll('=', ''));
  }

  Future<List<int>> sharedSecret(List<int> peerPublicKey) async {
    if (peerPublicKey.length != 32 ||
        peerPublicKey.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('设备公钥格式错误');
    }
    try {
      final secret = await _exchange.sharedSecretKey(keyPair: _exchangePair,
          remotePublicKey: SimplePublicKey(peerPublicKey, type: KeyPairType.x25519));
      final bytes = await secret.extractBytes();
      if (bytes.every((b) => b == 0)) throw StateError('无效共享密钥');
      return bytes;
    } catch (_) {
      throw StateError('设备密钥协商失败');
    }
  }
}
