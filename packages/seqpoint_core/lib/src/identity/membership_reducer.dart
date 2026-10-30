part of 'membership_state.dart';

enum MembershipApplyResult { applied, waiting, duplicate, conflict }

/// 公开授权先归约；解封本机密钥不能推迟撤销或替分叉选择胜者。
final class MembershipReducer {
  static Future<MembershipReducer> recoverFromConfirmedPairing({required MembershipReducer previous,
    required PairingHandshake session, required Map<String, Object?> checkpoint,
  }) => _recoverFromCompletedPairing(previous: previous, session: session,
      checkpoint: checkpoint, hosted: false);
  static Future<MembershipReducer> recoverFromHostedPairing({required MembershipReducer previous,
    required PairingHandshake session, required Map<String, Object?> checkpoint,
  }) => _recoverFromCompletedPairing(previous: previous, session: session,
      checkpoint: checkpoint, hosted: true);
  static Future<MembershipReducer> _recoverFromCompletedPairing({required MembershipReducer previous,
    required bool hosted,
    required PairingHandshake session, required Map<String, Object?> checkpoint,
  }) async {
    final before = jsonEncode(previous.toTrustedLocalJson());
    final prior = await restoreTrustedLocal(Map<String, Object?>.from(jsonDecode(before) as Map));
    if (!prior.isConflicted) throw StateError('只有冲突控制状态可显式恢复');
    final recovered = hosted
        ? await MembershipState.fromHostedPairing(session: session, checkpoint: checkpoint)
        : await MembershipState.fromConfirmedPairing(session: session, checkpoint: checkpoint);
    final transcript = session.response.transcript;
    if (recovered.vaultPublicId != prior.state.vaultPublicId ||
        prior._allAuthorityIds.contains(recovered.authorityId) || recovered.members.length != 2 ||
        !recovered.members.keys.toSet().containsAll({transcript.initiator.deviceId, transcript.responder.deviceId}) ||
        recovered.epoch <= prior.maximumObservedEpoch ||
        prior._allCommitments.contains(recovered.keyCommitment)) {
      throw StateError('恢复需要新授权域、更高Epoch、新密钥和本次双方确认名单');
    }
    if (before != jsonEncode(previous.toTrustedLocalJson())) {
      throw StateError('恢复期间旧控制状态已变更，请重新确认');
    }
    final result = MembershipReducer(trustedAnchor: recovered);
    result._isolated.add(prior);
    return result;
  }
  Set<String> get _allAuthorityIds => {
    state.authorityId,
    for (final previous in _isolated) ...previous._allAuthorityIds,
  };
  Set<String> get _allCommitments => {
    for (final state in _states.values) ...state.keyCommitments,
    for (final previous in _isolated) ...previous._allCommitments,
  };
  /// 仅从系统安全存储读取的控制记录恢复；普通网络成员文件不具备可信锚。
  static Future<MembershipReducer> restoreTrustedLocal(Map<String, Object?> source) async {
    final json = Map<String, Object?>.from(jsonDecode(jsonEncode(source)) as Map);
    const fields = {'v', 'anchor', 'anchor_hash', 'state_hash', 'conflicted', 'facts', 'pending', 'isolated'};
    if (json.length != fields.length || !json.keys.toSet().containsAll(fields) ||
        json['v'] is! int || json['v'] != 1 || json['conflicted'] is! bool) {
      throw const FormatException('本机成员控制记录格式错误');
    }
    final anchor = await MembershipState.restoreTrustedLocal(
        Map<String, Object?>.from(json['anchor'] as Map), expectedHeadHash: json['anchor_hash'] as String);
    final result = MembershipReducer(trustedAnchor: anchor);
    for (final raw in json['isolated'] as List) {
      final previous = await restoreTrustedLocal(Map<String, Object?>.from(raw as Map));
      if (!previous.isConflicted || previous.state.vaultPublicId != anchor.vaultPublicId ||
          previous._allAuthorityIds.contains(anchor.authorityId) || anchor.epoch <= previous.maximumObservedEpoch ||
          previous._allCommitments.contains(anchor.keyCommitment)) {
        throw const FormatException('隔离授权域与恢复检查点不一致');
      }
      result._isolated.add(previous);
    }
    for (final raw in json['facts'] as List) {
      final event = MembershipEvent.fromJson(Map<String, Object?>.from(raw as Map));
      final applied = await result.ingest(event, issuerFileDeviceId: event.issuerDeviceId);
      if (applied == MembershipApplyResult.waiting || applied == MembershipApplyResult.duplicate ||
          !result._facts.containsKey(event.eventId)) {
        throw const FormatException('本机签名事实链不完整');
      }
    }
    for (final raw in json['pending'] as List) {
      final event = MembershipEvent.fromJson(Map<String, Object?>.from(raw as Map));
      final applied = await result.ingest(event, issuerFileDeviceId: event.issuerDeviceId);
      if (applied != MembershipApplyResult.waiting && applied != MembershipApplyResult.conflict) {
        throw const FormatException('本机待定事件状态不一致');
      }
    }
    if (result.state.headHash != json['state_hash'] || result.isConflicted != json['conflicted']) {
      throw StateError('本机成员控制记录重放不一致');
    }
    return result;
  }
  MembershipReducer({required MembershipState trustedAnchor})
      : _state = trustedAnchor, _trustedAnchor = trustedAnchor {
    _states[trustedAnchor.headHash] = trustedAnchor;
  }
  MembershipState _state;
  final MembershipState _trustedAnchor;
  final _isolated = <MembershipReducer>[];
  List<Map<String, Object?>> get isolatedControlRecords =>
      List.unmodifiable(_isolated.map((entry) => entry.toTrustedLocalJson()));
  MembershipState get state => _state;
  bool get isConflicted => _conflict;
  bool _conflict = false;
  final _states = <String, MembershipState>{};
  final _facts = <String, MembershipEvent>{};
  final _sequences = <String, String>{};
  final _children = <String, String>{};
  final _pending = <String, MembershipEvent>{};
  Future<void> _tail = Future<void>.value();
  List<MembershipEvent> get pendingEvents => List.unmodifiable(_pending.values);
  List<MembershipEvent> get evidence => List.unmodifiable(_facts.values);
  MemberKeys? knownMemberKeys(String deviceId) {
    for (final entry in _states.values) {
      final member = entry.members[deviceId];
      if (member != null) return member;
    }
    return null;
  }
  /// 同步生成完整一致快照；不等待正在验证的消息，已接受事实始终在同一记录内。
  Map<String, Object?> toTrustedLocalJson() => {
    'v': 1, 'anchor': _trustedAnchor.toJson(), 'anchor_hash': _trustedAnchor.headHash,
    'state_hash': state.headHash, 'conflicted': _conflict,
    'facts': [for (final event in _facts.values) event.toJson()],
    'pending': [for (final event in _pending.values) event.toJson()],
    'isolated': [for (final entry in _isolated) entry.toTrustedLocalJson()],
  };
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
  Future<MembershipApplyResult> ingest(MembershipEvent event,
      {required String issuerFileDeviceId}) => _enqueue(() async {
    if (issuerFileDeviceId != event.issuerDeviceId) throw StateError('成员文件签发者不匹配');
    if (event.vaultPublicId != state.vaultPublicId || event.authorityId != state.authorityId) {
      throw StateError('成员事件Vault或授权域不匹配');
    }
    return _ingest(event);
  });
  Future<MembershipApplyResult> _ingest(MembershipEvent event, {bool drain = true}) async {
    final hash = await event.eventHash;
    final previous = _facts[event.eventId] ?? _pending[event.eventId];
    if (previous != null) {
      if (await previous.eventHash != hash) throw StateError('成员事件ID碰撞');
      return MembershipApplyResult.duplicate;
    }
    final slot = '${event.issuerDeviceId}:${event.issuerSequence}';
    if (_pending.values.any((entry) => entry.issuerDeviceId == event.issuerDeviceId &&
        entry.issuerSequence == event.issuerSequence)) {
      throw StateError('待定成员签发序号碰撞');
    }
    if (_sequences.containsKey(slot) && _sequences[slot] != hash) {
      throw StateError('成员签发序号碰撞');
    }
    final parent = _states[event.parentHash];
    if (_conflict || parent == null) {
      _pending[event.eventId] = event;
      return _conflict ? MembershipApplyResult.conflict : MembershipApplyResult.waiting;
    }
    if (event.type != MembershipEventType.add && _allCommitments.contains(event.keyCommitment)) {
      throw StateError('新Epoch不能复用已观察授权域的密钥');
    }
    final next = await parent._apply(event);
    _facts[event.eventId] = event;
    _sequences[slot] = hash;
    _states[next.headHash] = next;
    final sibling = _children[event.parentHash];
    if (sibling != null && sibling != hash) {
      _conflict = true;
      return MembershipApplyResult.conflict;
    }
    _children[event.parentHash] = hash;
    _state = next;
    if (drain) await _drain();
    return _conflict ? MembershipApplyResult.conflict : MembershipApplyResult.applied;
  }
  final _rejected = <MembershipEvent>[];
  List<MembershipEvent> get rejectedEvents => List.unmodifiable(_rejected);
  Future<void> _drain() async {
    while (!_conflict) {
      final ready = _pending.values.where((e) => _states.containsKey(e.parentHash)).firstOrNull;
      if (ready == null) return;
      _pending.remove(ready.eventId);
      try { await _ingest(ready, drain: false); }
      catch (_) { _rejected.add(ready); }
    }
  }
  bool isMemberAuthorized(String deviceId) => !_conflict && state.members.containsKey(deviceId);
  int get maximumObservedEpoch => _states.values.fold(state.epoch,
      (largest, entry) => entry.epoch > largest ? entry.epoch : largest);
  Future<VaultKey?> openCurrentEpoch({required DeviceKeys localDevice}) async {
    final snapshot = state;
    final recipient = snapshot.members[localDevice.deviceId];
    if (_conflict || recipient == null) return null;
    if (base64Encode(localDevice.signer.publicKey) != base64Encode(recipient.signingPublicKey) ||
        base64Encode(localDevice.exchangePublicKey) != base64Encode(recipient.exchangePublicKey)) {
      throw StateError('本机成员密钥不匹配');
    }
    var cursor = snapshot;
    while (cursor.parentHash != null) {
      final parent = _states[cursor.parentHash];
      if (parent == null) return null;
      final event = _facts.values.where((entry) => entry.parentHash == parent.headHash &&
          entry.keyCommitment == snapshot.keyCommitment && entry.epoch == snapshot.epoch &&
          entry.envelopes.containsKey(localDevice.deviceId)).firstOrNull;
      if (event != null) {
        final key = await event.envelopes[localDevice.deviceId]!.open(recipient: localDevice,
          senderIdentity: parent.members[event.issuerDeviceId]!, recipientIdentity: recipient,
          context: event.contextBytes, epoch: snapshot.epoch);
        final commitment = await epochKeyCommitment(vaultPublicId: snapshot.vaultPublicId, keyBytes: key.keyBytes);
        if (_conflict || state.headHash != snapshot.headHash || commitment != snapshot.keyCommitment) {
          throw StateError('本机Epoch密钥承诺或当前授权状态已变更');
        }
        return key;
      }
      cursor = parent;
    }
    return null;
  }
}
