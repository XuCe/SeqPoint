import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  String? value;
  bool failWrite = false, dropWrite = false;
  @override
  Future<String?> read(String key) async => value;
  @override
  Future<void> write(String key, String record) async {
    if (failWrite) throw StateError('fake failure');
    if (!dropWrite) value = record;
  }
}

Future<({DeviceKeys device, MembershipReducer control, VaultKey key})> _fixture() async {
  final device = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
  final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 41));
  final anchor = await MembershipState.createVault(founder: device,
      vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
  return (device: device, control: MembershipReducer(trustedAnchor: anchor), key: key);
}

void main() {
  test('rotation retains verified older keys in the same durable record after reopen', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.control, localDevice: f.device, epochKey: f.key);
    final next = VaultKey(epoch: 2, keyBytes: List.filled(32, 42));
    final rotate = await MembershipEvent.create(parent: f.control.state, issuer: f.device,
        type: MembershipEventType.rotate, epochKey: next);
    await f.control.ingest(rotate, issuerFileDeviceId: f.device.deviceId);
    await store.save(membership: f.control, localDevice: f.device, epochKey: next);
    final reopened = (await SyncMembershipStore(secrets).load(f.device))!;
    expect(reopened.epochKeys, {1: f.key.keyBytes, 2: next.keyBytes});
    expect(reopened.epochKey!.epoch, 2);
    expect(() => reopened.epochKeys.clear(), throwsUnsupportedError);
    expect(() => reopened.epochKeys[1]!.clear(), throwsUnsupportedError);
  });

  test('v1 current key migrates to v2 without inventing missing history', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.control, localDevice: f.device, epochKey: f.key);
    final legacy = jsonDecode(secrets.value!) as Map;
    legacy['v'] = 1; legacy.remove('epoch_keys'); secrets.value = jsonEncode(legacy);
    expect((await store.load(f.device))!.epochKeys.keys, [1]);
    final key = VaultKey(epoch: 2, keyBytes: List.filled(32, 42));
    final event = await MembershipEvent.create(parent: f.control.state, issuer: f.device,
        type: MembershipEventType.rotate, epochKey: key);
    await f.control.ingest(event, issuerFileDeviceId: f.device.deviceId);
    await store.save(membership: f.control, localDevice: f.device, epochKey: key);
    expect(jsonDecode(secrets.value!)['v'], 2);
    expect((await store.load(f.device))!.epochKeys.keys, [1, 2]);
    final fresh = SyncMembershipStore(_Secrets());
    final paired = await fresh.save(membership: MembershipReducer(trustedAnchor: f.control.state),
        localDevice: f.device, epochKey: key);
    expect(paired.epochKeys.keys, [2]);
  });

  test('v2 rejects wrong commitments, invented epochs and noncanonical schema', () async {
    final f = await _fixture(), secrets = _Secrets(), store = SyncMembershipStore(_Secrets());
    final own = SyncMembershipStore(secrets);
    await own.save(membership: f.control, localDevice: f.device, epochKey: f.key);
    final before = secrets.value!;
    final wrong = base64UrlEncode(List.filled(32, 77)).replaceAll('=', '');
    for (final change in <void Function(Map)>[
      (record) => record['epoch_keys'] = {'1': wrong},
      (record) => (record['epoch_keys'] as Map)['2'] = wrong,
      (record) => record['epoch_keys'] = {'01': record['key']},
      (record) => record.remove('epoch_keys'),
      (record) => record['extra'] = true,
      (record) => record['v'] = 3,
    ]) {
      final record = jsonDecode(before) as Map; change(record); secrets.value = jsonEncode(record);
      await expectLater(own.load(f.device), throwsStateError);
    }
    expect(await store.load(f.device), isNull);
  });

  test('rotation save failure and failed readback leave the prior key history usable', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.control, localDevice: f.device, epochKey: f.key);
    final before = secrets.value!;
    final key = VaultKey(epoch: 2, keyBytes: List.filled(32, 42));
    final event = await MembershipEvent.create(parent: f.control.state, issuer: f.device,
        type: MembershipEventType.rotate, epochKey: key);
    await f.control.ingest(event, issuerFileDeviceId: f.device.deviceId);
    secrets.failWrite = true;
    await expectLater(store.save(membership: f.control, localDevice: f.device, epochKey: key), throwsStateError);
    secrets.failWrite = false; secrets.dropWrite = true;
    await expectLater(store.save(membership: f.control, localDevice: f.device, epochKey: key), throwsStateError);
    expect(secrets.value, before);
    expect((await store.load(f.device))!.epochKeys.keys, [1]);
    secrets.dropWrite = false;
    await store.save(membership: f.control, localDevice: f.device, epochKey: key);
    expect((await store.load(f.device))!.epochKeys.keys, [1, 2]);
  });

  test('a correct current key does not authenticate a wrong historical epoch key', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.control, localDevice: f.device, epochKey: f.key);
    final key = VaultKey(epoch: 2, keyBytes: List.filled(32, 42));
    final event = await MembershipEvent.create(parent: f.control.state, issuer: f.device,
        type: MembershipEventType.rotate, epochKey: key);
    await f.control.ingest(event, issuerFileDeviceId: f.device.deviceId);
    await store.save(membership: f.control, localDevice: f.device, epochKey: key);
    final record = jsonDecode(secrets.value!) as Map;
    (record['epoch_keys'] as Map)['1'] = base64UrlEncode(List.filled(32, 99)).replaceAll('=', '');
    secrets.value = jsonEncode(record);
    await expectLater(store.load(f.device), throwsStateError);
  });
}
