import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'sync_identity_store.dart';
import 'sync_membership_controller.dart';
import 'sync_membership_store.dart';
import 'sync_tls_store.dart';
import 'device_join_link.dart';
import 'gateway_mailbox.dart';
import 'hosted_invite.dart';

part 'app_sync_service_pairing.dart';
part 'app_sync_service_recovery.dart';
part 'app_sync_service_revocation.dart';
part 'app_sync_service_automatic.dart';
part 'app_sync_service_join.dart';

/// Main-engine owner; construction does not touch storage or the network.
///
/// 同步只有一种方式：序点同步网关。第一台设备粘贴服务器邀请，
/// 其他设备用已连接设备给出的一次性加入链接，经网关完成加密配对后自动登记。
class AppSyncService extends ChangeNotifier {
  AppSyncService({required this.db, required this.root, required this.secrets,
      this.onCommittedChange});
  // 保留旧版本使用的存储键，升级前未完成的网关登记仍可继续。
  String? get _pendingKey => identity == null || relayVaultId == null
      ? null : 'sync.syncthing.${identity!.deviceId}.$relayVaultId.hostedPending';
  Future<String?> pendingHostedInvite() async {
    final key = _pendingKey;
    return key == null ? null : secrets.read(key);
  }
  /// 已配对但还没登记到同步服务器（例如登记时断网）。
  Future<bool> hasPendingEnrollment() async =>
      await gatewayOrigin() == null && await pendingHostedInvite() != null;
  Future<void> retryEnrollment() async {
    final pending = await pendingHostedInvite();
    if (pending == null) throw StateError('没有待完成的服务器登记');
    await enableHosted(pending);
  }
  Future<String?> hostedGrant(MemberKeys peer) async {
    final gateway = await gatewayOrigin();
    if (gateway == null) return null;
    final member = _controller!.authorize(relayVaultId!, peer.deviceId);
    if (member == null || !listEquals(member.signingPublicKey, peer.signingPublicKey)) {
      throw StateError('设备已不在资料库中');
    }
    return HostedInvite.delegate(gateway, relayVaultId!,
        _local!.keys.signer, member.signingPublicKey, gateway: true);
  }

  static const _leavingKey = 'sync.leavingVault';
  /// 本机退出当前同步空间：便签、事项、附件都保留，其他设备不受影响。
  Future<void> leaveVault() => _leaveVault();
  AddDeviceSession? _joining;
  /// 在已连接同步服务器的设备上生成一次性加入链接，等待新设备加入。
  AddDeviceSession startAddDevice() {
    _joining?.cancel();
    final session = _joining = AddDeviceSession._(this);
    unawaited(session._start());
    return session;
  }
  /// 新设备打开已连接设备给出的加入链接：经同步服务器配对并登记。
  /// 本机已在另一个同步空间时抛出 [VaultSwitchRequired]；用户确认后以
  /// [leaveCurrentVault] 重试，先退出原空间再加入。
  Future<void> joinWithLink(String link, {void Function(String step)? onProgress,
      bool Function()? cancelled, bool leaveCurrentVault = false}) =>
      _joinWithLink(link, onProgress, cancelled, leaveCurrentVault);

  /// 粘贴框的统一入口：服务器邀请或已连接设备的加入链接。
  Future<void> connectWithLink(String link, {void Function(String step)? onProgress,
      bool Function()? cancelled, bool leaveCurrentVault = false}) async {
    if (DeviceJoinLink.looksLike(link)) {
      return joinWithLink(link, onProgress: onProgress, cancelled: cancelled,
          leaveCurrentVault: leaveCurrentVault);
    }
    final HostedInvite invite;
    try {
      invite = HostedInvite.parse(link);
    } on FormatException {
      throw const FormatException('请粘贴服务器邀请链接，或已连接设备上的加入链接');
    }
    if (!invite.gateway) throw const FormatException('请使用序点同步网关生成的邀请链接');
    onProgress?.call('正在连接同步服务器');
    await enableHosted(link);
  }

