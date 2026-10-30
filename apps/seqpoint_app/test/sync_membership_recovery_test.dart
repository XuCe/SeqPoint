import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async { values[key] = value; }
}

Future<({DeviceKeys host, DeviceKeys guest, MembershipReducer control, VaultKey key})> _control(int epoch) async {
  final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
  final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
  final key = VaultKey(epoch: epoch, keyBytes: List.filled(32, epoch + 41));
  final root = await MembershipState.createVault(founder: a,
      vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
  final reducer = MembershipReducer(trustedAnchor: root);
  final add = await MembershipEvent.create(parent: root, issuer: a, type: MembershipEventType.add,
      subject: MemberKeys(deviceId: b.deviceId, signingPublicKey: b.signer.publicKey,
          exchangePublicKey: b.exchangePublicKey, tlsFingerprint: 'b' * 64), epochKey: key);
  await reducer.ingest(add, issuerFileDeviceId: a.deviceId);
  return (host: a, guest: b, control: reducer, key: key);
}

void main() {
  test('普通写入不能清除冲突，完成新配对后原子保存新域与旧审计', () async {
    final old = await _control(1), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: old.control, localDevice: old.guest, epochKey: old.key);
    final parent = old.control.state;
    final a = await MembershipEvent.create(parent: parent, issuer: old.host, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: parent, issuer: old.guest, type: MembershipEventType.rotate);
    await old.control.ingest(a, issuerFileDeviceId: old.host.deviceId);
    await store.save(membership: old.control, localDevice: old.guest,
        epochKey: await old.control.openCurrentEpoch(localDevice: old.guest));
    await old.control.ingest(b, issuerFileDeviceId: old.guest.deviceId);
    final blocked = await store.save(membership: old.control, localDevice: old.guest);
    expect(blocked.isUsable, isFalse);
    expect(blocked.epochKeys.keys, [1, 2]);
    final fresh = await _control(3);
    await expectLater(store.save(membership: fresh.control, localDevice: old.guest,
        epochKey: fresh.key), throwsStateError);
    final clock = FakeClock(DateTime.utc(2026, 10, 26));
    final invitation = await PairingInvitation.create(keys: fresh.host, vaultPublicId: 'vault',
        tlsFingerprint: 'a' * 64, clock: clock);
    final guest = await PairingHandshake.respond(keys: fresh.guest, clock: clock,
        invitation: await PairingInvitation.fromQr(invitation.toQrPayload(), clock: clock), tlsFingerprint: 'b' * 64);
    final host = await PairingHandshake.acceptResponse(invitation: invitation, keys: fresh.host,
        response: guest.response.toJson(), clock: clock);
    final hp = await host.confirmShortCode(host.shortCode), gp = await guest.confirmShortCode(guest.shortCode);
    await host.acceptConfirmation(gp); await guest.acceptConfirmation(hp);
    final key = await guest.openEpoch(await host.sealEpoch(fresh.key, checkpointHash: fresh.control.state.headHash));
    final saved = await store.recoverFromPairing(session: guest, checkpoint: fresh.control.state.toJson(),
        localDevice: fresh.guest, epochKey: key);
    expect(saved.isUsable, isTrue);
    expect(saved.epochKeys.keys, [1, 2, 3]);
    expect(saved.membership.isolatedControlRecords, hasLength(1));
    final reopened = (await SyncMembershipStore(secrets).load(fresh.guest))!;
    expect(reopened.state.authorityId, fresh.control.state.authorityId);
    expect(reopened.epochKeys.keys, [1, 2, 3]);
    expect(reopened.membership.isolatedControlRecords.single['conflicted'], isTrue);
    final eraseAudit = MembershipReducer(trustedAnchor: reopened.state);
    await expectLater(store.save(membership: eraseAudit, localDevice: fresh.guest, epochKey: key), throwsStateError);
    expect((await store.load(fresh.guest))!.membership.isolatedControlRecords, hasLength(1));
    await expectLater(store.save(membership: old.control, localDevice: old.guest), throwsStateError);
  });
}
