import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'pairing_handshake_test.dart' show pairedFixture;
import 'pairing_epoch_test.dart' show confirmPair;

const checkpointHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  test('检查点hash认证绑定，完成会话提供不可伪造的成员引导依据', () async {
    final f = await pairedFixture();
    expect(f.guest.confirmedCheckpointHash, isNull);
    await confirmPair(f.host, f.guest);
    final key = VaultKey(epoch: 3, keyBytes: List.filled(32, 42));
    final wire = await f.host.sealEpoch(key, checkpointHash: checkpointHash);
    expect(wire['checkpoint_hash'], checkpointHash);
    final received = await f.guest.openEpoch(wire);
    expect(received.keyBytes, key.keyBytes);
    for (final side in [f.host, f.guest]) {
      expect(side.state, PairingHandshakeState.completed);
      expect(side.confirmedCheckpointHash, checkpointHash);
      expect(side.confirmedEpoch, 3);
      expect(side.confirmedKeyCommitment, await epochKeyCommitment(
          vaultPublicId: f.invitation.vaultPublicId, keyBytes: key.keyBytes));
    }
  });
  test('替换检查点或缺失检查点不能解封或提供引导依据', () async {
    for (final replacement in [null, 'AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA']) {
      final f = await pairedFixture(); await confirmPair(f.host, f.guest);
      final wire = {...await f.host.sealEpoch(
          VaultKey(epoch: 1, keyBytes: List.filled(32, 42)), checkpointHash: checkpointHash)};
      if (replacement == null) { wire.remove('checkpoint_hash'); }
      else { wire['checkpoint_hash'] = replacement; }
      await expectLater(f.guest.openEpoch(wire), throwsA(anyOf(isA<FormatException>(), isA<StateError>())));
      expect(f.guest.confirmedCheckpointHash, isNull);
      expect(f.guest.confirmedKeyCommitment, isNull);
    }
  });
}
