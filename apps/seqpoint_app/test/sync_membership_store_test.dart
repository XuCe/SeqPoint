import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  bool failWrite = false, dropWrite = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('PRIVATE_TEST_VALUE');
    if (!dropWrite) values[key] = value;
  }
}

void main() {
  test('超过可重开容量的控制记录拒绝写入并保留上一条可用记录', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    final anchor = await MembershipState.createVault(founder: keys,
        vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
    final control = MembershipReducer(trustedAnchor: anchor), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: control, localDevice: keys, epochKey: key);
    final before = secrets.values.values.single;
    final template = await MembershipEvent.create(parent: anchor, issuer: keys, type: MembershipEventType.rotate);
    for (var n = 1; n <= 1400; n++) {
      final id = List<int>.filled(32, 200)..[30] = n >> 8..[31] = n & 255;
      final event = MembershipEvent.fromJson({...template.toJson(),
        'event_id': base64UrlEncode(id).replaceAll('=', ''), 'issuer_seq': n + 100,
        'parent_hash': base64UrlEncode(List.filled(32, 199)).replaceAll('=', '')});
      await control.ingest(event, issuerFileDeviceId: keys.deviceId);
    }
    expect(jsonEncode(control.toTrustedLocalJson()).length, greaterThan(SyncMembershipStore.maxRecordChars));
    await expectLater(store.save(membership: control, localDevice: keys, epochKey: key), throwsStateError);
    expect(secrets.values.values.single, before);
    expect((await store.load(keys))!.isUsable, isTrue);
  });
  test('公开撤销无新密钥仍保存，重开保留旧父事实并拒绝旧记录回写', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
    final guest = await DeviceKeys.fromSeeds(List.filled(32, 9), List.filled(32, 10));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    final anchor = await MembershipState.createVault(founder: keys,
        vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
    final membership = MembershipReducer(trustedAnchor: anchor);
    final add = await MembershipEvent.create(parent: anchor, issuer: keys,
        type: MembershipEventType.add, epochKey: key,
        subject: MemberKeys(deviceId: guest.deviceId, signingPublicKey: guest.signer.publicKey,
            exchangePublicKey: guest.exchangePublicKey, tlsFingerprint: 'b' * 64));
    await membership.ingest(add, issuerFileDeviceId: keys.deviceId);
    final secrets = _Secrets(), store = SyncMembershipStore(_Secrets());
    final guestStore = SyncMembershipStore(secrets);
    await guestStore.save(membership: membership, localDevice: guest, epochKey: key);
    final old = await MembershipReducer.restoreTrustedLocal(membership.toTrustedLocalJson());
    final revoke = await MembershipEvent.create(parent: membership.state,
        issuer: keys, type: MembershipEventType.revoke, targetDeviceId: guest.deviceId);
    await membership.ingest(revoke, issuerFileDeviceId: keys.deviceId);
    final saved = await guestStore.save(membership: membership, localDevice: guest, epochKey: key);
    expect(saved.isUsable, isFalse);
    final reopened = (await SyncMembershipStore(secrets).load(guest))!;
    expect(reopened.state.revokedIds, contains(guest.deviceId));
    expect(reopened.epochKey, isNull);
    expect(reopened.epochKeys, {1: key.keyBytes});
    await expectLater(guestStore.save(membership: old, localDevice: guest, epochKey: key), throwsStateError);
    expect((await store.save(membership: old, localDevice: keys, epochKey: key)).isUsable, isTrue);
  });
  test('安全写失败或回读不一致不返回可用记录，错误脱敏且可以重试', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    final state = await MembershipState.createVault(founder: keys,
        vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
    final membership = MembershipReducer(trustedAnchor: state);
    final secrets = _Secrets()..failWrite = true;
    final store = SyncMembershipStore(secrets);
    final safe = throwsA(predicate((e) => e is StateError && !e.toString().contains('PRIVATE_TEST_VALUE')));
    await expectLater(store.save(membership: membership, localDevice: keys, epochKey: key), safe);
    secrets.failWrite = false; secrets.dropWrite = true;
    await expectLater(store.save(membership: membership, localDevice: keys, epochKey: key), safe);
    expect(secrets.values, isEmpty);
    secrets.dropWrite = false;
    expect((await store.save(membership: membership, localDevice: keys, epochKey: key)).isUsable, isTrue);
  });
  test('名单先持久化但无密钥保持停传，错误承诺不能覆盖正确记录', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    final state = await MembershipState.createVault(founder: keys,
        vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
    final membership = MembershipReducer(trustedAnchor: state), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    expect((await store.save(membership: membership, localDevice: keys)).isUsable, isFalse);
    expect((await store.load(keys))!.epochKey, isNull);
    final before = secrets.values.values.single;
    await expectLater(store.save(membership: membership, localDevice: keys,
        epochKey: VaultKey(epoch: 1, keyBytes: List.filled(32, 43))), throwsStateError);
    expect(secrets.values.values.single, before);
    await store.save(membership: membership, localDevice: keys, epochKey: key);
    secrets.values[SyncMembershipStore.storageKey] = '{}';
    await expectLater(store.load(keys), throwsStateError);
    expect(secrets.values.values.single, '{}');
  });
  test('单条安全记录原子保存名单和Epoch，重开验证身份与承诺', () async {
    final secrets = _Secrets(), keys = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 42));
    final state = await MembershipState.createVault(founder: keys,
        vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
    final store = SyncMembershipStore(secrets);
    expect(await store.load(keys), isNull);
    final saved = await store.save(membership: MembershipReducer(trustedAnchor: state), localDevice: keys, epochKey: key);
    expect(saved.state.headHash, state.headHash);
    expect(secrets.values, hasLength(1));
    final reopened = (await SyncMembershipStore(secrets).load(keys))!;
    expect(reopened.state.headHash, state.headHash);
    expect(reopened.isUsable, isTrue);
    expect(reopened.epochKey!.keyBytes, key.keyBytes);
    expect(() => reopened.epochKey!.keyBytes.clear(), throwsUnsupportedError);
    final rotate = await MembershipEvent.create(parent: reopened.state, issuer: keys, type: MembershipEventType.rotate);
    await reopened.membership.ingest(rotate, issuerFileDeviceId: keys.deviceId);
    expect(reopened.isUsable, isFalse);
    final stranger = await DeviceKeys.fromSeeds(List.filled(32, 9), List.filled(32, 10));
    await expectLater(store.load(stranger), throwsStateError);
  });
}
