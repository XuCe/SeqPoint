import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/identity/pairing_secrets.dart';
import 'package:test/test.dart';
import 'pairing_transcript_test.dart' show ExpiringClock;

void main() {
  late DeviceKeys a, b; late FakeClock clock; late PairingTranscript transcript;
  setUp(() async {
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    clock = FakeClock(DateTime.utc(2026, 10, 26));
    PairingParticipant p(DeviceKeys k, int n) => PairingParticipant(deviceId: k.deviceId,
        signingPublicKey: k.signer.publicKey, exchangePublicKey: k.exchangePublicKey,
        nonce: List.filled(32, n), tlsFingerprint: 'a' * 64);
    transcript = PairingTranscript(vaultPublicId: 'v1', sessionId: 's1', initiator: p(a, 1),
        responder: p(b, 2), expiresAt: clock.now().add(const Duration(minutes: 5)));
  });
  test('双端X25519/HKDF结果一致，用途密钥隔离、短码稳定、输出不可变', () async {
    final first = await derivePairingSecrets(localKeys: a, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: clock);
    final peer = await derivePairingSecrets(localKeys: b, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: clock);
    expect(first.encryptionKey, peer.encryptionKey); expect(first.confirmationKey, peer.confirmationKey);
    expect(first.encryptionKey, hasLength(32)); expect(first.confirmationKey, hasLength(32));
    expect(first.confirmationKey, isNot(first.encryptionKey));
    expect(first.shortCode, peer.shortCode); expect(first.shortCode, matches(r'^[A-F0-9]{2}(-[A-F0-9]{2}){2}$'));
    expect(() => first.encryptionKey.clear(), throwsUnsupportedError);
    expect(() => first.confirmationKey.clear(), throwsUnsupportedError);
    final otherSecret = await derivePairingSecrets(localKeys: a, transcript: transcript,
        pairingSecret: List.filled(32, 8), clock: clock);
    expect(otherSecret.encryptionKey, isNot(first.encryptionKey));
  });
  test('过期和非法一次性秘密均不得派生有效会话', () async {
    await expectLater(derivePairingSecrets(localKeys: a, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: ExpiringClock(clock.now())), throwsStateError);
    for (final secret in [List.filled(31, 7), List.filled(32, 256)]) {
      await expectLater(derivePairingSecrets(localKeys: a, transcript: transcript,
          pairingSecret: secret, clock: clock), throwsArgumentError);
    }
  });
  test('冻结一次性秘密，transcript改动或本机协商身份不符不能混用原密钥', () async {
    final secret = List.filled(32, 7);
    final future = derivePairingSecrets(localKeys: a, transcript: transcript, pairingSecret: secret, clock: clock);
    secret[0] = 8; final original = await future;
    final peer = await derivePairingSecrets(localKeys: b, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: clock);
    expect(original.encryptionKey, peer.encryptionKey);
    final changed = PairingTranscript(vaultPublicId: 'v2', sessionId: transcript.sessionId,
        initiator: transcript.initiator, responder: transcript.responder, expiresAt: transcript.expiresAt);
    final other = await derivePairingSecrets(localKeys: a, transcript: changed,
        pairingSecret: List.filled(32, 7), clock: clock);
    expect(other.encryptionKey, isNot(original.encryptionKey));
    final wrongExchange = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 5));
    await expectLater(derivePairingSecrets(localKeys: wrongExchange, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: clock), throwsStateError);
  });
  test('HKDF异步完成后再次核对期限，过期不返回会话材料', () async {
    await expectLater(derivePairingSecrets(localKeys: a, transcript: transcript,
        pairingSecret: List.filled(32, 7), clock: AfterVerificationClock(clock.now())), throwsStateError);
  });
}

class AfterVerificationClock implements Clock {
  AfterVerificationClock(this.start);
  final DateTime start;
  var reads = 0;
  @override
  DateTime now() => reads++ < 2 ? start : start.add(const Duration(minutes: 6));
}
