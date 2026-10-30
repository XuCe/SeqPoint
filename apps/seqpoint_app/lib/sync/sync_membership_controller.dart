import 'dart:async';
import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'sync_membership_store.dart';

enum SyncMembershipControllerState { unloaded, updating, ready, blocked, stopping, stopped }

/// Main-engine owner of the durable membership boundary.
final class SyncMembershipController {
  SyncMembershipController({required SyncMembershipStore store, required this.localDevice})
      : _store = store;
  final SyncMembershipStore _store;
  final DeviceKeys localDevice;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  SyncMembershipControllerState _state = SyncMembershipControllerState.unloaded;
  SyncMembershipControllerState get state => _state;
  SavedMembership? _committed, _current;
  /// Detached from the private durable source; changing its reducer grants no authority.
  SavedMembership? get current => _current;
  Map<String, List<int>> _files = const {};
  Future<void> _tail = Future<void>.value();
  Future<void>? _stopFuture;
  int _accepted = 0;
  bool _failed = false, _stopping = false;
  bool _notifying = false, _notifyAgain = false;
  Object _version = Object();
  Object get version => _version;

  void _notify() {
    _version = Object();
    if (_notifying) { _notifyAgain = true; return; }
    do {
      _notifyAgain = false;
      _notifying = true;
      try { _changes.add(null); }
      finally { _notifying = false; }
    } while (_notifyAgain);
  }

