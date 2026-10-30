import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('承诺匹配独立SHA256黄金值，绑定Vault和key但不随Epoch号改变', () async {
    final first = VaultKey(epoch: 1, keyBytes: List.filled(32, 7));
    final next = VaultKey(epoch: 2, keyBytes: List.filled(32, 7));
    final value = await epochKeyCommitment(vaultPublicId: 'v1', keyBytes: first.keyBytes);
    // Python hashlib: canonical JSON context + 0分隔 + 32个0x07。
    expect(value, '84WKAoF_vZnRKQ6s231P7J7kqaD59kjt00lK9lMA5JE');
    expect(await epochKeyCommitment(vaultPublicId: 'v1', keyBytes: next.keyBytes), value);
    expect(await epochKeyCommitment(vaultPublicId: 'v2', keyBytes: first.keyBytes), isNot(value));
    expect(await epochKeyCommitment(vaultPublicId: 'v1', keyBytes: List.filled(32, 8)), isNot(value));
  });
  test('异步摘要前冻结输入，不修改调用方密钥', () async {
    final key = List.filled(32, 7);
    final pending = epochKeyCommitment(vaultPublicId: 'v1', keyBytes: key);
    key[0] = 8;
    expect(await pending, '84WKAoF_vZnRKQ6s231P7J7kqaD59kjt00lK9lMA5JE');
    expect(key[0], 8);
  });
  test('拒绝坏Vault/密钥，不在异常中回显密钥', () async {
    for (final id in ['', 'a' * 129, 'v1\n']) {
      await expectLater(epochKeyCommitment(vaultPublicId: id, keyBytes: List.filled(32, 7)), throwsArgumentError);
    }
    for (final key in [List.filled(31, 7), List.filled(32, 256)]) {
      await expectLater(epochKeyCommitment(vaultPublicId: 'v1', keyBytes: key),
          throwsA(isA<ArgumentError>().having((e) => e.toString(), 'safe message', isNot(contains(key.toString())))));
    }
  });
}
