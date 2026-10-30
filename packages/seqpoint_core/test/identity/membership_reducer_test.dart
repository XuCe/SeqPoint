import 'package:seqpoint_core/seqpoint_core.dart' hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';

void main() {
  test('待定事件也拒绝相同签发序号不同内容', () async {
    final f = await membershipFixture();
    final a = await MembershipEvent.create(parent: f.reducer.state, issuer: f.guest, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: f.reducer.state, issuer: f.guest, type: MembershipEventType.rotate);
    final reducer = MembershipReducer(trustedAnchor: f.initial);
    await reducer.ingest(a, issuerFileDeviceId: f.guest.deviceId);
    await expectLater(reducer.ingest(b, issuerFileDeviceId: f.guest.deviceId), throwsStateError);
  });
  test('撤销公开归约先于密钥，精确排除撤销者且禁止身份重入', () async {
    final f = await membershipFixture();
    final event = await MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    expect(event.envelopes.keys, [f.founder.deviceId]);
    await f.reducer.ingest(event, issuerFileDeviceId: f.founder.deviceId);
    expect(f.reducer.state.members, isNot(contains(f.guest.deviceId)));
    expect(f.reducer.state.revokedIds, contains(f.guest.deviceId));
    expect(await f.reducer.openCurrentEpoch(localDevice: f.guest), isNull);
    expect((await f.reducer.openCurrentEpoch(localDevice: f.founder))!.epoch, 2);
    await expectLater(MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.add, subject: memberIdentity(f.guest, 'b'),
        epochKey: VaultKey(epoch: 2, keyBytes: List.filled(32, 7))), throwsStateError);
  });
  test('未知父等待，父到达后按签名事实归约', () async {
    final f = await membershipFixture();
    final rotate = await MembershipEvent.create(parent: f.reducer.state,
        issuer: f.guest, type: MembershipEventType.rotate);
    final reducer = MembershipReducer(trustedAnchor: f.initial);
    expect(await reducer.ingest(rotate, issuerFileDeviceId: f.guest.deviceId), MembershipApplyResult.waiting);
    expect(reducer.state.headHash, f.initial.headHash);
    await reducer.ingest(f.add, issuerFileDeviceId: f.founder.deviceId);
    expect(reducer.pendingEvents, isEmpty);
    expect(reducer.state.epoch, 2);
    expect((await reducer.openCurrentEpoch(localDevice: f.founder))!.epoch, 2);
  });
  test('不同可信签发者同父合法分叉暂停，不选后继密钥', () async {
    final f = await membershipFixture(), parent = f.reducer.state;
    final a = await MembershipEvent.create(parent: parent, issuer: f.founder, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: parent, issuer: f.guest, type: MembershipEventType.rotate);
    await f.reducer.ingest(a, issuerFileDeviceId: f.founder.deviceId);
    expect(await f.reducer.ingest(b, issuerFileDeviceId: f.guest.deviceId), MembershipApplyResult.conflict);
    expect(f.reducer.evidence.length, 3);
    expect(f.reducer.isMemberAuthorized(f.founder.deviceId), isFalse);
    expect(await f.reducer.openCurrentEpoch(localDevice: f.founder), isNull);
  });
}
