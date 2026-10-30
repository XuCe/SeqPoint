import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceKeys a, b; late FakeClock clock;
  late PairingInvitation own, guest;
  Future<PairingResponse> respond() => PairingResponse.create(invitation: guest,
      keys: b, tlsFingerprint: 'b' * 64, clock: clock);
  setUp(() async {
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    clock = FakeClock(DateTime.utc(2026, 10, 26));
    own = await PairingInvitation.create(keys: a, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: clock);
    guest = await PairingInvitation.fromQr(own.toQrPayload(), clock: clock);
  });
  test('签名应答绑定完整双端上下文，wire不含QR秘密或Epoch且解析冻结输入', () async {
    final response = await respond(), json = response.toJson();
    expect(json.keys, unorderedEquals(['purpose', 'v', 'type', 'transcript', 'signature']));
    expect(jsonEncode(json), isNot(contains(base64UrlEncode(own.pairingSecret).replaceAll('=', ''))));
    final parsing = PairingResponse.fromJson(json, invitation: own, clock: clock);
    (json['transcript'] as Map)['session_id'] = 'changed';
    expect((await parsing).transcript.canonicalBytes, response.transcript.canonicalBytes);
    expect(response.transcript.initiator.deviceId, a.deviceId);
    expect(response.transcript.responder.deviceId, b.deviceId);
  });
  test('篡改邀请或应答材料、期限和签名均不能通过', () async {
    final response = await respond();
    String bytes(int n, int count) => base64UrlEncode(List.filled(count, n)).replaceAll('=', '');
    for (final change in <void Function(Map)>[
      (t) => t['vault_id'] = 'other', (t) => t['session_id'] = 'other',
      (t) => t['expires_at'] = own.expiresAt.subtract(const Duration(minutes: 1)).toIso8601String(),
      (t) => (t['initiator'] as Map)['tls_sha256'] = 'c' * 64,
      (t) => (t['responder'] as Map)['nonce'] = bytes(7, 32),
      (t) => (t['responder'] as Map)['exchange_pub'] = bytes(7, 32),
      (t) => (t['responder'] as Map)['signing_pub'] = bytes(7, 32),
    ]) {
      final json = response.toJson(); change(json['transcript'] as Map);
      await expectLater(PairingResponse.fromJson(json, invitation: own, clock: clock), throwsStateError);
    }
  });
  test('严格wire及其他真实签名邀请不能混用，坏签名拒绝', () async {
    final response = await respond();
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['extra'] = true, (m) => m['v'] = 1.0,
      (m) => m['type'] = 'invitation', (m) => m['signature'] = 'a' * 85,
    ]) {
      final json = response.toJson(); change(json);
      await expectLater(PairingResponse.fromJson(json, invitation: own, clock: clock), throwsFormatException);
    }
    final bad = response.toJson()..['signature'] = base64UrlEncode(List.filled(64, 7)).replaceAll('=', '');
    await expectLater(PairingResponse.fromJson(bad, invitation: own, clock: clock), throwsStateError);
    final other = await PairingInvitation.create(keys: a, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: clock);
    await expectLater(PairingResponse.fromJson(response.toJson(), invitation: other, clock: clock), throwsStateError);
  });
  test('只接受收到的邀请一次，本机邀请不能用作应答', () async {
    await respond();
    await expectLater(respond(), throwsStateError);
    await expectLater(PairingResponse.create(invitation: own, keys: b,
        tlsFingerprint: 'b' * 64, clock: clock), throwsStateError);
    own.checkActive();
  });
  test('签名或验签期间取消不返回可使用应答', () async {
    final creating = respond(); guest.cancel(); await expectLater(creating, throwsStateError);
    guest = await PairingInvitation.fromQr(own.toQrPayload(), clock: clock);
    final response = await respond();
    final parsing = PairingResponse.fromJson(response.toJson(), invitation: own, clock: clock);
    own.cancel(); await expectLater(parsing, throwsStateError);
  });
}
