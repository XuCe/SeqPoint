import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceKeys keys;
  Future<MembershipState> create({String vault = 'v1', VaultKey? key, String? tls}) =>
      MembershipState.createVault(founder: keys, vaultPublicId: vault,
        epochKey: key ?? VaultKey(epoch: 1, keyBytes: List.filled(32, 7)), tlsFingerprint: tls ?? 'a' * 64);
  setUp(() async { keys = await DeviceKeys.fromSeeds(List.filled(32, 5), List.filled(32, 6)); });
  test('新Vault初态只含本机公开身份与承诺，随机授权域不复用', () async {
    final state = await create(), other = await create(), json = state.toJson();
    expect(state.members.keys, [keys.deviceId]); expect(state.epoch, 1);
    expect(state.keyCommitment, '84WKAoF_vZnRKQ6s231P7J7kqaD59kjt00lK9lMA5JE');
    expect(state.authorityId, matches(r'^[A-Za-z0-9_-]{43}$'));
    expect(state.authorityId, isNot(other.authorityId)); expect(state.headHash, isNot(other.headHash));
    expect(state.headHash, matches(r'^[A-Za-z0-9_-]{43}$'));
    expect(json.keys, unorderedEquals(['purpose', 'v', 'vault_id', 'authority_id', 'epoch', 'key_commitment',
      'parent_hash', 'event_hash', 'members', 'revoked', 'issuer_seq', 'key_commitments']));
    expect(json['parent_hash'], isNull); expect(json['event_hash'], isNull);
    expect(jsonEncode(json), isNot(contains(base64UrlEncode(List.filled(32, 7)).replaceAll('=', ''))));
  });
  test('冻结原始密钥、名单和返回JSON互不影响，不保留可变外部引用', () async {
    final bytes = List.filled(32, 7), pending = create(key: VaultKey(epoch: 1, keyBytes: bytes)); bytes[0] = 8;
    final state = await pending, before = (await pending).headHash;
    expect(state.keyCommitment, '84WKAoF_vZnRKQ6s231P7J7kqaD59kjt00lK9lMA5JE');
    expect(() => state.members.clear(), throwsUnsupportedError);
    expect(() => state.revokedIds.add(keys.deviceId), throwsUnsupportedError);
    expect(() => state.issuerSequences[keys.deviceId] = 1, throwsUnsupportedError);
    final json = state.toJson(); (json['members'] as List).clear();
    expect(state.members.keys, [keys.deviceId]); expect(state.headHash, before);
  });
  test('拒绝坏初态参数，不能以错误epoch/key/Vault或TLS建立信任', () async {
    await expectLater(create(vault: ''), throwsArgumentError);
    await expectLater(create(tls: 'bad'), throwsArgumentError);
    await expectLater(create(key: VaultKey(epoch: 0, keyBytes: List.filled(32, 7))), throwsArgumentError);
    await expectLater(create(key: VaultKey(epoch: 1, keyBytes: [])), throwsArgumentError);
  });
}
