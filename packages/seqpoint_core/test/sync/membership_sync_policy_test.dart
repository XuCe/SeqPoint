import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:seqpoint_core/src/sync/membership_sync_policy.dart';
import 'package:test/test.dart';

import '../identity/membership_fixture.dart';

void main() {
  test('revoked old history still waits after recovery from a later trusted anchor', () async {
    final f = await membershipFixture();
    final revoke = await MembershipEvent.create(
      parent: f.reducer.state,
      issuer: f.founder,
      type: MembershipEventType.revoke,
      targetDeviceId: f.guest.deviceId,
    );
    await f.reducer.ingest(revoke, issuerFileDeviceId: f.founder.deviceId);
    final recovered = MembershipReducer(trustedAnchor: f.reducer.state);
    expect(recovered.knownMemberKeys(f.guest.deviceId), isNull);
    final policy = MembershipSyncPolicy(
      membership: recovered,
      localDeviceId: f.founder.deviceId,
      hasEpochKey: (_) => true,
    );
    expect(
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1).decision,
      MembershipSyncDecision.waiting,
    );
    expect(
      policy.checkSession(f.guest.deviceId).decision,
      MembershipSyncDecision.rejected,
    );
    expect(
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 2).decision,
      MembershipSyncDecision.rejected,
    );
  });

  test('a valid membership fork freezes all business and sessions without dropping evidence', () async {
    final f = await membershipFixture();
    final policy = MembershipSyncPolicy(
      membership: f.reducer,
      localDeviceId: f.founder.deviceId,
      hasEpochKey: (_) => true,
    );
    final parent = f.reducer.state;
    final a = await MembershipEvent.create(
      parent: parent,
      issuer: f.founder,
      type: MembershipEventType.rotate,
    );
    final b = await MembershipEvent.create(
      parent: parent,
      issuer: f.guest,
      type: MembershipEventType.rotate,
    );
    await f.reducer.ingest(a, issuerFileDeviceId: f.founder.deviceId);
    await f.reducer.ingest(b, issuerFileDeviceId: f.guest.deviceId);
    expect(f.reducer.isConflicted, isTrue);
    for (final check in [
      policy.checkSession(f.guest.deviceId),
      policy.checkLocalPublication(keyEpoch: 2),
      policy.checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 2),
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1),
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 2),
    ]) {
      expect(check.decision, MembershipSyncDecision.rejected);
      expect(check.reason, 'conflict');
    }
    expect(f.reducer.evidence, hasLength(3));
  });

  test('rotation holds old history and never publishes new operations at old epoch', () async {
    final f = await membershipFixture();
    final policy = MembershipSyncPolicy(
      membership: f.reducer,
      localDeviceId: f.founder.deviceId,
      hasEpochKey: (_) => true,
    );
    final rotate = await MembershipEvent.create(
      parent: f.reducer.state,
      issuer: f.guest,
      type: MembershipEventType.rotate,
    );
    await f.reducer.ingest(rotate, issuerFileDeviceId: f.guest.deviceId);
    final old = policy.checkInbound(
      peerDeviceId: f.guest.deviceId,
      keyEpoch: 1,
    );
    expect(old.decision, MembershipSyncDecision.waiting);
    expect(old.reason, 'history-cutoff-unproven');
    expect(old.isAllowed, isFalse);
    expect(
      policy
          .checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
          .decision,
      MembershipSyncDecision.rejected,
    );
    expect(policy.checkLocalPublication(keyEpoch: 1).isAllowed, isFalse);
    expect(
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 3).decision,
      MembershipSyncDecision.waiting,
    );
    expect(policy.checkLocalPublication(keyEpoch: 3).isAllowed, isFalse);
    expect(
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 0).decision,
      MembershipSyncDecision.rejected,
    );
    expect(
      policy.checkInbound(peerDeviceId: 'unknown', keyEpoch: 1).decision,
      MembershipSyncDecision.rejected,
    );
    expect(
      policy
          .checkInbound(peerDeviceId: f.founder.deviceId, keyEpoch: 2)
          .isAllowed,
      isFalse,
    );
  });

  test('revoked local identity cannot receive or publish even with cached epoch keys', () async {
    final f = await membershipFixture();
    final policy = MembershipSyncPolicy(
      membership: f.reducer,
      localDeviceId: f.founder.deviceId,
      hasEpochKey: (_) => true,
    );
    final revoke = await MembershipEvent.create(
      parent: f.reducer.state,
      issuer: f.guest,
      type: MembershipEventType.revoke,
      targetDeviceId: f.founder.deviceId,
    );
    await f.reducer.ingest(revoke, issuerFileDeviceId: f.guest.deviceId);
    expect(policy.checkSession(f.guest.deviceId).isAllowed, isFalse);
    expect(
      policy
          .checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
          .isAllowed,
      isFalse,
    );
    expect(
      policy
          .checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 2)
          .isAllowed,
      isFalse,
    );
    expect(
      policy.checkLocalPublication(keyEpoch: 2).decision,
      MembershipSyncDecision.rejected,
    );
    expect(
      policy
          .checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 2)
          .isAllowed,
      isFalse,
    );
  });

  test(
    'session uses public membership while business requires current epoch key',
    () async {
      final f = await membershipFixture();
      var keyAvailable = false;
      final policy = MembershipSyncPolicy(
        membership: f.reducer,
        localDeviceId: f.founder.deviceId,
        hasEpochKey: (epoch) => keyAvailable && epoch == 1,
      );
      expect(policy.checkSession(f.guest.deviceId).isAllowed, isTrue);
      expect(
        policy
            .checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
            .decision,
        MembershipSyncDecision.waiting,
      );
      expect(
        policy
            .checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
            .decision,
        MembershipSyncDecision.waiting,
      );
      expect(policy.checkLocalPublication(keyEpoch: 1).isAllowed, isFalse);
      keyAvailable = true;
      expect(
        policy
            .checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
            .isAllowed,
        isTrue,
      );
      expect(
        policy
            .checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
            .isAllowed,
        isTrue,
      );
      expect(policy.checkLocalPublication(keyEpoch: 1).isAllowed, isTrue);
      expect(
        policy.checkSession('unknown').decision,
        MembershipSyncDecision.rejected,
      );
    },
  );

  test('revocation rejects future sessions and new inbound but waits for old history', () async {
    final f = await membershipFixture();
    final policy = MembershipSyncPolicy(
      membership: f.reducer,
      localDeviceId: f.founder.deviceId,
      hasEpochKey: (_) => true,
    );
    final revoke = await MembershipEvent.create(
      parent: f.reducer.state,
      issuer: f.founder,
      type: MembershipEventType.revoke,
      targetDeviceId: f.guest.deviceId,
    );
    await f.reducer.ingest(revoke, issuerFileDeviceId: f.founder.deviceId);
    expect(
      policy.checkSession(f.guest.deviceId).decision,
      MembershipSyncDecision.rejected,
    );
    expect(
      policy.checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1).decision,
      MembershipSyncDecision.waiting,
    );
    for (final epoch in [2, 3]) {
      expect(
        policy
            .checkInbound(peerDeviceId: f.guest.deviceId, keyEpoch: epoch)
            .decision,
        MembershipSyncDecision.rejected,
      );
    }
    expect(
      policy
          .checkOutbound(peerDeviceId: f.guest.deviceId, keyEpoch: 1)
          .decision,
      MembershipSyncDecision.rejected,
    );
  });
}
