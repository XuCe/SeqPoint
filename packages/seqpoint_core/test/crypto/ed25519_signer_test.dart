import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/src/crypto/ed25519_signer.dart';
import 'package:test/test.dart';

void main() {
  test('仅公钥静态验签，无需私钥实例并冻结异步输入', () async {
    final signer = await Ed25519Signer.fromSeed(List.filled(32, 7));
    final message = [1, 2, 3], original = await signer.sign([1, 2, 3]);
    final proof = [...original], publicBytes = [...signer.publicKey];
    final checking = Ed25519Signer.verifyPublic(message, proof, publicBytes);
    message[0] = 9; proof[0] ^= 1; publicBytes[0] ^= 1;
    expect(await checking, isTrue);
    expect(await Ed25519Signer.verifyPublic([9], original, signer.publicKey), isFalse);
    expect(await Ed25519Signer.verifyPublic([1], [], signer.publicKey), isFalse);
  });
  test('签名可由标准库验证，公钥不可变', () async {
    final seed = List.generate(32, (i) => i);
    final signer = await Ed25519Signer.fromSeed(seed);
    final publicKey = await (await Ed25519().newKeyPairFromSeed(seed))
        .extractPublicKey();
    expect(signer.publicKey, publicKey.bytes);
    final signature = await signer.sign([1, 2, 3]);
    expect(signature, hasLength(64));
    expect(await Ed25519().verify([1, 2, 3],
        signature: Signature(signature, publicKey: publicKey)), isTrue);
    expect(await signer.verify([1, 2, 3], signature, signer.publicKey), isTrue);
    expect(() => signer.publicKey[0] = 0, throwsUnsupportedError);
  });
  test('修改消息、签名、公钥或使用畸形长度均验证失败', () async {
    final signer = await Ed25519Signer.fromSeed(List.filled(32, 7));
    final other = await Ed25519Signer.fromSeed(List.filled(32, 8));
    final signature = await signer.sign([3]);
    expect(await signer.verify([4], signature, signer.publicKey), isFalse);
    expect(await signer.verify([3], signature, other.publicKey), isFalse);
    final bad = List<int>.of(signature)..[0] ^= 1;
    expect(await signer.verify([3], bad, signer.publicKey), isFalse);
    expect(await signer.verify([3], [], signer.publicKey), isFalse);
    expect(await signer.verify([3], signature, []), isFalse);
    expect(await signer.verify([3], List.filled(64, 256), signer.publicKey),
        isFalse);
  });
  test('种子输入复制，非法种子不进入库', () async {
    final seed = List.filled(32, 9);
    final signer = await Ed25519Signer.fromSeed(seed);
    final first = await signer.sign([]);
    seed.fillRange(0, seed.length, 0);
    expect(await signer.sign([]), first);
    await expectLater(Ed25519Signer.fromSeed([]), throwsArgumentError);
    await expectLater(Ed25519Signer.fromSeed(List.filled(32, -1)),
        throwsArgumentError);
  });
}
