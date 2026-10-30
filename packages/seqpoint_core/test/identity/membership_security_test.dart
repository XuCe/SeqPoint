import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart' hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';

void main() {
  test('事件自带身份和有效私钥签名不能绕过已验证父状态授权', () async {
    final f = await membershipFixture();
    final json = f.add.toJson(); json['issuer_id'] = f.guest.deviceId;
    final unsigned = MembershipEvent.fromJson(json);
    json['signature'] = base64UrlEncode(await f.guest.signer.sign(unsigned.signingBytes)).replaceAll('=', '');
    final reducer = MembershipReducer(trustedAnchor: f.initial);
    await expectLater(reducer.ingest(MembershipEvent.fromJson(json),
        issuerFileDeviceId: f.guest.deviceId), throwsStateError);
    expect(reducer.state.headHash, f.initial.headHash);
    expect(reducer.evidence, isEmpty);
  });
  test('有效签名撤销即使本机密文损坏仍公开生效，不能回退旧Epoch', () async {
    final f = await membershipFixture();
    final event = await MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    final json = event.toJson();
    ((json['envelopes'] as List).single as Map)['frame'] =
        base64UrlEncode(List.filled(72, 0)).replaceAll('=', '');
    final unsigned = MembershipEvent.fromJson(json);
    json['signature'] = base64UrlEncode(await f.founder.signer.sign(unsigned.signingBytes)).replaceAll('=', '');
    await f.reducer.ingest(MembershipEvent.fromJson(json), issuerFileDeviceId: f.founder.deviceId);
    expect(f.reducer.state.epoch, 2);
    expect(f.reducer.isMemberAuthorized(f.guest.deviceId), isFalse);
    await expectLater(f.reducer.openCurrentEpoch(localDevice: f.founder), throwsStateError);
    expect(f.reducer.state.epoch, 2);
  });
  test('异步开封期间新授权到达则不返回过期本机Epoch', () async {
    final f = await membershipFixture();
    final rotate = await MembershipEvent.create(parent: f.reducer.state,
        issuer: f.founder, type: MembershipEventType.rotate);
    final opening = f.reducer.openCurrentEpoch(localDevice: f.guest);
    final accepting = f.reducer.ingest(rotate, issuerFileDeviceId: f.founder.deviceId);
    await accepting;
    try {
      final key = await opening;
      expect(key?.epoch, 1);
    } on StateError {
      expect(f.reducer.state.epoch, 2);
    }
    expect((await f.reducer.openCurrentEpoch(localDevice: f.guest))!.epoch, 2);
  });
  test('签名覆盖公开变更和全部封装，错误文件不能注入', () async {
    final f = await membershipFixture();
    final rotate = await MembershipEvent.create(parent: f.reducer.state,
        issuer: f.founder, type: MembershipEventType.rotate);
    await expectLater(f.reducer.ingest(rotate, issuerFileDeviceId: f.guest.deviceId), throwsStateError);
    final changed = rotate.toJson(); changed['issued_at'] = rotate.issuedAt + 1;
    await expectLater(f.reducer.ingest(MembershipEvent.fromJson(changed),
        issuerFileDeviceId: f.founder.deviceId), throwsStateError);
    final missing = rotate.toJson(); (missing['envelopes'] as List).removeLast();
    await expectLater(f.reducer.ingest(MembershipEvent.fromJson(missing),
        issuerFileDeviceId: f.founder.deviceId), throwsStateError);
    expect(f.reducer.state.epoch, 1);
    expect(f.reducer.evidence.length, 1);
  });
  test('拒绝自撤销、旧密钥复用和已撤销签发者授权', () async {
    final f = await membershipFixture();
    await expectLater(MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.revoke, targetDeviceId: f.founder.deviceId), throwsStateError);
    await expectLater(MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.rotate, epochKey: VaultKey(epoch: 2, keyBytes: f.key.keyBytes)), throwsStateError);
    final revoke = await MembershipEvent.create(parent: f.reducer.state, issuer: f.founder,
        type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    await f.reducer.ingest(revoke, issuerFileDeviceId: f.founder.deviceId);
    await expectLater(MembershipEvent.create(parent: f.reducer.state,
        issuer: f.guest, type: MembershipEventType.rotate), throwsStateError);
    final json = revoke.toJson(); json['signature'] = base64UrlEncode(List.filled(64, 0)).replaceAll('=', '');
    await expectLater(f.reducer.ingest(MembershipEvent.fromJson(json),
        issuerFileDeviceId: f.founder.deviceId), throwsStateError);
  });
}
