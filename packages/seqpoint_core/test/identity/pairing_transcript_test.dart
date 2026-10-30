import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceKeys a, b; late FakeClock clock;
  PairingParticipant participant(DeviceKeys keys, int nonce, {String? fingerprint}) =>
      PairingParticipant(deviceId: keys.deviceId, signingPublicKey: keys.signer.publicKey,
          exchangePublicKey: keys.exchangePublicKey, nonce: List.filled(32, nonce),
          tlsFingerprint: fingerprint ?? 'a' * 64);
  PairingTranscript transcript({String vault = 'v1', String session = 'session1',
    PairingParticipant? host, PairingParticipant? guest, DateTime? expires,
  }) => PairingTranscript(vaultPublicId: vault, sessionId: session,
      initiator: host ?? participant(a, 1), responder: guest ?? participant(b, 2),
      expiresAt: expires ?? clock.now().add(const Duration(minutes: 5)));
  setUp(() async {
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    clock = FakeClock(DateTime.utc(2026, 10, 26));
  });
  test('规范transcript双端身份可核验，所有公开字节复制且不可变', () async {
    final nonce = List.filled(32, 1), key = [...a.signer.publicKey];
    final host = PairingParticipant(deviceId: a.deviceId, signingPublicKey: key,
        exchangePublicKey: a.exchangePublicKey, nonce: nonce, tlsFingerprint: 'a' * 64);
    final frame = transcript(host: host), before = transcript().canonicalBytes;
    nonce[0] = 0; key[0] ^= 1;
    await frame.verify(clock: clock); expect(frame.canonicalBytes, before);
    expect(() => frame.canonicalBytes[0] = 0, throwsUnsupportedError);
    expect(() => host.nonce.clear(), throwsUnsupportedError);
    expect(() => host.signingPublicKey.clear(), throwsUnsupportedError);
  });
  test('Vault/session/期限/角色/双方nonce与TLS指纹均绑定规范字节', () async {
    final original = transcript().canonicalBytes;
    for (final changed in [
      transcript(vault: 'v2'), transcript(session: 'session2'),
      transcript(expires: clock.now().add(const Duration(minutes: 6))),
      transcript(host: participant(b, 2), guest: participant(a, 1)),
      transcript(host: participant(a, 3)), transcript(guest: participant(b, 3)),
      transcript(host: participant(a, 1, fingerprint: 'b' * 64)),
      transcript(guest: participant(b, 2, fingerprint: 'b' * 64)),
    ]) { await changed.verify(clock: clock); expect(changed.canonicalBytes, isNot(original)); }
  });
  test('异步核对身份后再次检查期限，不放行核对期间过期的材料', () async {
    await expectLater(transcript().verify(clock: ExpiringClock(clock.now())), throwsStateError);
  });
  test('拒绝坏字节/指纹/标识/重复参与方，身份冒领与期限失败不成为有效会话', () async {
    for (final id in ['', 'x' * 129, 'bad\n']) {
      expect(() => transcript(vault: id), throwsArgumentError);
      expect(() => transcript(session: id), throwsArgumentError);
    }
    for (final fingerprint in ['a' * 63, 'g' * 64, '${'a' * 64}\n']) {
      expect(() => participant(a, 1, fingerprint: fingerprint), throwsArgumentError);
    }
    for (final nonce in [List.filled(31, 1), List.filled(32, 256)]) {
      expect(() => PairingParticipant(deviceId: a.deviceId, signingPublicKey: a.signer.publicKey,
          exchangePublicKey: a.exchangePublicKey, nonce: nonce, tlsFingerprint: 'a' * 64), throwsArgumentError);
    }
    expect(() => transcript(guest: participant(a, 2)), throwsArgumentError);
    expect(() => transcript(guest: participant(b, 1)), throwsArgumentError);
    expect(() => transcript(expires: DateTime(2026, 10, 26)), throwsArgumentError);
    final impostor = PairingParticipant(deviceId: 'z' * 43, signingPublicKey: a.signer.publicKey,
        exchangePublicKey: a.exchangePublicKey, nonce: List.filled(32, 1), tlsFingerprint: 'a' * 64);
    await expectLater(transcript(host: impostor).verify(clock: clock), throwsStateError);
    for (final expires in [clock.now(), clock.now().subtract(const Duration(seconds: 1)),
      clock.now().add(const Duration(minutes: 11))]) {
      await expectLater(transcript(expires: expires).verify(clock: clock), throwsStateError);
    }
  });
}

class ExpiringClock implements Clock {
  ExpiringClock(this.start);
  final DateTime start;
  var reads = 0;
  @override
  DateTime now() => reads++ == 0 ? start : start.add(const Duration(minutes: 6));
}
