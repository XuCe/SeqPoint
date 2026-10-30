part of 'membership_state.dart';

enum MembershipEventType { add, revoke, rotate }

final class MembershipEvent {
  static Future<MembershipEvent> create({required MembershipState parent,
    required DeviceKeys issuer, required MembershipEventType type, MemberKeys? subject,
    String? targetDeviceId, VaultKey? epochKey, Clock clock = const SystemClock(),
  }) async {
    final key = epochKey == null
        ? VaultKey(epoch: parent.epoch + 1, keyBytes: List.generate(32, (_) => Random.secure().nextInt(256)))
        : VaultKey(epoch: epochKey.epoch, keyBytes: List.unmodifiable(epochKey.keyBytes));
    final issuerIdentity = parent.members[issuer.deviceId];
    if (issuerIdentity == null ||
        base64Encode(issuer.signer.publicKey) != base64Encode(issuerIdentity.signingPublicKey) ||
        base64Encode(issuer.exchangePublicKey) != base64Encode(issuerIdentity.exchangePublicKey)) {
      throw StateError('签发者不在可信父状态');
    }
    final commitment = await epochKeyCommitment(vaultPublicId: parent.vaultPublicId, keyBytes: key.keyBytes);
    final id = base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    final target = type == MembershipEventType.add ? subject?.deviceId : targetDeviceId;
    final unsigned = MembershipEvent._(vaultPublicId: parent.vaultPublicId, authorityId: parent.authorityId,
      eventId: id, issuerDeviceId: issuer.deviceId, issuerSequence: (parent.issuerSequences[issuer.deviceId] ?? 0) + 1,
      parentHash: parent.headHash, type: type, targetDeviceId: target, subject: subject,
      epoch: key.epoch, keyCommitment: commitment, issuedAt: clock.now().millisecondsSinceEpoch,
      envelopes: const {}, signature: const []);
    final recipients = unsigned._recipients(parent);
    final envelopes = <String, MemberEpochEnvelope>{};
    for (final member in recipients.values) {
      envelopes[member.deviceId] = await MemberEpochEnvelope.seal(sender: issuer,
        senderIdentity: issuerIdentity, recipient: member, context: unsigned.contextBytes, epochKey: key);
    }
    final json = {...unsigned.toJson(), 'envelopes': [for (final entry in envelopes.values) entry.toJson()]};
    final prepared = MembershipEvent.fromJson({...json, 'signature': base64UrlEncode(List.filled(64, 0)).replaceAll('=', '')});
    return MembershipEvent.fromJson({...json,
      'signature': base64UrlEncode(await issuer.signer.sign(prepared.signingBytes)).replaceAll('=', '')});
  }
  factory MembershipEvent.fromJson(Map<String, Object?> json) {
    const fields = {'purpose', 'v', 'vault_id', 'authority_id', 'event_id', 'issuer_id',
      'issuer_seq', 'parent_hash', 'type', 'target_id', 'subject', 'epoch',
      'key_commitment', 'issued_at', 'envelopes', 'signature'};
    try {
      if (json.length != fields.length || !json.keys.toSet().containsAll(fields) ||
          json['purpose'] != 'seqpoint-membership-event-v1' || json['v'] is! int || json['v'] != 1 ||
          json['vault_id'] is! String ||
          RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(json['vault_id'] as String)?.end != (json['vault_id'] as String).length) {
        throw const FormatException();
      }
      for (final field in ['authority_id', 'event_id', 'issuer_id', 'parent_hash', 'key_commitment']) {
        parsePairingBytes(json[field], 32);
      }
      if (json['target_id'] != null) parsePairingBytes(json['target_id'], 32);
      for (final field in ['issuer_seq', 'epoch', 'issued_at']) {
        if (json[field] is! int || (json[field] as int) < (field == 'issued_at' ? 0 : 1) ||
            (json[field] as int) > 9007199254740991) {
          throw const FormatException();
        }
      }
      final subject = json['subject'] == null ? null : MemberKeys.fromJson(
          Map<String, Object?>.from(json['subject'] as Map));
      final envelopes = <String, MemberEpochEnvelope>{};
      for (final raw in json['envelopes'] as List) {
        final envelope = MemberEpochEnvelope.fromJson(Map<String, Object?>.from(raw as Map));
        if (envelopes.containsKey(envelope.recipientDeviceId)) throw const FormatException();
        envelopes[envelope.recipientDeviceId] = envelope;
      }
      final type = MembershipEventType.values.byName(json['type'] as String);
      if ((type == MembershipEventType.add) != (subject != null) ||
          (type == MembershipEventType.rotate) != (json['target_id'] == null) ||
          (subject != null && subject.deviceId != json['target_id'])) {
        throw const FormatException();
      }
      return MembershipEvent._(vaultPublicId: json['vault_id'] as String,
        authorityId: json['authority_id'] as String, eventId: json['event_id'] as String,
        issuerDeviceId: json['issuer_id'] as String, issuerSequence: json['issuer_seq'] as int,
        parentHash: json['parent_hash'] as String, type: type, targetDeviceId: json['target_id'] as String?,
        subject: subject, epoch: json['epoch'] as int, keyCommitment: json['key_commitment'] as String,
        issuedAt: json['issued_at'] as int, envelopes: envelopes,
        signature: parsePairingBytes(json['signature'], 64));
    } catch (_) { throw const FormatException('成员签名事件格式错误'); }
  }
  MembershipEvent._({required this.vaultPublicId, required this.authorityId,
    required this.eventId, required this.issuerDeviceId, required this.issuerSequence,
    required this.parentHash, required this.type, required this.targetDeviceId,
    required this.subject, required this.epoch, required this.keyCommitment,
    required this.issuedAt, required Map<String, MemberEpochEnvelope> envelopes,
    required List<int> signature,
  }) : envelopes = Map.unmodifiable(envelopes), signature = List.unmodifiable(signature);
  final String vaultPublicId, authorityId, eventId, issuerDeviceId, parentHash, keyCommitment;
  final String? targetDeviceId;
  final int issuerSequence, epoch, issuedAt;
  final MemberKeys? subject;
  final MembershipEventType type;
  final Map<String, MemberEpochEnvelope> envelopes;
  final List<int> signature;
  Map<String, MemberKeys> _recipients(MembershipState parent) {
    if (vaultPublicId != parent.vaultPublicId || authorityId != parent.authorityId ||
        parentHash != parent.headHash || !parent.members.containsKey(issuerDeviceId) ||
        issuerSequence != (parent.issuerSequences[issuerDeviceId] ?? 0) + 1) {
      throw StateError('成员事件未获父状态授权');
    }
    if (type == MembershipEventType.add) {
      if (subject == null || targetDeviceId != subject!.deviceId ||
          parent.members.containsKey(targetDeviceId) || parent.revokedIds.contains(targetDeviceId) ||
          epoch != parent.epoch || keyCommitment != parent.keyCommitment) {
        throw StateError('新增成员或Epoch无效');
      }
      return {subject!.deviceId: subject!};
    }
    if (subject != null || epoch != parent.epoch + 1 || parent.keyCommitments.contains(keyCommitment)) {
      throw StateError('后继Epoch或密钥承诺无效');
    }
    final members = Map<String, MemberKeys>.of(parent.members);
    if (type == MembershipEventType.revoke) {
      if (targetDeviceId == issuerDeviceId || members.remove(targetDeviceId) == null) {
        throw StateError('撤销目标无效或签发者自行撤销');
      }
    } else if (targetDeviceId != null) {
      throw StateError('轮换事件不能指定目标');
    }
    return members;
  }
  Future<void> _verify(MembershipState parent) async {
    final recipients = _recipients(parent);
    if (recipients.length != envelopes.length || !recipients.keys.toSet().containsAll(envelopes.keys)) {
      throw StateError('Epoch封装接收者集合不匹配');
    }
    await subject?.verifyIdentity();
    await parent.members[issuerDeviceId]!.verifySignature(signingBytes, signature);
  }
  Map<String, Object?> get context => {
    'purpose': 'seqpoint-membership-event-v1', 'v': 1,
    'vault_id': vaultPublicId, 'authority_id': authorityId,
    'event_id': eventId, 'issuer_id': issuerDeviceId, 'issuer_seq': issuerSequence,
    'parent_hash': parentHash, 'type': type.name, 'target_id': targetDeviceId,
    'subject': subject?.toJson(), 'epoch': epoch, 'key_commitment': keyCommitment,
    'issued_at': issuedAt,
  };
  List<int> get contextBytes => utf8.encode(jsonEncode(context));
  Map<String, Object?> get unsignedJson {
    final ids = envelopes.keys.toList()..sort();
    return {...context, 'envelopes': [for (final id in ids) envelopes[id]!.toJson()]};
  }
  List<int> get signingBytes => utf8.encode(jsonEncode(unsignedJson));
  Map<String, Object?> toJson() => {...unsignedJson,
    'signature': base64UrlEncode(signature).replaceAll('=', '')};
  Future<String> get eventHash async => base64UrlEncode(
      (await Sha256().hash(utf8.encode(jsonEncode(toJson())))).bytes).replaceAll('=', '');
}
