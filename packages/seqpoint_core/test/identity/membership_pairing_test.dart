import 'package:seqpoint_core/seqpoint_core.dart' hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';
import 'pairing_handshake_test.dart' show pairedFixture;
import 'pairing_epoch_test.dart' show confirmPair;

Future<({PairingHandshake host, PairingHandshake guest, MembershipReducer reducer, VaultKey key})>
    confirmedMembership({int epoch = 1, int keyByte = 42, bool addGuest = true}) async {
  final f = await pairedFixture();
  final key = VaultKey(epoch: epoch, keyBytes: List.filled(32, keyByte));
  final initial = await MembershipState.createVault(founder: f.hostKeys,
      vaultPublicId: 'v1', epochKey: key, tlsFingerprint: 'a' * 64);
  final reducer = MembershipReducer(trustedAnchor: initial);
  if (addGuest) {
    final add = await MembershipEvent.create(parent: initial, issuer: f.hostKeys,
        type: MembershipEventType.add, subject: memberIdentity(f.guestKeys, 'b'), epochKey: key);
    await reducer.ingest(add, issuerFileDeviceId: f.hostKeys.deviceId);
  }
  await confirmPair(f.host, f.guest);
  await f.guest.openEpoch(await f.host.sealEpoch(key, checkpointHash: reducer.state.headHash));
  return (host: f.host, guest: f.guest, reducer: reducer, key: key);
}

void main() {
  test('即使配对密文绑定hash，检查点仍必须包含双方身份', () async {
    final f = await confirmedMembership(addGuest: false);
    await expectLater(MembershipState.fromConfirmedPairing(session: f.guest,
        checkpoint: f.reducer.state.toJson()), throwsStateError);
    final valid = await confirmedMembership();
    final changed = valid.reducer.state.toJson(); changed['epoch'] = 2;
    await expectLater(MembershipState.fromConfirmedPairing(session: valid.guest,
        checkpoint: changed), throwsStateError);
  });
  test('冲突仅由新配对新域更高Epoch恢复，旧事实隔离并可重开', () async {
    final old = await membershipFixture(), parent = old.reducer.state;
    final a = await MembershipEvent.create(parent: parent, issuer: old.founder, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: parent, issuer: old.guest, type: MembershipEventType.rotate);
    await old.reducer.ingest(a, issuerFileDeviceId: old.founder.deviceId);
    await old.reducer.ingest(b, issuerFileDeviceId: old.guest.deviceId);
    final f = await confirmedMembership(epoch: 3);
    final recovered = await MembershipReducer.recoverFromConfirmedPairing(previous: old.reducer,
        session: f.guest, checkpoint: f.reducer.state.toJson());
    expect(recovered.isConflicted, isFalse);
    expect(recovered.isolatedControlRecords.length, 1);
    expect(recovered.state.authorityId, isNot(old.reducer.state.authorityId));
    await expectLater(recovered.ingest(a, issuerFileDeviceId: old.founder.deviceId), throwsStateError);
    final restored = await MembershipReducer.restoreTrustedLocal(recovered.toTrustedLocalJson());
    expect(restored.state.epoch, 3);
    expect(restored.isolatedControlRecords.single['conflicted'], isTrue);
    expect((restored.isolatedControlRecords.single['facts'] as List).length, 3);
    final low = await confirmedMembership(epoch: 2);
    await expectLater(MembershipReducer.recoverFromConfirmedPairing(previous: old.reducer,
        session: low.guest, checkpoint: low.reducer.state.toJson()), throwsStateError);
    final reused = await confirmedMembership(epoch: 3, keyByte: 7);
    await expectLater(MembershipReducer.recoverFromConfirmedPairing(previous: old.reducer,
        session: reused.guest, checkpoint: reused.reducer.state.toJson()), throwsStateError);
  });
  test('完成的接收端配对可引导精确检查点，host和未完成会话不可引导', () async {
    final f = await confirmedMembership();
    final restored = await MembershipState.fromConfirmedPairing(session: f.guest,
        checkpoint: f.reducer.state.toJson());
    expect(restored.headHash, f.reducer.state.headHash);
    await expectLater(MembershipState.fromConfirmedPairing(session: f.host,
        checkpoint: f.reducer.state.toJson()), throwsStateError);
    final pending = await pairedFixture();
    await expectLater(MembershipState.fromConfirmedPairing(session: pending.guest,
        checkpoint: f.reducer.state.toJson()), throwsStateError);
  });
}