  Future<SavedMembership?> _run(Future<SavedMembership?> Function() action,
      {bool reload = false}) {
    if (_stopping || (_failed && !reload)) {
      return Future.error(StateError('成员控制已停用，请显式重新加载安全记录'));
    }
    _accepted++;
    _state = SyncMembershipControllerState.updating;
    final result = _tail.then((_) async {
      try {
        if (_failed && !reload) throw StateError('成员控制等待重新加载');
        final saved = await action();
        await _install(saved);
        _failed = false;
        if (!_stopping && _accepted == 1) _state = SyncMembershipControllerState.ready;
        return _current;
      } catch (_) {
        _failed = true;
        if (!_stopping) _state = SyncMembershipControllerState.blocked;
        throw StateError('成员控制更新失败，请显式重新加载安全记录');
      } finally {
        _accepted--;
        _notify();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _notify();
    return result;
  }

  MembershipSyncPolicy? get policy => _state != SyncMembershipControllerState.ready ||
      _committed == null || _committed!.membership.isConflicted ? null :
      MembershipSyncPolicy(membership: MembershipReducer(trustedAnchor: _committed!.state),
        localDeviceId: localDevice.deviceId,
        hasEpochKey: (epoch) => _state == SyncMembershipControllerState.ready &&
            _committed?.isUsable == true && _committed?.epochKey?.epoch == epoch);

  MemberKeys? authorize(String vaultPublicId, String peerDeviceId) {
    final saved = _committed;
    if (_state != SyncMembershipControllerState.ready || saved == null ||
        !saved.membership.isMemberAuthorized(localDevice.deviceId) ||
        saved.state.vaultPublicId != vaultPublicId) {
      return null;
    }
    return saved.state.members[peerDeviceId];
  }

  Map<String, List<int>> publishedControlFiles() =>
      _state == SyncMembershipControllerState.ready ? _files : const {};

  Future<void> _install(SavedMembership? saved) async {
    SavedMembership? view;
    Map<String, List<int>> files = const {};
    if (saved != null) {
      final detached = await MembershipReducer.restoreTrustedLocal(
          saved.membership.toTrustedLocalJson());
      view = SavedMembership(detached, saved.epochKey, saved.localDeviceId,
          epochKeys: saved.epochKeys);
      final own = saved.membership.evidence.where(
          (event) => event.issuerDeviceId == localDevice.deviceId).toList()
        ..sort((a, b) => a.issuerSequence.compareTo(b.issuerSequence));
      final file = MembershipFile(vaultPublicId: saved.state.vaultPublicId,
          authorityId: saved.state.authorityId, issuerDeviceId: localDevice.deviceId,
          events: own);
      files = Map.unmodifiable({file.path: file.encode()});
    }
    _committed = saved;
    _current = view;
    _files = files;
  }

  Future<SavedMembership?> load() => _run(() => _store.load(localDevice), reload: true);

  Future<SavedMembership> initializeFromPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint, required VaultKey epochKey}) {
    final frozen = Map<String, Object?>.from(jsonDecode(jsonEncode(checkpoint)) as Map);
    final key = VaultKey(epoch: epochKey.epoch, keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _run(() async {
      if (await _store.load(localDevice) != null || session.localDeviceId != localDevice.deviceId) {
        throw StateError('成员记录已存在或配对本机身份不一致');
      }
      final anchor = await MembershipState.fromConfirmedPairing(session: session, checkpoint: frozen);
      return _store.save(membership: MembershipReducer(trustedAnchor: anchor),
          localDevice: localDevice, epochKey: key);
    }).then((saved) => saved!);
  }

  Future<SavedMembership> recoverFromPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint, required VaultKey epochKey}) {
    final frozen = Map<String, Object?>.from(jsonDecode(jsonEncode(checkpoint)) as Map);
    final key = VaultKey(epoch: epochKey.epoch, keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _run(() => _store.recoverFromPairing(session: session, checkpoint: frozen,
        localDevice: localDevice, epochKey: key)).then((saved) => saved!);
  }

  Future<SavedMembership> recoverFromHostedPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint, required VaultKey epochKey}) {
    final frozen = Map<String, Object?>.from(jsonDecode(jsonEncode(checkpoint)) as Map);
    final key = VaultKey(epoch: epochKey.epoch, keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _run(() => _store.recoverFromHostedPairing(session: session, checkpoint: frozen,
        localDevice: localDevice, epochKey: key)).then((saved) => saved!);
  }

  Future<SavedMembership> ingest({required String path, required List<int> bytes}) {
    final frozen = List<int>.unmodifiable(bytes);
    return _run(() async {
      final previous = _committed;
      if (previous == null) throw StateError('同步文件不能创建可信成员记录');
      final match = RegExp(r'^members/([A-Za-z0-9_-]{43})\.json$').firstMatch(path);
      if (match == null) throw const FormatException('成员文件路径无效');
      final issuer = match.group(1)!;
      final next = await MembershipReducer.restoreTrustedLocal(
          previous.membership.toTrustedLocalJson());
      final file = MembershipFile.decode(frozen, issuerFileDeviceId: issuer,
          expectedVaultPublicId: previous.state.vaultPublicId,
          expectedAuthorityId: previous.state.authorityId);
      final known = [...next.evidence, ...next.pendingEvents].where(
          (event) => event.issuerDeviceId == issuer).toList()
        ..sort((a, b) => a.issuerSequence.compareTo(b.issuerSequence));
      file.validateExtensionOf(MembershipFile(vaultPublicId: previous.state.vaultPublicId,
          authorityId: previous.state.authorityId, issuerDeviceId: issuer, events: known));
      var rejected = false;
      for (final event in file.events) {
        try { await next.ingest(event, issuerFileDeviceId: issuer); }
        catch (_) { rejected = true; break; }
      }
      VaultKey? key;
      if (!next.isConflicted && next.isMemberAuthorized(localDevice.deviceId)) {
        key = previous.epochKey?.epoch == next.state.epoch ? previous.epochKey : null;
        if (key == null) {
          try { key = await next.openCurrentEpoch(localDevice: localDevice); }
          catch (_) { /* Public revocations must survive an unusable envelope. */ }
        }
      }
      final saved = await _store.save(membership: next, localDevice: localDevice, epochKey: key);
      if (rejected || next.rejectedEvents.isNotEmpty) throw StateError('成员文件后缀无效');
      return saved;
    }).then((saved) => saved!);
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _stopFuture = completion.future;
    unawaited(_stop().then(completion.complete, onError: completion.completeError));
    return completion.future;
  }
  Future<void> _stop() async {
    _stopping = true;
    _state = SyncMembershipControllerState.stopping;
    _notify();
    await _tail;
    _state = SyncMembershipControllerState.stopped;
    _notify();
    await _changes.close();
  }

  Future<SavedMembership> createVault({required String vaultPublicId,
      required VaultKey epochKey, required String tlsFingerprint}) {
    final key = VaultKey(epoch: epochKey.epoch,
        keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _run(() async {
      if (await _store.load(localDevice) != null) throw StateError('成员记录已存在');
      final anchor = await MembershipState.createVault(founder: localDevice,
          vaultPublicId: vaultPublicId, epochKey: key, tlsFingerprint: tlsFingerprint);
      return _store.save(membership: MembershipReducer(trustedAnchor: anchor),
          localDevice: localDevice, epochKey: key);
    }).then((saved) => saved!);
  }
}
