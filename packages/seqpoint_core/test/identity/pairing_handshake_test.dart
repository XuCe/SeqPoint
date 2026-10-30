import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Future<({PairingHandshake host, PairingHandshake guest, PairingInvitation invitation,
    PairingInvitation received, DeviceKeys hostKeys, DeviceKeys guestKeys, FakeClock clock})>
    pairedFixture() async {
  final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
  final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
  final clock = FakeClock(DateTime.utc(2026, 10, 26));
  final own = await PairingInvitation.create(keys: a, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: clock);
  final received = await PairingInvitation.fromQr(own.toQrPayload(), clock: clock);
  final guest = await PairingHandshake.respond(invitation: received, keys: b,
      tlsFingerprint: 'b' * 64, clock: clock);
  final host = await PairingHandshake.acceptResponse(invitation: own, keys: a,
      response: guest.response.toJson(), clock: clock);
  return (host: host, guest: guest, invitation: own, received: received, hostKeys: a, guestKeys: b, clock: clock);
}

void main() {
  test('真实签名邀请/应答派生相同短码，确认前都不能ready且无公开密钥材料', () async {
    final f = await pairedFixture();
    expect(f.host.shortCode, f.guest.shortCode);
    expect(f.host.state, PairingHandshakeState.awaitingConfirmation);
    expect(f.guest.state, PairingHandshakeState.awaitingConfirmation);
    expect(f.host.localDeviceId, f.hostKeys.deviceId); expect(f.guest.localDeviceId, f.guestKeys.deviceId);
  });
  test('本机邀请只能接受一次应答，扫码得到的邀请不能当发起方', () async {
    final f = await pairedFixture();
    await expectLater(PairingHandshake.acceptResponse(invitation: f.invitation, keys: f.hostKeys,
        response: f.guest.response.toJson(), clock: f.clock), throwsStateError);
    await expectLater(PairingHandshake.acceptResponse(invitation: f.received, keys: f.hostKeys,
        response: f.guest.response.toJson(), clock: f.clock), throwsStateError);
  });
  test('错误本机身份不消耗邀请，匹配身份才可接受', () async {
    final f = await pairedFixture();
    final own = await PairingInvitation.create(keys: f.hostKeys, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: f.clock);
    final received = await PairingInvitation.fromQr(own.toQrPayload(), clock: f.clock);
    final guest = await PairingHandshake.respond(invitation: received, keys: f.guestKeys, tlsFingerprint: 'b' * 64, clock: f.clock);
    await expectLater(PairingHandshake.acceptResponse(invitation: own, keys: f.guestKeys,
        response: guest.response.toJson(), clock: f.clock), throwsStateError);
    final host = await PairingHandshake.acceptResponse(invitation: own, keys: f.hostKeys,
        response: guest.response.toJson(), clock: f.clock);
    expect(host.shortCode, guest.shortCode);
  });
  test('应答核验期间取消邀请，不返回会话或恢复邀请使用权', () async {
    final f = await pairedFixture();
    final own = await PairingInvitation.create(keys: f.hostKeys, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: f.clock);
    final received = await PairingInvitation.fromQr(own.toQrPayload(), clock: f.clock);
    final guest = await PairingHandshake.respond(invitation: received, keys: f.guestKeys, tlsFingerprint: 'b' * 64, clock: f.clock);
    final accepting = PairingHandshake.acceptResponse(invitation: own, keys: f.hostKeys,
        response: guest.response.toJson(), clock: f.clock);
    own.cancel(); await expectLater(accepting, throwsStateError);
    expect(() => own.claim(asInitiator: true), throwsStateError);
  });
  test('邀请已观察过期时，会话不能因时钟回拨显示待确认', () async {
    final f = await pairedFixture(), start = DateTime.utc(2026, 10, 26);
    f.clock.advance(const Duration(minutes: 11)); expect(f.invitation.checkActive, throwsStateError);
    f.clock.set(start); expect(f.host.state, PairingHandshakeState.expired);
  });
  test('观察到过期后即使时钟回拨也不能恢复会话', () async {
    final f = await pairedFixture(), start = DateTime.utc(2026, 10, 26);
    f.clock.advance(const Duration(minutes: 11));
    expect(f.host.state, PairingHandshakeState.expired); expect(f.guest.state, PairingHandshakeState.expired);
    f.clock.set(start);
    expect(f.host.state, PairingHandshakeState.expired);
    expect(() => f.host.shortCode, throwsStateError);
  });
}
