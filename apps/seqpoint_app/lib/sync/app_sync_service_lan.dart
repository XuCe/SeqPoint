part of 'app_sync_service.dart';

extension _AppSyncLan on AppSyncService {
  Future<void> _loadLanTargets() async {
    final prefs = await SharedPreferences.getInstance();
    _lanEnabled = prefs.getBool('$_lanKey.enabled') ?? false;
    final saved = jsonDecode(prefs.getString('$_lanKey.peers') ?? '{}');
    if (saved is! Map<String, dynamic>) {
      throw const FormatException('局域网地址配置错误');
    }
    _lanPeers.clear();
    for (final entry in saved.entries) {
      final member = _authorize(relayVaultId!, entry.key);
      if (member == null) continue;
      final data = Map<String, Object?>.from(entry.value as Map);
      final host = data['host'] as String;
      final address = LanPairingAddress.parse(
        '${host.contains(':') ? '[$host]' : host}:${data['port']}',
      );
      _lanPeers[entry.key] = LanPeer(
        deviceId: entry.key,
        host: address.host,
        port: address.port,
        tlsFingerprint: member.tlsFingerprint,
      );
    }
  }

  Future<bool> _automaticRound() async {
    Object? failure;
    if (_lanEnabled) {
      try {
        await startServer(automatic: true);
      } catch (error) {
        failure = error;
      }
      for (final peer in _lanPeers.values.toList()) {
        if (_closed || _userPaused || _suspended || !_lanEnabled) break;
        if (_authorize(relayVaultId!, peer.deviceId) == null) continue;
        try {
          await syncOnce(
            peerDeviceId: peer.deviceId,
            host: peer.host,
            port: peer.port,
            automatic: true,
          );
        } catch (error) {
          failure = error;
        }
      }
    }
    if (_automaticEndpoint.isNotEmpty &&
        !_closed &&
        !_userPaused &&
        !_suspended) {
      try {
        await syncRelay(automatic: true);
      } catch (error) {
        failure = error;
      }
    }
    if (_syncthingEnabled && !_closed && !_userPaused && !_suspended) {
      try {
        await syncSyncthing(automatic: true);
      } catch (error) {
        failure = error;
      }
    }
    if (failure != null) throw failure;
    return (_runtime?.mediaPending ?? false) &&
        (_runtime?.mediaTransferredBytes ?? 0) > 0;
  }

  String get _lanKey =>
      'sync.lan.${identity!.deviceId}.${relayVaultId ?? 'unpaired'}';

  Future<void> _setLanEnabled(bool value) async {
    await _run(() async {
      _requirePrepared();
      if (!await (await SharedPreferences.getInstance()).setBool(
        '$_lanKey.enabled',
        value,
      )) {
        throw StateError('局域网同步设置保存失败');
      }
      _lanEnabled = value;
      if (!value) {
        await _runtime?.pause();
        _listeningPort = null;
        _paused = true;
      }
    });
    if (value && canSync) await startServer();
    if (!value) await _lanPairing?.close();
    await startAutomatic();
    await _refreshAutomaticTarget();
  }

  Future<void> _rememberLanPeer(LanPeer peer) async {
    await _run(() async {
      final member = _authorize(relayVaultId!, peer.deviceId);
      if (member == null || member.tlsFingerprint != peer.tlsFingerprint) {
        throw StateError('不能保存未经授权的局域网设备');
      }
      final targets = {..._lanPeers, peer.deviceId: peer};
      final json = jsonEncode({
        for (final entry in targets.entries)
          entry.key: {'host': entry.value.host, 'port': entry.value.port},
      });
      if (!await (await SharedPreferences.getInstance()).setString(
        '$_lanKey.peers',
        json,
      )) {
        throw StateError('局域网设备地址保存失败');
      }
      _lanPeers[peer.deviceId] = peer;
    });
    await _setLanEnabled(true);
  }
}