  Future<void> enableHosted(String link) async {
    final invite = HostedInvite.parse(link);
    if (!invite.gateway) throw const FormatException('请使用序点同步网关生成的邀请链接');
    if (!prepared) await prepare(_defaultDeviceName());
    await _run(() async {
      _requirePrepared();
      _requireNormalMode();
      final signer = _local!.keys.signer;
      final first = !hasVault;
      if (first && invite.token.isEmpty || !first && !canSync) throw StateError('请先与资料库中的设备配对');
      final staged = 'sync.gateway.newVault.${identity!.deviceId}';
      // Keep the candidate ID across a lost response or a crash before local commit.
      var candidate = relayVaultId ?? await secrets.read(staged);
      if (candidate == null) {
        final random = Random.secure();
        candidate = base64UrlEncode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
        await secrets.write(staged, candidate);
      }
      final vault = candidate;
      if (invite.issuer.isNotEmpty &&
          (!verifiedPeers.any((p) => _authorize(vault, p.deviceId) != null &&
              base64Encode(p.signingPublicKey) == invite.issuer) ||
           !await signer.verify(utf8.encode(['seqpoint-gateway-grant-v1', invite.origin,
             vault, base64Encode(signer.publicKey)].join('\n')), base64Decode(invite.grant),
             base64Decode(invite.issuer)))) {
        throw const FormatException('授权与当前配对设备不匹配');
      }
      await invite.enroll(vault, identity!.deviceId, signer);
      if (first && !_closed) await _createLocalVault(vaultPublicId: vault);
      if (_closed || !canSync || vault != relayVaultId) throw StateError('资料库已变化');
      await _storeRelayEndpoint('gateway+${invite.origin}');
      await secrets.delete(staged);
    });
    final pending = _pendingKey;
    if (pending != null) await secrets.delete(pending);
  }

  static String _defaultDeviceName() {
    try {
      final name = Platform.localHostname.trim();
      if (name.isNotEmpty && name != 'localhost' && name.length <= 64) return name;
    } catch (_) {}
    if (Platform.isAndroid) return 'Android 设备';
    if (Platform.isIOS) return 'iPhone';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows 电脑';
    return '本机';
  }

