import 'package:cryptography/cryptography.dart';

import 'crypto_primitives.dart';

/// V1帧：随机24字节nonce、密文、16字节Poly1305认证码。
class XChaCha20Aead implements Aead {
  final _algorithm = Xchacha20.poly1305Aead();

  void _checkKey(List<int> key) {
    if (key.length != CryptoSpec.keyBytes ||
        key.any((byte) => byte < 0 || byte > 255)) {
      throw ArgumentError('加密密钥格式错误');
    }
  }

  @override
  Future<List<int>> seal(List<int> plaintext, List<int> key,
      {List<int>? aad}) async {
    _checkKey(key);
    final box = await _algorithm.encrypt(plaintext,
        secretKey: SecretKey(key), aad: aad ?? const []);
    return box.concatenation();
  }

  @override
  Future<List<int>> open(List<int> frame, List<int> key,
      {List<int>? aad}) async {
    _checkKey(key);
    if (frame.length < CryptoSpec.nonceBytes + CryptoSpec.macBytes ||
        frame.any((byte) => byte < 0 || byte > 255)) {
      throw const FormatException('加密帧格式错误');
    }
    final box = SecretBox.fromConcatenation(frame,
        nonceLength: CryptoSpec.nonceBytes, macLength: CryptoSpec.macBytes);
    try {
      return await _algorithm.decrypt(box,
          secretKey: SecretKey(key), aad: aad ?? const []);
    } on SecretBoxAuthenticationError {
      throw StateError('密文认证失败');
    }
  }
}
