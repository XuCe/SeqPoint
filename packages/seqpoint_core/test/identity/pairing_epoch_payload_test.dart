import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/identity/pairing_secrets.dart';
import 'package:test/test.dart';
import 'pairing_handshake_test.dart' show pairedFixture;
import 'pairing_epoch_test.dart' show confirmPair, testCheckpointHash;

void main() {
  test('有效AEAD内的坏JSON/额外字段/弱类型/坏密钥均拒绝，错误不泄露明文', () async {
    const marker = 'SENSITIVE_TEST_KEY';
    final key = base64UrlEncode(List.filled(32, 42)).replaceAll('=', '');
    for (final plaintext in [
      'bad:$marker:$key', jsonEncode({'v': 1, 'epoch': 1, 'key': key, 'extra': marker}),
      jsonEncode({'v': 1.0, 'epoch': 1, 'key': key}), jsonEncode({'v': 1, 'epoch': 0, 'key': key}),
      jsonEncode({'v': 1, 'epoch': 1.0, 'key': key}), jsonEncode({'v': 1, 'epoch': 1, 'key': 'a' * 42}),
    ]) {
      final f = await pairedFixture(); await confirmPair(f.host, f.guest);
      final material = await derivePairingSecrets(localKeys: f.hostKeys, transcript: f.host.response.transcript,
          pairingSecret: f.invitation.pairingSecret, clock: f.clock);
      final aad = utf8.encode(jsonEncode({
        'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'epoch-key',
        'transcript': f.host.response.transcript.toJson(),
        'sender_id': f.hostKeys.deviceId, 'recipient_id': f.guestKeys.deviceId,
        'checkpoint_hash': testCheckpointHash,
      }));
      final frame = await XChaCha20Aead().seal(utf8.encode(plaintext), material.encryptionKey, aad: aad);
      final wire = <String, Object?>{
        'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'epoch',
        'session_id': f.invitation.sessionId, 'sender_id': f.hostKeys.deviceId, 'recipient_id': f.guestKeys.deviceId,
        'checkpoint_hash': testCheckpointHash,
        'ciphertext': base64UrlEncode(frame).replaceAll('=', ''),
      };
      await expectLater(f.guest.openEpoch(wire), throwsA(isA<StateError>().having((e) => e.toString(),
          'safe message', allOf(isNot(contains(marker)), isNot(contains(key))))));
      expect(f.guest.state, PairingHandshakeState.cancelled);
    }
  });
}
