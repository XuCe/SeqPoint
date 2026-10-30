import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'pairing_handshake_test.dart' show pairedFixture;
import 'pairing_epoch_test.dart' show confirmPair, testCheckpointHash;

void main() {
  test('Epoch消息严格wire、尺寸/类型或错误目标被拒绝，真实密文不可篡改', () async {
    for (final entry in <(void Function(Map<String, Object?>), Matcher)>[
      ((m) => m['extra'] = true, throwsFormatException),
      ((m) => m['v'] = 1.0, throwsFormatException),
      ((m) => m['type'] = 'confirmation', throwsFormatException),
      ((m) => m['ciphertext'] = 'a' * 343, throwsFormatException),
      ((m) => m['ciphertext'] = '?', throwsFormatException),
      ((m) => m['session_id'] = 'other', throwsStateError),
      ((m) => m['recipient_id'] = m['sender_id'], throwsStateError),
      ((m) { final bytes = base64Url.decode(base64Url.normalize(m['ciphertext'] as String));
        bytes[0] ^= 1; m['ciphertext'] = base64UrlEncode(bytes).replaceAll('=', ''); }, throwsStateError),
    ]) {
      final f = await pairedFixture(); await confirmPair(f.host, f.guest);
      final wire = {...await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash)};
      entry.$1(wire); await expectLater(f.guest.openEpoch(wire), entry.$2);
      expect(f.guest.state, PairingHandshakeState.cancelled);
    }
  });
  test('相同身份另一会话即使修改外层session也无法解封旧密文', () async {
    final f = await pairedFixture(), other = await pairedFixture();
    await confirmPair(f.host, f.guest); await confirmPair(other.host, other.guest);
    final wire = {...await f.host.sealEpoch(VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: testCheckpointHash),
      'session_id': other.invitation.sessionId};
    await expectLater(other.guest.openEpoch(wire), throwsStateError);
    expect(other.guest.state, PairingHandshakeState.cancelled);
  });
}
