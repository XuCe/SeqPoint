part of 'app_sync_service.dart';

extension _AppSyncRevocation on AppSyncService {
  Object? _revocationVersion() {
    if (_closed || !prepared || _requiresNewIdentity || !_baselineReady) return null;
    final snapshot = _snapshot();
    if (snapshot == null) return null;
    final state = snapshot.policy.membership.state;
    if (!snapshot.epochKeys.containsKey(state.epoch) ||
        _authorize(state.vaultPublicId, _local!.keys.deviceId) == null) {
      return null;
    }
    final writer = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if (writer['enabled'] != 1 || writer['baseline_ready'] != 1 ||
        writer['requires_new_identity'] != 0 || writer['device_id'] != _local!.keys.deviceId) {
      return null;
    }
    return snapshot.version;
  }

  Future<void> _revokePeer(MemberKeys expectedPeer, Object expectedVersion) =>
      _run(() async {
    if (!identical(_revocationVersion(), expectedVersion)) {
      throw StateError('成员状态已变化，请重新确认撤销');
    }
    final controller = _controller!, local = _local!;
    final parent = _snapshot()!.policy.membership.state;
    final peer = controller.authorize(parent.vaultPublicId, expectedPeer.deviceId);
    if (peer == null || peer.deviceId == local.keys.deviceId ||
        peer.tlsFingerprint != expectedPeer.tlsFingerprint ||
        !listEquals(peer.signingPublicKey, expectedPeer.signingPublicKey) ||
        !listEquals(peer.exchangePublicKey, expectedPeer.exchangePublicKey)) {
      throw StateError('撤销目标已变化、无效或是本机');
    }
    final event = await MembershipEvent.create(parent: parent, issuer: local.keys,
        type: MembershipEventType.revoke, targetDeviceId: peer.deviceId);
    if (!identical(_controller, controller) || !identical(_local, local) ||
        !identical(_revocationVersion(), expectedVersion) ||
        _snapshot()!.policy.membership.state.headHash != parent.headHash) {
      throw StateError('撤销期间成员状态已变化，请重新确认');
    }
    final path = 'members/${local.keys.deviceId}.json';
    final bytes = controller.publishedControlFiles()[path];
    if (bytes == null) throw StateError('缺少已持久成员目录');
    final own = MembershipFile.decode(bytes, issuerFileDeviceId: local.keys.deviceId,
        expectedVaultPublicId: parent.vaultPublicId, expectedAuthorityId: parent.authorityId);
    await controller.ingest(path: path, bytes: MembershipFile(
        vaultPublicId: own.vaultPublicId, authorityId: own.authorityId,
        issuerDeviceId: own.issuerDeviceId, events: [...own.events, event]).encode());
    _lastRound = null;
    _cancelPairing();
  });
}
