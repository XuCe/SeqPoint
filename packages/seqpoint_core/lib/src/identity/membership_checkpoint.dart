part of 'membership_state.dart';

Set<String> _checkpointIds(Object? raw) {
  final ids = <String>{};
  for (final entry in raw as List) {
    parsePairingBytes(entry, 32);
    if (!ids.add(entry as String)) throw const FormatException('检查点重复条目');
  }
  if (jsonEncode(ids.toList()) != jsonEncode(ids.toList()..sort())) {
    throw const FormatException('检查点条目顺序不规范');
  }
  return ids;
}

Future<MembershipState> _finishCheckpoint(Map<String, Object?> json, String hash,
    Map<String, MemberKeys> members, Set<String> revoked, Set<String> commitments,
    Map<String, int> sequences) async {
  if (members.isEmpty || members.keys.any(revoked.contains) ||
      !commitments.contains(json['key_commitment']) ||
      sequences.keys.any((id) => !members.containsKey(id) && !revoked.contains(id)) ||
      (json['parent_hash'] == null &&
          (members.length != 1 || revoked.isNotEmpty || sequences.isNotEmpty || commitments.length != 1))) {
    throw const FormatException('检查点成员与历史不一致');
  }
  for (final member in members.values) { await member.verifyIdentity(); }
  final result = MembershipState._(vaultPublicId: json['vault_id'] as String,
    authorityId: json['authority_id'] as String, epoch: json['epoch'] as int,
    keyCommitment: json['key_commitment'] as String, parentHash: json['parent_hash'] as String?,
    eventHash: json['event_hash'] as String?, members: members, revokedIds: revoked,
    issuerSequences: sequences, keyCommitments: commitments);
  for (final field in ['members', 'revoked', 'issuer_seq', 'key_commitments']) {
    if (jsonEncode(json[field]) != jsonEncode(result.toJson()[field])) {
      throw const FormatException('检查点集合编码不规范');
    }
  }
  result._headHash = base64UrlEncode((await Sha256().hash(
      utf8.encode(jsonEncode(result.toJson())))).bytes).replaceAll('=', '');
  if (result.headHash != hash) throw StateError('可信检查点hash不匹配');
  return result;
}

Future<MembershipState> _restoreMembershipCheckpoint(
    Map<String, Object?> source, String expectedHeadHash) async {
  final json = Map<String, Object?>.from(jsonDecode(jsonEncode(source)) as Map);
  const fields = {'purpose', 'v', 'vault_id', 'authority_id', 'epoch', 'key_commitment',
    'parent_hash', 'event_hash', 'members', 'revoked', 'issuer_seq', 'key_commitments'};
  if (json.length != fields.length || !json.keys.toSet().containsAll(fields) ||
      json['purpose'] != CryptoSpec.infoMembershipState || json['v'] is! int || json['v'] != 1 ||
      json['epoch'] is! int || (json['epoch'] as int) < 1 || (json['epoch'] as int) > 9007199254740991 ||
      json['vault_id'] is! String || RegExp(r'^[A-Za-z0-9_-]{1,128}$')
          .firstMatch(json['vault_id'] as String)?.end != (json['vault_id'] as String).length) {
    throw const FormatException('可信成员检查点格式错误');
  }
  for (final key in ['authority_id', 'key_commitment']) { parsePairingBytes(json[key], 32); }
  parsePairingBytes(expectedHeadHash, 32);
  if ((json['parent_hash'] == null) != (json['event_hash'] == null)) {
    throw const FormatException('检查点因果引用不完整');
  }
  if (json['parent_hash'] != null) {
    parsePairingBytes(json['parent_hash'], 32); parsePairingBytes(json['event_hash'], 32);
  }
  final members = <String, MemberKeys>{};
  for (final raw in json['members'] as List) {
    final member = MemberKeys.fromJson(Map<String, Object?>.from(raw as Map));
    if (members.containsKey(member.deviceId)) throw const FormatException('检查点重复成员');
    members[member.deviceId] = member;
  }
  final revoked = _checkpointIds(json['revoked']);
  final commitments = _checkpointIds(json['key_commitments']);
  final sequences = <String, int>{};
  for (final raw in json['issuer_seq'] as List) {
    if (raw is! List || raw.length != 2 || raw[0] is! String || raw[1] is! int ||
        (raw[1] as int) < 1 || (raw[1] as int) > 9007199254740991 || sequences.containsKey(raw[0])) {
      throw const FormatException('检查点签发序号无效');
    }
    parsePairingBytes(raw[0], 32);
    sequences[raw[0] as String] = raw[1] as int;
  }
  return _finishCheckpoint(json, expectedHeadHash, members, revoked, commitments, sequences);
}
