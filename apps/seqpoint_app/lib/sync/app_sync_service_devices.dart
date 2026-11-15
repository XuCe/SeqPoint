part of 'app_sync_service.dart';

/// 设备名称，以及同步网关记下的各设备出口 IP 与地区。
///
/// 名称存在本机安全身份里；同步时顺带报给网关，其他设备从网关读取。
/// 全部是尽力而为：旧网关或断网时只是不显示，不影响同步。
extension _AppSyncDevices on AppSyncService {
  static const _presenceInterval = Duration(minutes: 5);

  GatewayDeviceInfo? _gatewayDevice(String deviceId) =>
      _gatewayDevicesVault != null && _gatewayDevicesVault == relayVaultId
          ? _gatewayDevices[deviceId] : null;

  bool get _presenceStale => _presenceAt == null ||
      DateTime.now().difference(_presenceAt!) > _presenceInterval;

  Future<void> _refreshGatewayDevices() async {
    final running = _presence;
    if (running != null) return running;
    final next = _presence = _reportPresence();
    try {
      await next;
    } catch (_) {
      // 网关不支持或网络不通时保持上次结果。
    } finally {
      if (identical(_presence, next)) _presence = null;
    }
  }

  Future<void> _reportPresence() async {
    final local = _local, vault = relayVaultId;
    if (_closed || local == null || vault == null || !canSync) return;
    final origin = await gatewayOrigin();
    if (origin == null || _closed) return;
    final client = RelayTransport(endpoint: origin, vaultPublicId: vault, keys: local.keys);
    try {
      final result = await client.devices(name: local.identity.name);
      _presenceAt = DateTime.now();
      if (result case Ok<List<GatewayDeviceInfo>>(:final value)
          when !_closed && relayVaultId == vault) {
        _gatewayDevices = {for (final device in value) device.deviceId: device};
        _gatewayDevicesVault = vault;
        _notifyDevices();
      }
    } finally {
      client.close();
    }
  }

  Future<void> _renameDevice(String value) async {
    final name = SyncIdentityStore.normalizeName(value);
    if (name == null) throw const FormatException('设备名称需为 1–64 个字符，且不能换行');
    await _run(() async {
      _requirePrepared();
      final local = _local!;
      if (local.identity.name == name) return;
      final renamed = await SyncIdentityStore(secrets).rename(local.keys.deviceId, name);
      if (!identical(_local, local)) throw StateError('设备身份已变化，请重试');
      _local = LocalDeviceIdentity(renamed.identity, local.keys,
          isRecoveryIdentity: local.isRecoveryIdentity);
    });
    final running = _presence;
    if (running != null) await running.catchError((Object _) {});
    await _refreshGatewayDevices();
  }
}
