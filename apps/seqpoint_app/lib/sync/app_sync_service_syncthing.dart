part of 'app_sync_service.dart';

typedef _SyncthingSettings = ({
  String address,
  String apiKey,
  String deviceId,
  String revision,
});

extension _AppSyncSyncthing on AppSyncService {
  Future<SyncOutcome> _syncSyncthing({required bool automatic}) => _run(
    () async {
      _requireSyncthing();
      if (automatic) {
        if (_closed || _userPaused || _suspended || !_automaticEnabled) {
          throw StateError('自动同步已暂停');
        }
      } else {
        await _resumeManual();
      }
      try {
        final config = await _loadSyncthingTarget();
        if (!_syncthingEnabled) throw StateError('请先开启跨网同步');
        if (config == null) throw StateError('请先保存 NAS 配置');
        final endpoint = await engineHost!.start();
        if (_syncthingSession != endpoint.baseUrl) {
          await _configureSyncthing(
            config.address,
            config.apiKey,
            expectedNasId: config.deviceId,
          );
          if (!await _activateSyncthing(config)) throw StateError('同步已暂停');
        } else {
          // NAS replaces device arrays; a concurrent setup can overwrite membership.
          await SyncthingClient(
            EngineEndpoint(baseUrl: config.address, apiKey: config.apiKey),
          ).shareVault(
            localDeviceId: (await engineHost!.localDeviceId())!,
            folderId: _syncthingFolderId,
            expectedNasId: config.deviceId,
          );
        }
        if (_closed ||
            (automatic && (_userPaused || _suspended || !_automaticEnabled))) {
          throw StateError('自动同步已暂停');
        }
        if (_paused) {
          _runtime!.resume();
          _paused = false;
        }
        final result = await _runtime!.syncFolder(
          FolderTransport(_syncthingFolder, writerDeviceId: identity!.deviceId),
        );
        if (result is! Ok<SyncOutcome>) throw StateError('加密目录同步未完成');
        _lastRound = result.value;
        final api = SyncthingClient(endpoint);
        if (result.value.pushed > 0) {
          await api.request('POST', 'db/scan?folder=$_syncthingFolderId');
        }
        await _syncthingStatus(api, config.deviceId, result.value);
        return result.value;
      } catch (_) {
        _syncthingMessage = '跨网同步未完成，请检查 NAS 管理接口、密钥和传输连接';
        await _stopSyncthing();
        rethrow;
      }
    },
  );
  void _requireSyncthing() {
    if (!syncthingSupported ||
        !canSync ||
        !verifiedPeers.any(
          (peer) =>
              _controller!.authorize(relayVaultId!, peer.deviceId) != null,
        )) {
      throw StateError('请先在局域网完成设备配对');
    }
  }

  Future<String> _configureSyncthing(
    String address,
    String apiKey, {
    String? expectedNasId,
  }) async {
    _requireSyncthing();
    final key = _syncthingKey, version = membershipVersion;
    void ensure() {
      if (_closed ||
          key != _syncthingKey ||
          version != membershipVersion ||
          !canSync) {
        throw StateError('同步身份已改变');
      }
    }

    final endpoint = await engineHost!.start();
    final localId = (await engineHost!.localDeviceId())!;
    ensure();
    final nas = SyncthingClient(
      EngineEndpoint(baseUrl: address, apiKey: apiKey),
    );
    final remote = await nas.shareVault(
      localDeviceId: localId,
      folderId: _syncthingFolderId,
      expectedNasId: expectedNasId,
    );
    ensure();
    await _syncthingFolder.create(recursive: true);
    ensure();
    await engineHost!.configure(
      vaultFolderPath: _syncthingFolder.path,
      vaultFolderId: _syncthingFolderId,
      peerDeviceIds: [remote.deviceId],
      paused: true,
    );
    await SyncthingClient(endpoint).request(
      'PATCH',
      'config/devices/${remote.deviceId}',
      {'addresses': remote.addresses},
    );
    ensure();
    _syncthingSession = endpoint.baseUrl;
    return remote.deviceId;
  }

  Future<void> _stopSyncthing() async {
    await engineHost?.stop();
    _syncthingSession = null;
  }

  Future<bool> _activateSyncthing(_SyncthingSettings config) async {
    bool blocked() => _closed || _userPaused || _suspended;
    if (blocked()) {
      await _stopSyncthing();
      return false;
    }
    final api = SyncthingClient(await engineHost!.start());
    if (blocked()) {
      await _stopSyncthing();
      return false;
    }
    await api.request('PATCH', 'config/devices/${config.deviceId}', {
      'paused': false,
    });
    if (blocked()) {
      await _stopSyncthing();
      return false;
    }
    await api.request('PATCH', 'config/folders/$_syncthingFolderId', {
      'paused': false,
    });
    if (blocked()) {
      await _stopSyncthing();
      return false;
    }
    return true;
  }

  Future<void> _syncthingStatus(
    SyncthingClient api,
    String nasId,
    SyncOutcome outcome,
  ) async {
    final connections = await api.request('GET', 'system/connections') as Map;
    final connected =
        (connections['connections'] as Map)[nasId]?['connected'] == true;
    final folder =
        await api.request('GET', 'db/status?folder=$_syncthingFolderId') as Map;
    if (folder['state'] == 'error' ||
        ((folder['pullErrors'] as num?) ?? 0) > 0) {
      throw StateError('Syncthing 目录传输异常');
    }
    _syncthingMessage = connected
        ? '已连接 NAS；本轮合并 ${outcome.pulled} 条更改'
        : '已写入加密目录，等待 NAS 传输连接';
    if (mediaPending || outcome.waitingPeers.isNotEmpty) {
      _syncthingMessage += '；仍有数据待补齐';
    }
  }

