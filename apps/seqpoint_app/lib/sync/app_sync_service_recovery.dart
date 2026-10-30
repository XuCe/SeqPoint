part of 'app_sync_service.dart';

extension _AppSyncRecovery on AppSyncService {
  Future<PairingInvitation> _createRecoveryInvitation() => _run(() async {
    _requirePrepared(); _requireNormalMode();
    if (!hasMembershipConflict || !_baselineReady) throw StateError('只有已核验的冲突控制状态可建立恢复授权域');
    cancelPairing();
    final old = _controller!.current!, random = Random.secure();
    final key = VaultKey(epoch: old.membership.maximumObservedEpoch + 1,
        keyBytes: List.generate(32, (_) => random.nextInt(256)));
    final anchor = await MembershipState.createVault(founder: _local!.keys,
        vaultPublicId: old.state.vaultPublicId, epochKey: key, tlsFingerprint: _tls!.fingerprint);
    _hostRecovery = (membership: MembershipReducer(trustedAnchor: anchor),
        key: key, version: _controller!.version);
    return _invitation = await PairingInvitation.create(keys: _local!.keys,
        vaultPublicId: _hostRecovery!.membership.state.vaultPublicId, tlsFingerprint: _tls!.fingerprint);
  });

  Future<Map<String, Object?>> _finishHostedRecovery(PairingHandshake session) async {
    final candidate = _hostRecovery!, transcript = session.response.transcript;
    _requireLocal(transcript.initiator, session);
    if (!_baselineReady || session.state != PairingHandshakeState.ready || !hasMembershipConflict ||
        !identical(candidate.version, _controller!.version)) {
      throw StateError('恢复会话或控制状态已变化');
    }
    final guest = transcript.responder;
    final add = await MembershipEvent.create(parent: candidate.membership.state, issuer: _local!.keys,
        type: MembershipEventType.add, epochKey: candidate.key,
        subject: MemberKeys(deviceId: guest.deviceId, signingPublicKey: guest.signingPublicKey,
            exchangePublicKey: guest.exchangePublicKey, tlsFingerprint: guest.tlsFingerprint));
    await candidate.membership.ingest(add, issuerFileDeviceId: _local!.keys.deviceId);
    final checkpoint = candidate.membership.state.toJson();
    final envelope = await session.sealEpoch(candidate.key, checkpointHash: candidate.membership.state.headHash);
    await _controller!.recoverFromHostedPairing(session: session,
        checkpoint: checkpoint, epochKey: candidate.key);
    _enableBaseline();
    await _runtime?.stop(); _runtime = null; _attachRuntime();
    _hostRecovery = null;
    return {'checkpoint': checkpoint, 'epoch_envelope': envelope};
  }

  Future<({Map<String, Object?> checkpoint, VaultKey key})> _recoveryPacket(
      PairingHandshake session, Map<String, Object?> packet) async {
    if (packet.length != 2 || packet['checkpoint'] is! Map || packet['epoch_envelope'] is! Map) {
      throw const FormatException('配对交付包格式错误');
    }
    final checkpoint = Map<String, Object?>.from(packet['checkpoint'] as Map);
    final key = await session.openEpoch(Map<String, Object?>.from(packet['epoch_envelope'] as Map));
    return (checkpoint: checkpoint, key: key);
  }

  void _requireRecoveryLocal(PairingHandshake session, LocalDeviceIdentity local) {
    final peer = session.response.transcript.responder;
    if (session.localDeviceId != local.keys.deviceId || peer.deviceId != local.keys.deviceId ||
        peer.tlsFingerprint != _tls!.fingerprint ||
        !listEquals(peer.signingPublicKey, local.keys.signer.publicKey) ||
        !listEquals(peer.exchangePublicKey, local.keys.exchangePublicKey)) {
      throw StateError('恢复配对本机完整身份不匹配');
    }
  }
  Future<DeviceIdentity> _beginIdentityRecovery(String name) => _run(() async {
    _requirePrepared();
    if (!_requiresNewIdentity) throw StateError('当前资料不需要更换恢复身份');
    cancelPairing(); _recoveryIdentity = null; _recoveryPreviousId = null;
    await _runtime?.stop(); _runtime = null; _baselineReady = false;
    final writer = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if (writer['requires_new_identity'] != 1) throw StateError('恢复状态已变化');
    final previous = writer['device_id'] as String? ?? _local!.keys.deviceId;
    final fresh = await SyncIdentityStore(secrets).createRecoveryIdentity(name);
    _recoveryPreviousId = previous; _recoveryIdentity = fresh;
    return fresh.identity;
  });

  Future<PairingHandshake> _respondToRecoveryInvitation(Map<String, Object?> payload) =>
      _run(() async {
    final local = _requiresNewIdentity ? _recoveryIdentity : (hasMembershipConflict ? _local : null);
    if (local == null || (!_requiresNewIdentity && !_baselineReady)) {
      throw StateError('请创建全新恢复身份或重新核验控制状态');
    }
    cancelPairing();
    final invitation = await PairingInvitation.fromQr(payload);
    final session = await PairingHandshake.respond(invitation: invitation,
        keys: local.keys, tlsFingerprint: _tls!.fingerprint);
    _sessions.add(session);
    return session;
  });

  Future<void> _finishIdentityRecovery(PairingHandshake session, Map<String, Object?> packet) =>
      _run(() async {
    final pending = _recoveryIdentity, previousId = _recoveryPreviousId;
    if (!_requiresNewIdentity || pending == null || previousId == null) {
      throw StateError('请显式创建全新恢复身份');
    }
    final local = await SyncIdentityStore(secrets).loadForDevice(pending.keys.deviceId);
    _requireRecoveryLocal(session, local);
    final material = await _recoveryPacket(session, packet);
    final anchor = await MembershipState.fromConfirmedPairing(
        session: session, checkpoint: material.checkpoint);
    await _membershipStore(local).save(membership: MembershipReducer(trustedAnchor: anchor),
        localDevice: local.keys, epochKey: material.key);
    SyncBaseline(db).initializeRestored(local.keys.deviceId, previousDeviceId: previousId);
    await _selectLocal(local);
    await _prepare(local.identity.name);
    _recoveryIdentity = null; _recoveryPreviousId = null;
  });

  Future<void> _recoverFromPairing(PairingHandshake session, Map<String, Object?> packet) =>
      _run(() async {
    _requirePrepared(); _requireNormalMode();
    if (!hasMembershipConflict || !_baselineReady) throw StateError('只有已核验的冲突控制状态可显式恢复');
    _requireRecoveryLocal(session, _local!);
    final material = await _recoveryPacket(session, packet);
    await _controller!.recoverFromPairing(session: session,
        checkpoint: material.checkpoint, epochKey: material.key);
    _enableBaseline();
    await _runtime?.stop(); _runtime = null; _attachRuntime();
  });
}
