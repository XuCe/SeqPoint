import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceKeys keys; late FakeClock clock;
  Future<PairingInvitation> create() => PairingInvitation.create(keys: keys,
      vaultPublicId: 'v1', tlsFingerprint: 'a' * 64, clock: clock);
  setUp(() async {
    keys = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    clock = FakeClock(DateTime.utc(2026, 10, 26));
  });
  test('真实签名QR往返，session/nonce/秘密随机且无Epoch或私钥', () async {
    final own = await create(), another = await create();
    final qr = own.toQrPayload();
    expect(qr.keys, unorderedEquals(['purpose', 'v', 'type', 'vault_id', 'session_id',
      'expires_at', 'initiator', 'secret', 'signature']));
    final peer = await PairingInvitation.fromQr(qr, clock: clock);
    expect(peer.initiator.deviceId, keys.deviceId); expect(peer.pairingSecret, own.pairingSecret);
    expect(peer.isLocalInvitation, isFalse); expect(own.isLocalInvitation, isTrue);
    expect(own.sessionId, isNot(another.sessionId));
    expect(own.initiator.nonce, isNot(another.initiator.nonce));
    expect(own.pairingSecret, isNot(another.pairingSecret));
    expect(() => peer.pairingSecret.clear(), throwsUnsupportedError);
  });
  test('签名绑定会话/Vault/期限/双公钥/nonce/TLS/一次性秘密', () async {
    final own = await create();
    String encoded(int n, int length) => base64UrlEncode(List.filled(length, n)).replaceAll('=', '');
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['session_id'] = 'other', (m) => m['vault_id'] = 'other',
      (m) => m['expires_at'] = own.expiresAt.subtract(const Duration(minutes: 1)).toIso8601String(),
      (m) => m['secret'] = encoded(7, 32), (m) => m['signature'] = encoded(7, 64),
      (m) => (m['initiator'] as Map)['nonce'] = encoded(7, 32),
      (m) => (m['initiator'] as Map)['exchange_pub'] = encoded(7, 32),
      (m) => (m['initiator'] as Map)['signing_pub'] = encoded(7, 32),
      (m) => (m['initiator'] as Map)['tls_sha256'] = 'b' * 64,
    ]) {
      final qr = own.toQrPayload(); change(qr);
      await expectLater(PairingInvitation.fromQr(qr, clock: clock), throwsStateError);
    }
  });
  test('邀请wire严格解析，冻结输入后才异步验签', () async {
    final own = await create();
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['extra'] = true, (m) => m['v'] = 1.0, (m) => m.remove('signature'),
      (m) => m['type'] = 'response', (m) => m['secret'] = 'a' * 44,
      (m) => m['signature'] = 'a' * 85,
      (m) => m['expires_at'] = '2026-10-26T00:10:00+00:00',
    ]) {
      final qr = own.toQrPayload(); change(qr);
      await expectLater(PairingInvitation.fromQr(qr, clock: clock), throwsFormatException);
    }
    final qr = own.toQrPayload(), expected = own.toQrPayload();
    final parsing = PairingInvitation.fromQr(qr, clock: clock);
    (qr['initiator'] as Map)['tls_sha256'] = 'b' * 64; qr['secret'] = 'changed';
    expect((await parsing).toQrPayload(), expected);
  });
  test('观察过期后时钟回拨不复活同一邀请', () async {
    final own = await create(), start = clock.now();
    clock.advance(const Duration(minutes: 11)); expect(own.checkActive, throwsStateError);
    clock.set(start); expect(own.checkActive, throwsStateError);
    expect(() => own.claim(asInitiator: true), throwsStateError);
  });
  test('签名或验签期间过期均不返回可使用邀请', () async {
    await expectLater(PairingInvitation.create(keys: keys, vaultPublicId: 'v1',
        tlsFingerprint: 'a' * 64, clock: DeadlineClock(clock.now(), 2)), throwsStateError);
    final qr = (await create()).toQrPayload();
    await expectLater(PairingInvitation.fromQr(qr,
        clock: DeadlineClock(clock.now(), 1)), throwsStateError);
  });
  test('仅匹配来源角色可claim一次，取消/过期不能再使用或显示QR', () async {
    final own = await create(), qr = (await create()).toQrPayload();
    own.claim(asInitiator: true); expect(() => own.claim(asInitiator: true), throwsStateError);
    final peer = await PairingInvitation.fromQr(qr, clock: clock);
    expect(() => peer.claim(asInitiator: true), throwsStateError);
    peer.claim(asInitiator: false); expect(() => peer.claim(asInitiator: false), throwsStateError);
    own.cancel(); expect(own.checkActive, throwsStateError);
    expect(own.toQrPayload, throwsStateError); expect(() => own.pairingSecret, throwsStateError);
    clock.advance(const Duration(minutes: 11));
    await expectLater(PairingInvitation.fromQr(qr, clock: clock), throwsStateError);
  });
}

class DeadlineClock implements Clock {
  DeadlineClock(this.start, this.validReads);
  final DateTime start;
  final int validReads;
  var reads = 0;
  @override
  DateTime now() => reads++ < validReads ? start : start.add(const Duration(minutes: 11));
}
