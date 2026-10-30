import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';

void main() {
  test('完整控制记录重放保留旧父授权和分叉证据', () async {
    final f = await membershipFixture();
    final a = await MembershipEvent.create(parent: f.reducer.state,
        issuer: f.founder, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: f.reducer.state,
        issuer: f.guest, type: MembershipEventType.rotate);
    await f.reducer.ingest(a, issuerFileDeviceId: f.founder.deviceId);
    final restored = await MembershipReducer.restoreTrustedLocal(f.reducer.toTrustedLocalJson());
    await restored.ingest(b, issuerFileDeviceId: f.guest.deviceId);
    expect(restored.isConflicted, isTrue);
    final after = await MembershipReducer.restoreTrustedLocal(restored.toTrustedLocalJson());
    expect(after.isConflicted, isTrue);
    expect(after.evidence.length, 3);
    expect(after.knownMemberKeys(f.guest.deviceId)!.deviceId, f.guest.deviceId);
    expect(after.maximumObservedEpoch, 2);
  });
  test('本机安全记录严格恢复，保留承诺历史且hash必须一致', () async {
    final f = await membershipFixture();
    final state = f.reducer.state;
    final restored = await MembershipState.restoreTrustedLocal(state.toJson(), expectedHeadHash: state.headHash);
    expect(restored.toJson(), state.toJson());
    expect(restored.keyCommitments, state.keyCommitments);
    await expectLater(MembershipState.restoreTrustedLocal(state.toJson(),
        expectedHeadHash: f.initial.headHash), throwsStateError);
    final duplicate = state.toJson();
    (duplicate['members'] as List).add((duplicate['members'] as List).first);
    await expectLater(MembershipState.restoreTrustedLocal(duplicate,
        expectedHeadHash: state.headHash), throwsFormatException);
  });
  test('检查点拒绝多余字段、错误身份、集合顺序与集合重叠', () async {
    final f = await membershipFixture(), state = f.reducer.state;
    final extra = {...state.toJson(), 'trusted': true};
    await expectLater(MembershipState.restoreTrustedLocal(extra,
        expectedHeadHash: state.headHash), throwsFormatException);
    final order = state.toJson();
    order['members'] = (order['members'] as List).reversed.toList();
    await expectLater(MembershipState.restoreTrustedLocal(order,
        expectedHeadHash: state.headHash), throwsFormatException);
    final overlap = state.toJson(); overlap['revoked'] = [f.founder.deviceId];
    await expectLater(MembershipState.restoreTrustedLocal(overlap,
        expectedHeadHash: state.headHash), throwsFormatException);
  });
}
