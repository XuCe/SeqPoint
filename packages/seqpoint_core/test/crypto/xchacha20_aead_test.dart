import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/src/crypto/xchacha20_aead.dart';
import 'package:test/test.dart';

void main() {
  final aead = XChaCha20Aead();
  final key = List.generate(32, (i) => i);
  test('标准库可打开nonce24+密文+MAC16帧，含AAD', () async {
    final frame = await aead.seal([1, 2, 255], key, aad: [7, 8]);
    expect(frame.length, 43);
    final box = SecretBox.fromConcatenation(frame,
        nonceLength: 24, macLength: 16);
    expect(await Xchacha20.poly1305Aead().decrypt(box,
        secretKey: SecretKey(key), aad: [7, 8]), [1, 2, 255]);
    expect(await aead.open(frame, key, aad: [7, 8]), [1, 2, 255]);
  });
  test('独立加密使用不同nonce，空明文也可往返', () async {
    final first = await aead.seal([], key);
    final second = await aead.seal([], key);
    expect(first.length, 40);
    expect(first.take(24), isNot(orderedEquals(second.take(24))));
    expect(await aead.open(first, key), isEmpty);
  });
  test('错误密钥、AAD及任意帧区域篡改均拒绝', () async {
    final frame = await aead.seal([1, 2, 3], key, aad: [7]);
    await expectLater(aead.open(frame, List.filled(32, 9), aad: [7]),
        throwsStateError);
    await expectLater(aead.open(frame, key, aad: [8]), throwsStateError);
    for (final at in [0, 24, frame.length - 1]) {
      final bad = List<int>.of(frame)..[at] ^= 1;
      await expectLater(aead.open(bad, key, aad: [7]), throwsStateError);
    }
  });
  test('截断帧和非32字节密钥前置拒绝', () async {
    await expectLater(aead.open(List.filled(39, 0), key), throwsFormatException);
    await expectLater(aead.seal([1], [2]), throwsArgumentError);
    await expectLater(aead.open(List.filled(40, 0), [2]), throwsArgumentError);
  });
}
