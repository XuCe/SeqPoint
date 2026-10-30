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
import 'lan_pairing_link.dart';
import 'lan_pairing_network.dart';
import 'syncthing_client.dart';

part 'app_sync_service_pairing.dart';
part 'app_sync_service_recovery.dart';
part 'app_sync_service_revocation.dart';
part 'app_sync_service_automatic.dart';
part 'app_sync_service_lan_pairing.dart';
part 'app_sync_service_lan.dart';
part 'app_sync_service_syncthing.dart';

/// Main-engine owner; construction does not touch storage or the network.
class AppSyncService extends ChangeNotifier {
  AppSyncService({required this.db, required this.root, required this.secrets,
      this.onCommittedChange, this.engineHost});
  final SyncEngineHost? engineHost;
  bool _syncthingEnabled = false;
  String? _syncthingSession;
  String _syncthingMessage = '';
  bool get syncthingSupported => engineHost?.isSupported ?? false;
  bool get syncthingEnabled => _syncthingEnabled;
  String get syncthingMessage => _syncthingMessage;
  Future<String> loadSyncthingAddress() async => (await _readSyncthing())?.address ?? '';
  Future<void> saveSyncthing({required String address, required String apiKey}) =>
      _saveSyncthing(address: address, apiKey: apiKey);
  Future<void> setSyncthingEnabled(bool enabled) => _setSyncthingEnabled(enabled);
  Future<SyncOutcome> syncSyncthing({bool automatic = false}) => _syncSyncthing(automatic: automatic);
  final SeqDatabase db;
  final Directory root;
  final SecretStore secrets;
  final FutureOr<void> Function()? onCommittedChange;
  bool _lanEnabled = false;
  final Map<String, LanPeer> _lanPeers = {};
  bool get lanEnabled => _lanEnabled;
  List<LanPeer> get lanPeers => List.unmodifiable(_lanPeers.values);
  Future<void> setLanEnabled(bool value) => _setLanEnabled(value);
  LanPairingCoordinator? _lanPairing;
  LanPairingCoordinator get lanPairing => _lanPairing ??= LanPairingCoordinator(this);
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
    if (!_closed && engineHost != null) {
      unawaited(_run(() async {
        await _stopSyncthing();
        if (_syncthingEnabled) _syncthingMessage='跨网同步已暂停';
      }).catchError((Object _) {
        if (!_closed) { _error='跨网同步暂停失败';notifyListeners(); }
      }));
    }
  }
  Future<void> resumeAutomatic() async {
    if(_closed) return;_suspended=false;
    try {
      if(!_automaticStarted) {await startAutomatic();} else {await _refreshAutomaticTarget();}
      _automatic?.request();
    } catch(_) {if(!_closed) {_error='自动同步恢复失败，请检查节点设置';notifyListeners();}}
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
    if(_automaticEnabled && _automaticEndpoint.isNotEmpty) return '自动云同步已开启';
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
      await _stopSyncthing(); _syncthingEnabled=false; _syncthingMessage='';
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
  Future<void> finishGuest(PairingHandshake session, Map<String, Object?> packet) =>
      _finishGuest(session, packet);
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
  Future<void> _newVault({String? vaultPublicId}) => _run(() async {
    _requirePrepared();
    _requireNormalMode();
    final random = Random.secure();
    List<int> fresh() => List.generate(32, (_) => random.nextInt(256));
    await _controller!.createVault(
        vaultPublicId: vaultPublicId ?? base64UrlEncode(fresh()).replaceAll('=', ''),
        epochKey: VaultKey(epoch: 1, keyBytes: fresh()),
        tlsFingerprint: _tls!.fingerprint);
    _enableBaseline();
  });

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
    return (await SharedPreferences.getInstance()).getString('sync.relay.$vault') ?? '';
  }

  Future<void> saveRelayEndpoint(String endpoint) => _run(() async {
    if (!canSync) throw StateError('同步尚未安全启用');
    final value = endpoint.trim();
    if (value.isNotEmpty) {
      RelayTransport(endpoint: value, vaultPublicId: relayVaultId!, keys: _local!.keys).close();
    }
    if (!await (await SharedPreferences.getInstance()).setString('sync.relay.$relayVaultId', value)) {
      throw StateError('节点地址保存失败');
    }
    await _refreshAutomaticTarget();
  });

  Future<SyncOutcome> syncRelay({bool automatic=false}) => _run(() async {
    if(automatic && (!_automaticEnabled || _userPaused || _suspended)) throw StateError('自动同步已暂停');
    if (!canSync) throw StateError('同步尚未安全启用');
    if(!automatic) await _resumeManual();
    final vault = relayVaultId!;
    _relayMessages.remove(vault);
    try {
      final endpoint = await loadRelayEndpoint();
      if (endpoint.isEmpty) throw StateError('请先保存 HTTPS 节点地址');
      if (_closed || !canSync) throw StateError('同步已停止');
      if (_paused) { _runtime!.resume(); _paused = false; }
      final result = await _runtime!.syncRelay(RelayTransport(
        endpoint: endpoint, vaultPublicId: vault, keys: _local!.keys));
      if (result case Ok<SyncOutcome>(:final value)) {
        _lastRound = value;
        _relayMessages[vault] = (_runtime?.mediaPending??false)
            ? '本轮交换已完成，仍有分块待传；后续同步会继续'
            : value.waitingPeers.isNotEmpty
            ? '部分数据仍在等待密钥或前序日志，请稍后重试'
            : '已完成本轮云端交换，等待其他设备取走；不代表对端已接收';
        return value;
      }
      throw StateError((result as Err<SyncOutcome>).message ?? '云同步失败');
    } catch (error) {
      _relayMessages[vault] = '云同步未完成：$error';
      rethrow;
    }
  });

  Future<int> startServer({InternetAddress? address, int port = 0, bool automatic = false}) => _run(() async {
    if (!canSync) throw StateError('同步尚未安全启用');
    if (automatic) {
      if (_closed || _userPaused || _suspended || !_lanEnabled || !_automaticEnabled) {
        throw StateError('自动同步已暂停');
      }
    } else { await _resumeManual(); }
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

  Future<SyncOutcome> syncOnce({required String peerDeviceId, required String host,
      required int port, bool automatic = false}) => _run(() async {
    if (!canSync || host.trim().isEmpty || port < 1 || port > 65535) {
      throw StateError('同步身份或对端地址无效');
    }
    if (automatic) {
      if (_closed || _userPaused || _suspended || !_lanEnabled || !_automaticEnabled) {
        throw StateError('自动同步已暂停');
      }
    } else { await _resumeManual(); }
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
      await _stopSyncthing();
      if (_syncthingEnabled) _syncthingMessage='跨网同步已暂停';
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
    await _lanPairing?.close();
    await _tail;
    await _automatic?.stop();
    cancelPairing();
    await _runtime?.stop();
    await _stopSyncthing();
    await _controller?.stop();
    await _membershipChanges?.cancel();
    _listeningPort = null; notifyListeners();
  }
}
