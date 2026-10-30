part of 'app_sync_service.dart';

extension _AppSyncPairing on AppSyncService {
  Future<PairingInvitation> _createInvitation() => _run(() async {
    _requirePrepared();
    if (_controller!.current?.isUsable != true || _snapshot() == null) {
      throw StateError('请先创建或加入有效Vault');
    }
    cancelPairing();
    return _invitation = await PairingInvitation.create(keys: _local!.keys,
        vaultPublicId: _controller!.current!.state.vaultPublicId,
        tlsFingerprint: _tls!.fingerprint);
  });

  Future<PairingHandshake> _respondToInvitation(Map<String, Object?> payload) =>
      _run(() async {
    _requirePrepared();
    _requireNormalMode();
    cancelPairing();
    final invitation = await PairingInvitation.fromQr(payload);
    final session = await PairingHandshake.respond(invitation: invitation,
        keys: _local!.keys, tlsFingerprint: _tls!.fingerprint);
    _sessions.add(session);
    return session;
  });

  Future<PairingHandshake> _acceptResponse(Map<String, Object?> payload) => _run(() async {
    _requirePrepared();
    final invitation = _invitation;
    if (invitation == null) throw StateError('请先创建本机邀请');
    final session = await PairingHandshake.acceptResponse(invitation: invitation,
        keys: _local!.keys, response: payload);
    _sessions.add(session);
    return session;
  });

  void _cancelPairing() {
    _hostRecovery = null;
    _invitation?.cancel(); _invitation = null;
    for (final session in _sessions) { session.cancel(); }
    _sessions.clear();
  }

  bool _sameMember(MemberKeys? member, PairingParticipant peer) => member != null &&
      member.deviceId == peer.deviceId && member.tlsFingerprint == peer.tlsFingerprint &&
      listEquals(member.signingPublicKey, peer.signingPublicKey) &&
      listEquals(member.exchangePublicKey, peer.exchangePublicKey);

  void _requireLocal(PairingParticipant peer, PairingHandshake session) {
    _requirePrepared();
    if (session.localDeviceId != _local!.keys.deviceId ||
        peer.deviceId != _local!.keys.deviceId || peer.tlsFingerprint != _tls!.fingerprint ||
        !listEquals(peer.signingPublicKey, _local!.keys.signer.publicKey) ||
        !listEquals(peer.exchangePublicKey, _local!.keys.exchangePublicKey)) {
      throw StateError('配对本机完整身份不匹配');
    }
  }

  Future<Map<String, Object?>> _finishHost(PairingHandshake session) => _run(() async {
    if (_hostRecovery != null) return _finishHostedRecovery(session);
    final transcript = session.response.transcript;
    _requireLocal(transcript.initiator, session);
    final controller = _controller!, current = _controller!.current;
    if (session.state != PairingHandshakeState.ready || _snapshot() == null ||
        current?.isUsable != true || current!.state.vaultPublicId != transcript.vaultPublicId ||
        !_sameMember(current.state.members[identity!.deviceId], transcript.initiator)) {
      throw StateError('配对会话或持久成员状态不匹配');
    }
    final guest = transcript.responder, known = current.state.members[transcript.responder.deviceId];
    if (current.state.revokedIds.contains(guest.deviceId) ||
        (known != null && !_sameMember(known, guest))) {
      throw StateError('对端已撤销或完整身份不匹配');
    }
    if (known == null) await _persistGuest(session);
    final saved = controller.current!;
    if (controller.state != SyncMembershipControllerState.ready || !saved.isUsable ||
        !_sameMember(saved.state.members[guest.deviceId], guest) ||
        !_sameMember(saved.state.members[identity!.deviceId], transcript.initiator)) {
      throw StateError('配对成员尚未安全保存');
    }
    _enableBaseline();
    final envelope = await session.sealEpoch(saved.epochKey!, checkpointHash: saved.state.headHash);
    return {'checkpoint': saved.state.toJson(), 'epoch_envelope': envelope};
  });

  Future<void> _persistGuest(PairingHandshake session) async {
    final controller = _controller!, current = _controller!.current!;
    final version = controller.version, guest = session.response.transcript.responder;
    final event = await MembershipEvent.create(parent: current.state, issuer: _local!.keys,
        type: MembershipEventType.add, epochKey: current.epochKey!,
        subject: MemberKeys(deviceId: guest.deviceId, signingPublicKey: guest.signingPublicKey,
            exchangePublicKey: guest.exchangePublicKey, tlsFingerprint: guest.tlsFingerprint));
    if (!identical(version, controller.version)) throw StateError('成员状态已变化，请重新配对');
    final path = 'members/${identity!.deviceId}.json';
    final own = MembershipFile.decode(controller.publishedControlFiles()[path]!,
        issuerFileDeviceId: identity!.deviceId, expectedVaultPublicId: current.state.vaultPublicId,
        expectedAuthorityId: current.state.authorityId);
    await controller.ingest(path: path, bytes: MembershipFile(
        vaultPublicId: own.vaultPublicId, authorityId: own.authorityId,
        issuerDeviceId: own.issuerDeviceId, events: [...own.events, event]).encode());
  }

  Future<void> _finishGuest(PairingHandshake session, Map<String, Object?> packet) =>
      _run(() async {
    _requireNormalMode();
    _requireLocal(session.response.transcript.responder, session);
    if (packet.length != 2 || packet['checkpoint'] is! Map || packet['epoch_envelope'] is! Map) {
      throw const FormatException('配对交付包格式错误');
    }
    final checkpoint = Map<String, Object?>.from(packet['checkpoint'] as Map);
    final key = await session.openEpoch(Map<String, Object?>.from(packet['epoch_envelope'] as Map));
    await _controller!.initializeFromPairing(session: session, checkpoint: checkpoint, epochKey: key);
    _enableBaseline();
  });
}
