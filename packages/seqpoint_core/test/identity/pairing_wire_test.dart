import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late PairingTranscript frame;
  setUp(() async {
    final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    PairingParticipant p(DeviceKeys k, int n) => PairingParticipant(deviceId: k.deviceId,
        signingPublicKey: k.signer.publicKey, exchangePublicKey: k.exchangePublicKey,
        nonce: List.filled(32, n), tlsFingerprint: 'a' * 64);
    frame = PairingTranscript(vaultPublicId: 'v', sessionId: 's', initiator: p(a, 1),
        responder: p(b, 2), expiresAt: DateTime.utc(2026, 10, 26, 0, 5));
  });
  test('公开材料和transcript规范往返，解析后不再引用输入map', () async {
    final json = frame.toJson();
    final parsed = PairingTranscript.fromJson(json);
    (json['initiator'] as Map)['nonce'] = 'changed'; json['session_id'] = 'changed';
    expect(parsed.canonicalBytes, frame.canonicalBytes);
    await parsed.verify(clock: FakeClock(DateTime.utc(2026, 10, 26)));
    expect(PairingParticipant.fromJson(frame.responder.toJson()).toJson(), frame.responder.toJson());
  });
  test('wire拒绝额外字段、弱类型、非规范编码或日期，不接受静默归一', () {
    for (final mutate in <void Function(Map<String, Object?>)>[
      (m) => m['extra'] = true, (m) => m['v'] = 1.0, (m) => m['v'] = 2,
      (m) => m['purpose'] = 'other', (m) => m['type'] = 'other',
      (m) => m['expires_at'] = '2026-10-26T00:05:00+00:00',
      (m) => m['expires_at'] = '2026-10-32T00:05:00.000Z',
      (m) => m['initiator'] = [],
      (m) => (m['initiator'] as Map)['extra'] = true,
      (m) => (m['initiator'] as Map)['signing_pub'] = 'a' * 44,
      (m) => (m['initiator'] as Map)['exchange_pub'] = '${'a' * 42}?',
      (m) => (m['initiator'] as Map)['nonce'] = '${'a' * 42}_',
      (m) => (m['responder'] as Map)['tls_sha256'] = '${'a' * 64}\n',
    ]) {
      final json = frame.toJson(); mutate(json);
      expect(() => PairingTranscript.fromJson(json), throwsFormatException);
    }
  });
}