  final SeqDatabase db;
  final Directory root;
  final SecretStore secrets;
  final FutureOr<void> Function()? onCommittedChange;
  LocalDeviceIdentity? _local;
  LanTlsIdentity? _tls;
  SyncMembershipController? _controller;
  LanSyncRuntime? _runtime;
  StreamSubscription<void>? _membershipChanges;
  PairingInvitation? _invitation;
  final _sessions = <PairingHandshake>{};
  Future<void> _tail = Future<void>.value();
  Future<void>? _stopping;
  bool _closed = false, _busy = false, _baselineReady = false, _paused = false;
  int? _listeningPort;
  String? _error;
  SyncOutcome? _lastRound;
  final Map<String, String> _relayMessages = {};
  AutoSyncScheduler? _automatic;
  bool _automaticStarted=false,_automaticEnabled=true,_userPaused=false,_suspended=false;
  String _automaticEndpoint='';
  bool get automaticEnabled=>_automaticEnabled;
  bool get mediaSyncEnabled=>AttachmentSyncPolicy(db).enabled;
  bool get mediaPending=>_runtime?.mediaPending??false;
  int get transferredBytes=>_runtime?.mediaTransferredBytes??0;
  Future<void> startAutomatic()=>_startAutomatic();
  void _notifyAutomatic()=>notifyListeners();
  void suspendAutomatic() {
    _suspended=true;_automatic?.suspend();
  }
  Future<void> resumeAutomatic() async {
    if(_closed) return;_suspended=false;
    try {
      if(!_automaticStarted) {await startAutomatic();} else {await _refreshAutomaticTarget();}
      _automatic?.request();
    } catch(_) {if(!_closed) {_error='自动同步恢复失败，请检查同步服务器连接';notifyListeners();}}
  }
  Future<void> setAutomaticEnabled(bool enabled)=>_run(() async {
    if(!await (await SharedPreferences.getInstance()).setBool('sync.auto.enabled',enabled)) throw StateError('自动同步设置保存失败');
    _automaticEnabled=enabled;
    if(enabled) {await _resumeManual();await _refreshAutomaticTarget();} else {_automatic?.suspend();}
  });
  Future<void> setMediaSyncEnabled(bool enabled)=>_run(() async {
    if(!canSync) throw StateError('请先准备同步空间');
    AttachmentSyncPolicy(db).setEnabled(enabled);_automatic?.request();
  });
  Future<void> _resumeManual() async {
    if(!_userPaused) return;
    if(!await (await SharedPreferences.getInstance()).setBool('sync.user.paused',false)) throw StateError('同步暂停状态保存失败');
    _userPaused=false;await _refreshAutomaticTarget();
  }
  String? get relayMessage => _relayMessages[relayVaultId];
  bool _requiresNewIdentity = false;
  LocalDeviceIdentity? _recoveryIdentity;
  String? _recoveryPreviousId;
  ({MembershipReducer membership, VaultKey key, Object version})? _hostRecovery;
  bool get requiresNewIdentity => _requiresNewIdentity;
  bool get hasPendingIdentityRecovery => !_closed && _requiresNewIdentity &&
      _recoveryIdentity != null && _recoveryPreviousId != null;
  DeviceIdentity? get pendingIdentity => _recoveryIdentity?.identity;
  bool get hasMembershipConflict => _controller?.current?.membership.isConflicted == true;
  bool get prepared => _local != null && _tls != null && _controller != null;
  DeviceIdentity? get identity => _local?.identity;
  SyncMembershipControllerState? get membershipState => _controller?.state;
  bool get busy => _busy;
  int? get listeningPort => _listeningPort;
  String? get error => _error;
  SyncOutcome? get lastRound => _lastRound;
  bool get hasVault => _controller?.current != null;
  bool get canCreateInvitation => !_closed && !_requiresNewIdentity && _controller?.current?.isUsable == true && _snapshot() != null;
  bool get canSync => !_closed && !_requiresNewIdentity && _baselineReady && _snapshot() != null;
  Object? get membershipVersion => _revocationVersion();
  List<MemberKeys> get verifiedPeers => List.unmodifiable(
      _controller?.current?.state.members.values.where(
          (member) => member.deviceId != identity?.deviceId) ?? const <MemberKeys>[]);
  String get status {
    if (_closed) return '同步已停止';
    if (_error != null) return '同步错误';
    if (_busy) return '正在处理';
    if (!prepared) return '尚未准备同步';
    if (_controller!.current == null) return '未配对';
    if (!_controller!.current!.isUsable) return '等待有效成员密钥';
    if (_listeningPort != null) return '已监听端口 $_listeningPort';
    if (_paused || _userPaused) return '同步已暂停';
    if(_automaticEnabled && _automaticEndpoint.isNotEmpty) return '自动同步已开启';
    return '等待手动同步';
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('同步服务已停止'));
    final result = _tail.then((_) async {
      _busy = true; _error = null; notifyListeners();
      try { return await action(); }
      catch (_) { _error = '同步操作失败，请检查配对、安全存储或对端地址'; rethrow; }
      finally { _busy = false; notifyListeners(); }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  LanSyncMembership? _snapshot() {
    if (_requiresNewIdentity || !_baselineReady) return null;
    final controller = _controller, current = controller?.current;
    if (controller?.state != SyncMembershipControllerState.ready || current == null ||
        !current.membership.isMemberAuthorized(_local!.keys.deviceId)) {
      return null;
    }
    final policy = controller!.policy;
    if (policy == null) return null;
    return LanSyncMembership(version: controller.version, policy: policy,
        checkpointMemberHistory: controller.checkpointMemberHistory,
        epochKeys: current.epochKeys);
  }

  Future<void> prepare(String name) => _run(() => _prepare(name));

  Future<void> _prepare(String name) async {
    _baselineReady = false;
    final writer = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    _requiresNewIdentity = writer['requires_new_identity'] == 1;
    final identities = SyncIdentityStore(secrets);
    final local = writer['device_id'] is String
        ? await identities.loadForDevice(writer['device_id'] as String)
        : await identities.loadOrCreate(name);
    await _selectLocal(local);
    if ((await SharedPreferences.getInstance()).getBool(AppSyncService._leavingKey) == true) {
      await _finishLeave(local);
      return _prepare(name);
    }
    _tls ??= await SyncTlsStore(secrets).loadOrCreate();
    if (_controller == null) {
      _controller = SyncMembershipController(store: _membershipStore(_local!),
          localDevice: _local!.keys);
      _membershipChanges = _controller!.changes.listen((_) => notifyListeners());
    }
    await _controller!.load();
    if (writer['device_id'] != null && _controller!.current == null) {
      await _runtime?.stop(); await _controller!.stop();
      await _membershipChanges?.cancel();
      _runtime = null; _controller = null; _baselineReady = false;
      throw StateError('已绑定设备缺少可信成员记录，同步保持关闭');
    }
    if (_requiresNewIdentity) {
      _baselineReady = false;
    } else if (_controller!.current?.isUsable == true) {
      _enableBaseline();
    } else {
      final writer = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
      _baselineReady = writer['enabled'] == 1 && writer['baseline_ready'] == 1 &&
          writer['device_id'] == _local!.keys.deviceId && writer['requires_new_identity'] == 0;
    }
    _attachRuntime();
  }

  SyncMembershipStore _membershipStore(LocalDeviceIdentity local) => SyncMembershipStore(
      secrets, deviceId: local.isRecoveryIdentity ? local.keys.deviceId : null);

  Future<void> _selectLocal(LocalDeviceIdentity local) async {
    if (_local?.keys.deviceId != local.keys.deviceId) {
      await _runtime?.stop(); await _controller?.stop();
      await _membershipChanges?.cancel();
      _runtime = null; _controller = null; _baselineReady = false;
    }
    _local = local;
  }

  void _attachRuntime() {
    _runtime ??= LanSyncRuntime(db: db, root: root, localDevice: _local!.keys,
        currentMembership: _snapshot, authorize: _authorize,
        controlFiles: _controller!.publishedControlFiles,
        ingestControl: (path, bytes) async {
          await _controller!.ingest(path: path, bytes: bytes);
        }, onCommittedChange: onCommittedChange);
  }

  MemberKeys? _authorize(String vault, String device) {
    if (_snapshot() == null) return null;
    if (device != _local!.keys.deviceId) return _controller!.authorize(vault, device);
    final snapshot = _snapshot();
    if (snapshot == null || snapshot.policy.membership.state.vaultPublicId != vault) return null;
    final member = snapshot.policy.membership.state.members[device];
    if (member == null || member.tlsFingerprint != _tls!.fingerprint ||
        !listEquals(member.signingPublicKey, _local!.keys.signer.publicKey) ||
        !listEquals(member.exchangePublicKey, _local!.keys.exchangePublicKey)) {
      return null;
    }
    return member;
  }

  void _enableBaseline() {
    SyncBaseline(db).initialize(_local!.keys.deviceId);
    _baselineReady = true;
  }

  void _requirePrepared() {
    if (!prepared) throw StateError('请先准备本机同步身份');
  }

  void _requireNormalMode() {
    if (_requiresNewIdentity) throw StateError('恢复后请先创建新设备身份重新配对');
  }

  Future<PairingInvitation> createInvitation() => _createInvitation();
  Future<void> revokePeer(MemberKeys expectedPeer, {required Object expectedVersion}) =>
      _revokePeer(expectedPeer, expectedVersion);
  Future<PairingHandshake> respondToInvitation(Map<String, Object?> payload) =>
      _respondToInvitation(payload);
  Future<PairingHandshake> acceptResponse(Map<String, Object?> payload) => _acceptResponse(payload);
  Future<Map<String, Object?>> finishHost(PairingHandshake session) => _finishHost(session);
  Future<void> finishGuest(PairingHandshake session, Map<String, Object?> packet) async {
    await _finishGuest(session, packet);
    await _resumeHostedEnrollment();
  }
  Future<void> _resumeHostedEnrollment() async {
    if (_closed || !canSync) return;
    try {
      final pending = await pendingHostedInvite();
      if (pending != null && !_closed) await enableHosted(pending);
    } catch (_) {
      if (_closed) return;
      _relayMessages[relayVaultId ?? ''] = '设备已配对，同步服务器暂未登记，请在同步设置中重试';
      notifyListeners();
    }
  }
  void cancelPairing() => _cancelPairing();
  Future<DeviceIdentity> beginIdentityRecovery(String name) =>
      _beginIdentityRecovery(name);
  Future<PairingHandshake> respondToRecoveryInvitation(Map<String, Object?> payload) =>
      _respondToRecoveryInvitation(payload);
  Future<void> finishIdentityRecovery(PairingHandshake session, Map<String, Object?> packet) =>
      _finishIdentityRecovery(session, packet);
  Future<void> recoverFromPairing(PairingHandshake session, Map<String, Object?> packet) =>
      _recoverFromPairing(session, packet);
  Future<PairingInvitation> createRecoveryInvitation() =>
      _createRecoveryInvitation();

  Future<void> newVault() => _newVault();
  Future<void> _newVault({String? vaultPublicId}) =>
      _run(() => _createLocalVault(vaultPublicId: vaultPublicId));
  Future<void> _createLocalVault({String? vaultPublicId}) async {
    _requirePrepared();
    _requireNormalMode();
    final random = Random.secure();
    List<int> fresh() => List.generate(32, (_) => random.nextInt(256));
    await _controller!.createVault(
        vaultPublicId: vaultPublicId ?? base64UrlEncode(fresh()).replaceAll('=', ''),
        epochKey: VaultKey(epoch: 1, keyBytes: fresh()),
        tlsFingerprint: _tls!.fingerprint);
    _enableBaseline();
  }

  String? get relayVaultId => _controller?.current?.state.vaultPublicId;
  String get relayNodeConfiguration {
    if (!canSync) throw StateError('请先创建同步空间并完成设备配对');
    final current = _controller!.current!;
    return const JsonEncoder.withIndent('  ').convert({
      'vaultId': current.state.vaultPublicId,
      'devices': {for (final member in current.state.members.values)
        if (current.membership.isMemberAuthorized(member.deviceId))
          member.deviceId: base64UrlEncode(member.signingPublicKey).replaceAll('=', '')},
      'quotaBytes': 1073741824,
    });
  }

  Future<String> loadRelayEndpoint() async {
    final vault = relayVaultId;
    if (vault == null) return '';
    final stored = await _relaySetting();
    return stored.startsWith('gateway+') ? stored.substring(8) : stored;
  }

  int _relaySettingsRevision = 0;
  int get relaySettingsRevision => _relaySettingsRevision;
  Future<String> _relaySetting() async => relayVaultId == null ? '' :
      (await SharedPreferences.getInstance()).getString('sync.relay.$relayVaultId') ?? '';
  Future<String?> gatewayOrigin() async {
    final stored = await _relaySetting();
    return stored.startsWith('gateway+') ? stored.substring(8) : null;
  }

  Future<void> saveRelayEndpoint(String endpoint) => _run(() async {
    if (!canSync) throw StateError('同步尚未安全启用');
    final value = endpoint.trim();
    if (value.isNotEmpty) {
      RelayTransport(endpoint: value, vaultPublicId: relayVaultId!, keys: _local!.keys).close();
    }
    if (await gatewayOrigin() == value) return;
    await _storeRelayEndpoint(value);
  });

  Future<void> _storeRelayEndpoint(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString('sync.relay.$relayVaultId', value)) {
      throw StateError('节点地址保存失败');
    }
    _relaySettingsRevision++;
    await _refreshAutomaticTarget();
    _automatic?.request();
  }

  Future<void> _sendGatewayRevocations(String origin) async {
    final revoked = _controller!.current!.state.revokedIds;
    if (revoked.isEmpty) return;
    final key = 'sync.gateway.revoked.${identity!.deviceId}.$relayVaultId.$origin';
    final prefs = await SharedPreferences.getInstance();
    final sent = (prefs.getStringList(key) ?? []).toSet();
    for (final id in revoked.difference(sent)) {
      await HostedInvite.revoke(origin, id, gateway: true).enroll(
          relayVaultId!, identity!.deviceId, _local!.keys.signer);
      sent.add(id);
      if (!await prefs.setStringList(key, sent.toList())) throw StateError('撤销回执保存失败');
    }
  }

  Future<SyncOutcome> syncRelay({bool automatic=false}) => _run(() async {
    if(automatic && (!_automaticEnabled || _userPaused || _suspended)) throw StateError('自动同步已暂停');
    if (!canSync) throw StateError('同步尚未安全启用');
    if(!automatic) await _resumeManual();
    final vault = relayVaultId!;
    _relayMessages.remove(vault);
    try {
      final endpoint = await loadRelayEndpoint();
      if (endpoint.isEmpty) throw StateError('请先连接同步服务器');
      final gateway = await gatewayOrigin() == endpoint;
      if (gateway) await _sendGatewayRevocations(endpoint);
      if (_closed || !canSync) throw StateError('同步已停止');
      if (_paused) { _runtime!.resume(); _paused = false; }
      RelayTransport connect() => RelayTransport(endpoint: endpoint, vaultPublicId: vault, keys: _local!.keys);
      final client = connect();
      var result = await _runtime!.syncRelay(client);
      if (gateway && result is Err<SyncOutcome> && {413,507}.contains(client.lastRejectedStatus)) {
        result = await _runtime!.syncRelay(connect(), downloadOnly: true);
        if (result case Ok<SyncOutcome>(:final value)) {
          _lastRound = value;
          _relayMessages[vault] = client.lastRejectedStatus == 507
              ? '节点磁盘空间不足，已接收可用更新，本机改动等待上传'
              : '上传超过容量或文件限制，已接收可用更新，本机改动等待上传';
          return value;
        }
      }
      if (result case Ok<SyncOutcome>(:final value)) {
        _lastRound = value;
        _relayMessages[vault] = (_runtime?.mediaPending??false)
            ? '本轮交换已完成，仍有分块待传；后续同步会继续'
            : value.waitingPeers.isNotEmpty
            ? '部分数据仍在等待密钥或前序日志，请稍后重试'
            : '已与同步服务器交换最新修改';
        return value;
      }
      throw StateError((result as Err<SyncOutcome>).message ?? '同步失败');
    } catch (error) {
      final detail = error.toString();
      _relayMessages[vault] = detail.contains('HTTP 413') ? '上传超过资料库配额或文件大小限制'
          : detail.contains('HTTP 507') ? '节点磁盘空间不足，上传暂缓'
          : detail.contains('HTTP 403') ? '节点已暂停此空间或设备无权访问'
          : '同步未完成：$error';
      rethrow;
    }
  });

  /// 局域网直连，仅用于测试与诊断；用户界面只走同步服务器。
  Future<int> startServer({InternetAddress? address, int port = 0}) => _run(() async {
    if (!canSync) throw StateError('同步尚未安全启用');
    await _resumeManual();
    if (_listeningPort != null) return _listeningPort!;
    if (_paused) { _runtime!.resume(); _paused = false; }
    final prefs = await SharedPreferences.getInstance();
    final key = 'sync.lan.port.${identity!.deviceId}';
    final savedPort = port != 0 ? port : prefs.getInt(key) ?? 0;
    _listeningPort = await _runtime!.startServer(address: address, port: savedPort,
        securityContext: _tls!.createSecurityContext(), tlsFingerprint: _tls!.fingerprint);
    if (!await prefs.setInt(key, _listeningPort!)) throw StateError('监听端口保存失败');
    return _listeningPort!;
  });

  /// 局域网直连，仅用于测试与诊断；用户界面只走同步服务器。
  Future<SyncOutcome> syncOnce({required String peerDeviceId, required String host,
      required int port}) => _run(() async {
    if (!canSync || host.trim().isEmpty || port < 1 || port > 65535) {
      throw StateError('同步身份或对端地址无效');
    }
    await _resumeManual();
    final peer = _controller!.authorize(
        _controller!.current!.state.vaultPublicId, peerDeviceId);
    if (peer == null) throw StateError('对端不在有效成员名单');
    if (_paused) { _runtime!.resume(); _paused = false; }
    final result = await _runtime!.syncOnce(LanPeer(deviceId: peer.deviceId,
        host: host.trim(), port: port, tlsFingerprint: peer.tlsFingerprint));
    if (result case Ok<SyncOutcome>(:final value)) return _lastRound = value;
    throw StateError('本轮同步失败');
  });

  Future<void> pause() {
    _userPaused=true;_automatic?.suspend();
    return _run(() async {
      _userPaused=true;_automatic?.suspend();
      await _runtime?.pause();_listeningPort=null;_paused=true;
      if(!await (await SharedPreferences.getInstance()).setBool('sync.user.paused',true)) throw StateError('同步暂停状态保存失败');
    });
  }

  Future<void> stop() {
    if (_stopping != null) return _stopping!;
    _closed = true;
    _automatic?.suspend();
    final stopping = Completer<void>();
    _stopping = stopping.future;
    unawaited(_stop().then<void>((_) => stopping.complete(), onError: (Object error, StackTrace stack) {
      _stopping = null;
      stopping.completeError(error, stack);
    }));
    notifyListeners();
    return stopping.future;
  }

  Future<void> _stop() async {
    _joining?.cancel();
    await _tail;
    await _automatic?.stop();
    cancelPairing();
    await _runtime?.stop();
    await _controller?.stop();
    await _membershipChanges?.cancel();
    _listeningPort = null; notifyListeners();
  }
}