  Future<void> _setSyncthingEnabled(bool enabled) => _run(() async {
    final key = _syncthingKey;
    if (key == null) throw StateError('请先完成设备配对');
    final config = enabled ? await _readSyncthing() : null;
    if (enabled) {
      _requireSyncthing();
      if (config == null) throw StateError('请先保存 NAS 配置');
    }
    _syncthingEnabled = false;
    await _stopSyncthing();
    final prefs = await SharedPreferences.getInstance();
    try {
      if (!await prefs.setString(
        '$key.enabledRevision',
        enabled ? config!.revision : '',
      )) {
        throw StateError('Syncthing 启用状态保存失败');
      }
    } catch (_) {
      await prefs.reload();
      rethrow;
    }
    _syncthingEnabled = enabled;
    if (enabled) {
      await _refreshAutomaticTarget();
      _automatic?.request();
    } else {
      await _stopSyncthing();
      _syncthingMessage = '跨网同步已关闭';
    }
  });

  Future<void> _saveSyncthing({
    required String address,
    required String apiKey,
  }) => _run(() async {
    _requireSyncthing();
    final normalized = SyncthingClient.parseAddress(address);
    final previous = await _readSyncthing();
    final key = apiKey.trim().isNotEmpty
        ? apiKey.trim()
        : previous?.address == normalized
        ? previous!.apiKey
        : '';
    if (key.isEmpty ||
        key.length > 4096 ||
        !RegExp(r'^[!-~]+$').hasMatch(key)) {
      throw StateError('首次配置或更换地址时请输入 API Key');
    }
    final storageKey = _syncthingKey!;
    try {
      final deviceId = await _configureSyncthing(
        normalized,
        key,
        expectedNasId: previous?.address == normalized
            ? previous?.deviceId
            : null,
      );
      final random = Random.secure();
      final revision = base64UrlEncode(
        List.generate(32, (_) => random.nextInt(256)),
      ).replaceAll('=', '');
      final configured = (
        address: normalized,
        apiKey: key,
        deviceId: deviceId,
        revision: revision,
      );
      final record = jsonEncode({
        'revision': revision,
        'v': 1,
        'address': configured.address,
        'api_key': configured.apiKey,
        'nas_id': configured.deviceId,
      });
      await secrets.write(storageKey, record);
      if (await secrets.read(storageKey) != record ||
          storageKey != _syncthingKey ||
          !canSync) {
        throw StateError('Syncthing 安全配置保存失败');
      }
      if (!await (await SharedPreferences.getInstance()).setString(
        '$storageKey.enabledRevision',
        revision,
      )) {
        throw StateError('Syncthing 启用状态保存失败');
      }
      _syncthingEnabled = true;
      _syncthingMessage = await _activateSyncthing(configured)
          ? '设备与目录已授权，等待 Syncthing 建立传输连接'
          : '配置已保存，同步保持暂停';
      await _refreshAutomaticTarget();
      _automatic?.request();
    } catch (_) {
      _syncthingEnabled = false;
      await _stopSyncthing();
      await (await SharedPreferences.getInstance()).reload();
      rethrow;
    }
  });

  String? get _syncthingKey => identity == null || relayVaultId == null
      ? null
      : 'sync.syncthing.${identity!.deviceId}.$relayVaultId';
  String get _syncthingFolderId =>
      'seqpoint-${lanSha256(utf8.encode(relayVaultId!))}';
  Directory get _syncthingFolder =>
      Directory('${root.parent.path}/syncthing-folders/$_syncthingFolderId');

  Future<_SyncthingSettings?> _readSyncthing() async {
    final key = _syncthingKey;
    if (key == null || engineHost == null) return null;
    final stored = await secrets.read(key);
    if (stored == null) return null;
    try {
      if (stored.length > 16384) throw const FormatException();
      final data = jsonDecode(stored) as Map;
      if (data['v'] != 1) throw const FormatException();
      final address = SyncthingClient.parseAddress(data['address'] as String);
      final apiKey = data['api_key'] as String;
      final deviceId = data['nas_id'] as String;
      final revision = data['revision'] as String;
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(revision)) {
        throw const FormatException();
      }
      if (apiKey.isEmpty ||
          apiKey.length > 4096 ||
          !RegExp(r'^[!-~]+$').hasMatch(apiKey) ||
          !RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(deviceId)) {
        throw const FormatException();
      }
      return (
        address: address,
        apiKey: apiKey,
        deviceId: deviceId,
        revision: revision,
      );
    } catch (_) {
      throw StateError('Syncthing 安全配置损坏，请重新配置');
    }
  }

  Future<_SyncthingSettings?> _loadSyncthingTarget() async {
    _syncthingEnabled = false;
    final key = _syncthingKey;
    if (!syncthingSupported || key == null) return null;
    final config = await _readSyncthing();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final committed = prefs.getString('$key.enabledRevision');
    _syncthingEnabled = config != null && config.revision == committed;
    return config;
  }
}
