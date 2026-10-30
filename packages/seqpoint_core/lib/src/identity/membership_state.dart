import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/vault_key.dart';
import 'device_keys.dart';
import 'member_keys.dart';
import 'member_epoch_envelope.dart';
import '../util/clock.dart';
import 'pairing_transcript.dart' show parsePairingBytes;
import 'pairing_handshake.dart';

part 'membership_event.dart';
part 'membership_reducer.dart';
part 'membership_checkpoint.dart';

final class MembershipState {
  MembershipState._({required this.vaultPublicId, required this.authorityId, required this.epoch,
    required this.keyCommitment, required this.parentHash, required this.eventHash,
    required Map<String, MemberKeys> members, required Set<String> revokedIds,
    required Map<String, int> issuerSequences, Set<String>? keyCommitments,
  }) : members = Map.unmodifiable(members), revokedIds = Set.unmodifiable(revokedIds),
       issuerSequences = Map.unmodifiable(issuerSequences),
       keyCommitments = Set.unmodifiable(keyCommitments ?? {keyCommitment});
  final String vaultPublicId, authorityId, keyCommitment;
  final int epoch;
  final String? parentHash, eventHash;
  final Map<String, MemberKeys> members;
  final Set<String> revokedIds;
  final Set<String> keyCommitments;
  final Map<String, int> issuerSequences;
  late final String _headHash;
  String get headHash => _headHash;
  /// 仅恢复已认证并存于本机SecretStore的记录；网络成员文件不能调用此入口。
  static Future<MembershipState> restoreTrustedLocal(Map<String, Object?> checkpoint,
      {required String expectedHeadHash}) => _restoreMembershipCheckpoint(checkpoint, expectedHeadHash);
  static Future<MembershipState> fromConfirmedPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint}) =>
      _fromCompletedPairing(session: session, checkpoint: checkpoint, hosted: false);
  static Future<MembershipState> fromHostedPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint}) =>
      _fromCompletedPairing(session: session, checkpoint: checkpoint, hosted: true);
  static Future<MembershipState> _fromCompletedPairing({required PairingHandshake session,
      required bool hosted,
      required Map<String, Object?> checkpoint}) async {
    final transcript = session.response.transcript;
    final expectedLocal = hosted ? transcript.initiator.deviceId : transcript.responder.deviceId;
    if (session.state != PairingHandshakeState.completed ||
        session.localDeviceId != expectedLocal || session.confirmedCheckpointHash == null) {
      throw StateError('必须由完成确认的对应端配对引导');
    }
    final result = await _restoreMembershipCheckpoint(checkpoint, session.confirmedCheckpointHash!);
    if (result.vaultPublicId != transcript.vaultPublicId || result.epoch != session.confirmedEpoch ||
        result.keyCommitment != session.confirmedKeyCommitment) {
      throw StateError('配对检查点Epoch或Vault不匹配');
    }
    for (final peer in [transcript.initiator, transcript.responder]) {
      final member = result.members[peer.deviceId];
      if (member == null || member.tlsFingerprint != peer.tlsFingerprint ||
          base64Encode(member.signingPublicKey) != base64Encode(peer.signingPublicKey) ||
          base64Encode(member.exchangePublicKey) != base64Encode(peer.exchangePublicKey)) {
        throw StateError('配对双方完整身份不在确认的成员名单');
      }
    }
    return result;
  }
  static Future<MembershipState> createVault({required DeviceKeys founder, required String vaultPublicId,
    required VaultKey epochKey, required String tlsFingerprint,
  }) async {
    final epoch = epochKey.epoch;
    if (epoch < 1) throw ArgumentError('初始Epoch无效');
    final member = MemberKeys(deviceId: founder.deviceId, signingPublicKey: founder.signer.publicKey,
        exchangePublicKey: founder.exchangePublicKey, tlsFingerprint: tlsFingerprint);
    final commitment = await epochKeyCommitment(vaultPublicId: vaultPublicId, keyBytes: epochKey.keyBytes);
    final random = Random.secure();
    final scope = base64UrlEncode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
    final result = MembershipState._(vaultPublicId: vaultPublicId, authorityId: scope, epoch: epoch,
        keyCommitment: commitment, parentHash: null, eventHash: null,
        members: {founder.deviceId: member}, revokedIds: const <String>{}, issuerSequences: const {});
    result._headHash = base64UrlEncode((await Sha256().hash(utf8.encode(jsonEncode(result.toJson())))).bytes).replaceAll('=', '');
    return result;
  }
  Map<String, Object?> toJson() {
    final ids = members.keys.toList()..sort(), revoked = revokedIds.toList()..sort(), seqs = issuerSequences.keys.toList()..sort();
    final commitments = keyCommitments.toList()..sort();
    return {
      'purpose': CryptoSpec.infoMembershipState, 'v': 1, 'vault_id': vaultPublicId, 'authority_id': authorityId,
      'epoch': epoch, 'key_commitment': keyCommitment, 'parent_hash': parentHash, 'event_hash': eventHash,
      'members': [for (final id in ids) members[id]!.toJson()],
      'revoked': revoked, 'issuer_seq': [for (final id in seqs) [id, issuerSequences[id]]],
      'key_commitments': commitments,
    };
  }
  Future<MembershipState> _apply(MembershipEvent event) async {
    await event._verify(this);
    final nextMembers = Map<String, MemberKeys>.of(members);
    final nextRevoked = Set<String>.of(revokedIds);
    if (event.type == MembershipEventType.add) {
      nextMembers[event.subject!.deviceId] = event.subject!;
    } else if (event.type == MembershipEventType.revoke) {
      nextMembers.remove(event.targetDeviceId);
      nextRevoked.add(event.targetDeviceId!);
    }
    final result = MembershipState._(vaultPublicId: vaultPublicId, authorityId: authorityId,
      epoch: event.epoch, keyCommitment: event.keyCommitment, parentHash: headHash,
      eventHash: await event.eventHash, members: nextMembers, revokedIds: nextRevoked,
      issuerSequences: {...issuerSequences, event.issuerDeviceId: event.issuerSequence},
      keyCommitments: {...keyCommitments, event.keyCommitment});
    result._headHash = base64UrlEncode((await Sha256().hash(
        utf8.encode(jsonEncode(result.toJson())))).bytes).replaceAll('=', '');
    return result;
  }
}
