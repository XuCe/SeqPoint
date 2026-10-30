import 'package:cryptography/cryptography.dart';

import 'crypto_primitives.dart';

class Ed25519Signer implements Signer {
  Ed25519Signer._(this._keyPair, List<int> publicKey)
      : publicKey = List.unmodifiable(publicKey);

  final SimpleKeyPair _keyPair;
  final List<int> publicKey;
  static final _algorithm = Ed25519();

  static Future<Ed25519Signer> fromSeed(List<int> seed) async {
    if (seed.length != 32 || seed.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('签名种子格式错误');
    }
    final pair = await _algorithm.newKeyPairFromSeed(List<int>.of(seed));
    return Ed25519Signer._(pair, (await pair.extractPublicKey()).bytes);
  }

  @override
  Future<List<int>> sign(List<int> message) async =>
      (await _algorithm.sign(message, keyPair: _keyPair)).bytes;

  @override
  Future<bool> verify(List<int> message, List<int> signature,
      List<int> publicKey) => verifyPublic(message, signature, publicKey);

  /// 验证公开签名无需本机私钥；在异步库调用前冻结全部输入。
  static Future<bool> verifyPublic(List<int> message, List<int> signature,
      List<int> publicKey) async {
    if (signature.length != 64 || publicKey.length != 32 ||
        signature.any((byte) => byte < 0 || byte > 255) ||
        publicKey.any((byte) => byte < 0 || byte > 255)) {
      return false;
    }
    return _algorithm.verify(List<int>.of(message),
        signature: Signature(List<int>.of(signature),
            publicKey: SimplePublicKey(List<int>.of(publicKey), type: KeyPairType.ed25519)));
  }
}
