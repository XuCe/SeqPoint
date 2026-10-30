import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db/database.dart';
import '../identity/device_keys.dart';
import '../identity/member_keys.dart';
import '../util/ids.dart';
import '../util/result.dart';
import 'membership_sync_policy.dart';
import 'operation.dart';
import 'segment_receiver.dart';
import 'sync_engine.dart';
import 'sync_publication_catalog.dart';
import 'sync_publisher.dart';
import 'sync_blob_store.dart';
import 'sync_content_transfer.dart';
import 'sync_manifest.dart';
import 'sync_media.dart';
import 'sync_checkpoints.dart';
import 'sync_files.dart';
import 'sync_media_prepare.dart';
import 'sync_content_catalog.dart';
import 'sync_cache_gc.dart';
import 'transport/published_file_view.dart';
import 'transport/lan_file_source.dart';
import 'transport/lan_https_server.dart';
import 'transport/lan_protocol.dart';
import 'transport/lan_transport.dart';
import 'transport/vault_transport.dart';
import 'transport/relay_transport.dart';
import 'vault/encrypted_segment_codec.dart';
import 'vault/segment.dart';
import 'vault/vault_layout.dart';
import 'vault/vault_store.dart';

/// The adapter must return null while verified membership is being replaced.
final class LanSyncMembership {
  LanSyncMembership({
    required this.version,
    required this.policy,
    required Map<int, List<int>> epochKeys,
  }) : epochKeys = Map.unmodifiable(
         epochKeys.map(
           (epoch, key) => MapEntry(epoch, List<int>.unmodifiable(key)),
         ),
       );
  final Object version;
  final MembershipSyncPolicy policy;
  final Map<int, List<int>> epochKeys;
}

/// Serial HTTPS orchestration. The database remains open until stop completes.
class LanSyncRuntime {
  LanSyncRuntime({
    required this.db,
    required this.root,
    required this.localDevice,
    required this.currentMembership,
    required this.authorize,
    required this.controlFiles,
    required this.ingestControl,
    this.onCommittedChange,
    this.writeSegmentBytes,
    this.writeAckBytes,
  });
  final SeqDatabase db;
  final Directory root;
  final DeviceKeys localDevice;
  final LanSyncMembership? Function() currentMembership;
  final LanAuthorization authorize;
  final LanPublishedFiles controlFiles;
  final Future<void> Function(String path, List<int> bytes) ingestControl;
  final FutureOr<void> Function()? onCommittedChange;
  final Future<void> Function(File, List<int>)? writeSegmentBytes;
  final Future<void> Function(File, List<int>)? writeAckBytes;
  bool _accepting = true, _stopped = false;
  bool _needsReconciliation = false;
  Future<void> _tail = Future<void>.value();
  Future<void>? _pausing;
  LanHttpsServer? _server;
  SyncPublisher? _publisher;
  SyncPublicationCatalog? _catalog;
  _LanScope? _scope;
  String? _vaultPublicId, _authorityId;
  final Set<LanTransport> _clients = {};
  final Set<RelayTransport> _relayClients = {};
  bool mediaPending = false;
  int mediaTransferredBytes = 0;
  Map<String, List<int>> _ackFiles = const {};

  Future<T> _enqueue<T>(Future<T> Function() work) {
    if (!_accepting) return Future.error(StateError('LAN runtime paused'));
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> pause() {
    _accepting = false;
    _ackFiles = const {};
    _contentFiles = const {};
    for (final client in _clients) {
      client.close();
    }
    for (final client in _relayClients) {
      client.close();
    }
    return _pausing ??= _drain();
  }

  Future<void> _drain() async {
    await _server?.close();
    await _tail;
    await _publisher?.stop();
    await _catalog?.stop();
    _server = null;
    _publisher = null;
    _catalog = null;
    _scope = null;
    _pausing = null;
  }

  void resume() {
    if (_stopped || _pausing != null) {
      throw StateError('LAN stopped or draining');
    }
    _accepting = true;
  }

  Future<void> stop() {
    _stopped = true;
    return pause();
  }

  _LanScope _capture({bool requireEpochKey = true}) {
    final membership = currentMembership();
    if (membership == null) throw StateError('Verified membership unavailable');
    final state = membership.policy.membership.state;
    if ((_vaultPublicId != null && _vaultPublicId != state.vaultPublicId) ||
        (_authorityId != null && _authorityId != state.authorityId)) {
      throw StateError('LAN runtime authorization domain changed');
    }
    final scope = _LanScope(membership);
    _ensure(scope, requireEpochKey: requireEpochKey);
    _vaultPublicId ??= state.vaultPublicId;
    _authorityId ??= state.authorityId;
    return scope;
  }

  void _ensure(
    _LanScope scope, {
    bool allowTransaction = false,
    bool requireEpochKey = true,
  }) {
    if (!_accepting || _stopped) throw StateError('LAN runtime paused');
    final current = currentMembership();
    final policy = scope.membership.policy;
    if (current == null ||
        !identical(current.version, scope.membership.version) ||
        current.policy.membership.state.headHash != scope.head ||
        policy.membership.state.headHash != scope.head ||
        current.policy.membership.state.authorityId !=
            policy.membership.state.authorityId ||
        policy.localDeviceId != localDevice.deviceId ||
        policy.membership.isConflicted ||
        !policy.membership.isMemberAuthorized(localDevice.deviceId) ||
        (requireEpochKey && !_hasCurrentKey(scope))) {
      throw StateError('LAN membership changed or blocked');
    }
    if (!allowTransaction && !db.raw.autocommit) {
      throw StateError('LAN cannot own an open transaction');
    }
    final state = db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if (state['device_id'] != localDevice.deviceId ||
        state['enabled'] != 1 ||
        state['baseline_ready'] != 1 ||
        state['requires_new_identity'] != 0) {
      throw StateError('LAN database writer unavailable');
    }
  }

  bool _hasCurrentKey(_LanScope scope) =>
      scope.membership.epochKeys.containsKey(
        scope.membership.policy.membership.state.epoch,
      ) &&
      scope.membership.policy
          .checkLocalPublication(
            keyEpoch: scope.membership.policy.membership.state.epoch,
          )
          .isAllowed;

  MembershipSyncPolicy _guardedPolicy(_LanScope scope) => MembershipSyncPolicy(
    membership: scope.membership.policy.membership,
    localDeviceId: localDevice.deviceId,
    hasEpochKey: (epoch) {
      _ensure(scope, allowTransaction: true);
      return scope.membership.epochKeys.containsKey(epoch);
    },
  );

  SyncManifestCodec _contentCodec(_LanScope scope) {
    final state=scope.membership.policy.membership.state;
    return SyncManifestCodec(blobs:SyncBlobStore(root:root,vaultId:state.vaultPublicId,
      deviceId:localDevice.deviceId,epochKeys:scope.membership.epochKeys,guard:()=>_ensure(scope)),
      keys:localDevice,epoch:state.epoch,membershipHash:state.headHash,
      signers:state.members.map((id,member)=>MapEntry(id,member.signingPublicKey))
        ..removeWhere((id,_)=>!scope.membership.policy.membership.isMemberAuthorized(id)));
  }
  Map<String,List<int>> _checkpointAuthorKeys(_LanScope scope) {
    final membership=scope.membership.policy.membership;
    return {
      for(final id in {...membership.state.members.keys,...membership.state.revokedIds})
        if(membership.knownMemberKeys(id) case final member?) id:member.signingPublicKey,
    };
  }
  Map<String,List<int>> _contentFiles=const {};
  DateTime? _lastCacheGc;
  Future<void> _collectContentCache(SyncManifestCodec codec) async {
    final now=DateTime.now();
    if(mediaPending || (_lastCacheGc!=null && now.difference(_lastCacheGc!).inMinutes<60)) return;
    await collectSyncCache(db,codec.blobs.files);
    _lastCacheGc=now;
  }
  Future<void> _preparePublishedContent(_LanScope scope,VaultStore store,EncryptedSegmentCodec codec,{bool publishPending=true}) async {
    final content=_contentCodec(scope);
    if(publishPending) {
      await prepareLocalSyncMedia(db,SyncFiles(Directory('${root.parent.path}/attachments'),guard:()=>_ensure(scope)),content);
      while(await _publisher!.publishNext(store:store,keyEpoch:content.epoch)!=null) { _ensure(scope); }
    }
    final size=db.raw.select('SELECT COUNT(*) AS n,COALESCE(SUM(length(segment_bytes)),0) AS bytes FROM sync_publications').single;
    final compacted=db.raw.select('SELECT 1 FROM sync_checkpoints WHERE author=?',[localDevice.deviceId]).isNotEmpty;
    if(!compacted && (size['n'] as int)<100 && (size['bytes'] as int)<16*1024*1024) {
      await _catalog!.refresh(codec:codec);
      _contentFiles=await syncContentCatalog(db,content);_ensure(scope);return;
    }
    final checkpoints=SyncCheckpoints.local(db,content,_checkpointAuthorKeys(scope));
    final own=await checkpoints.prepare(await _publisher!.sealHead(store:store));
    await checkpoints.rewrapStored(publishToRelay:false);
    if(own!=null) checkpoints.compactLocal(own);
    await _catalog!.refresh(codec:codec);
    _contentFiles=await syncContentCatalog(db,content);_ensure(scope);
  }

  Map<String, List<int>> publishedFiles() {
    if (!_accepting || _scope == null) return const {};
    try {
      _ensure(_scope!, requireEpochKey: false);
      return PublishedFileView.combine([
        {for(final entry in controlFiles().entries)
          if(entry.key==VaultLayout.memberPath(localDevice.deviceId)) entry.key:entry.value},
        if(_hasCurrentKey(_scope!)) ...[_catalog?.snapshot()??const {},_ackFiles,_contentFiles],
      ]);
    } catch (_) {
      return const {};
    }
  }

  Future<int> startServer({
    required SecurityContext securityContext,
    required String tlsFingerprint,
    InternetAddress? address,
    int port = 0,
    LanLimits? limits,
  }) => _enqueue(() async {
    if (_server != null) throw StateError('LAN server already running');
    final scope = _capture(requireEpochKey: false);
    if (_hasCurrentKey(scope)) {
      final session = await _rebuild(scope);
      await _preparePublishedContent(scope,session.store,session.codec,publishPending:false);
    } else {
      _scope = scope;
    }
    _ensure(scope, requireEpochKey: false);
    final server = await LanHttpsServer.start(
      securityContext: securityContext,
      keys: localDevice,
      vaultPublicId: scope.membership.policy.membership.state.vaultPublicId,
      tlsFingerprint: tlsFingerprint,
      publishedFiles: publishedFiles,
      authorize: _authorize,
      address: address,
      port: port,
      limits: limits,
    );
    try {
      _ensure(scope, requireEpochKey: false);
    } catch (_) {
      await server.close();
      rethrow;
    }
    _server = server;
    return server.port;
  });

  MemberKeys? _authorize(String vault, String device) =>
      _accepting && !_stopped ? authorize(vault, device) : null;

  Future<Result<SyncOutcome>> syncOnce(LanPeer peer) async {
    try {
      return Ok(await _enqueue(() => _sync(peer)));
    } catch (error) {
      return Err('lan_sync_failed', cause: error);
    }
  }

  Future<Result<SyncOutcome>> syncRelay(RelayTransport client) async {
    _relayClients.add(client);
    try {
      return Ok(await _enqueue(() => _syncRelay(client)));
    } catch (error) {
      return Err('relay_sync_failed', message: '$error', cause: error);
    } finally {
      client.close();
      _relayClients.remove(client);
    }
  }

  Future<SyncOutcome> _syncRelay(RelayTransport client) async {
    final initial = _capture(requireEpochKey: false);
    if (client.selfDeviceId != localDevice.deviceId ||
        client.vaultPublicId !=
            initial.membership.policy.membership.state.vaultPublicId) {
      throw StateError('Relay authorization domain mismatch');
    }
    final ownPath = 'members/${localDevice.deviceId}.json';
    final ownControl = controlFiles()[ownPath];
    if (ownControl != null) {
      _value(await client.putChanged(ownPath, ownControl));
      _ensure(initial, requireEpochKey: false);
    }
    await _pullControl(client);
    final scope = _capture(requireEpochKey: false);
    final peers = scope.membership.policy.membership.state.members.keys
        .where(
          (id) =>
              id != localDevice.deviceId &&
              scope.membership.policy.checkSession(id).isAllowed,
        )
        .toList();
    if (!_hasCurrentKey(scope)) {
      return SyncOutcome(
        pulled: 0,
        pushed: 0,
        reclaimed: 0,
        peers: const [],
        waitingPeers: peers,
      );
    }
    final session = await _rebuild(scope);
    final state=scope.membership.policy.membership.state;
    final content=SyncContentTransfer(_contentCodec(scope),client,SyncTransferBudget());
    final media=SyncMedia(db,content,Directory('${root.parent.path}/attachments'));
    await media.push();
    final before = _pendingPublicationCount();
    if (db.raw.select(
      'SELECT 1 FROM sync_publications WHERE key_epoch<? AND published=0 LIMIT 1',
      [scope.membership.policy.membership.state.epoch],
    ).isNotEmpty) {
      throw StateError('Old unpublished epoch requires recovery');
    }
    while (await _publisher!.publishNext(
          store: session.store,
          keyEpoch: scope.membership.policy.membership.state.epoch,
        ) !=
        null) {
      _ensure(scope);
    }
    final checkpoints=SyncCheckpoints(db,SyncContentTransfer(content.codec,client,
      SyncTransferBudget(remaining:16*1024*1024)),
      _checkpointAuthorKeys(scope));
    for(final author in state.members.keys) {
      await checkpoints.pull(author);_ensure(scope);
    }
    await checkpoints.rewrapStored();
    final head=await _publisher!.sealHead(store:session.store);
    final checkpoint=await checkpoints.prepare(head);
    if(checkpoint==null || await checkpoints.publish(checkpoint,head:head)) {
      await _catalog!.refresh(codec:session.codec);
    }
    _ensure(scope);
    var pulled = 0;
    final waiting = <String>{};
    pulled+=checkpoints.added;
    if(checkpoints.added>0) { _needsReconciliation=true;await _reconcile(); }
    for (final peer in peers) {
      final outcome = await _pullOperations(
        client,
        peer,
        scope,
        session.codec,
        session.receiver,
        0,
      );
      pulled += outcome.pulled;
      waiting.addAll(outcome.waitingPeers);
    }
    for (final entry in _ackFiles.entries) {
      _ensure(scope);
      _value(await client.putChanged(entry.key, entry.value));
      _ensure(scope);
    }
    await media.pull();
    _contentFiles=await syncContentCatalog(db,content.codec);
    mediaPending=media.pending || checkpoints.pending;
    mediaTransferredBytes=content.budget.transferred+checkpoints.transfer.budget.transferred;
    await _collectContentCache(content.codec);
    if(media.completed>0) { _needsReconciliation=true; await _reconcile(); }
    return SyncOutcome(
      pulled: pulled,
      pushed: (before - _pendingPublicationCount()).clamp(0, before),
      reclaimed: checkpoints.reclaimed,
      peers: const [],
      waitingPeers: waiting.toList(),
      pendingObjects: session.receiver.pendingObjects,
    );
  }

  Future<void> _pullControl(VaultTransport client) async {
    final files = _value(await client.list('members'));
    for (final file in files) {
      final path = 'members/${file.name}';
      final bytes = _value(await client.get(path));
      if (!_accepting) throw StateError('LAN runtime paused');
      await ingestControl(path, bytes);
      if (!_accepting) throw StateError('LAN runtime paused');
    }
  }

  int _pendingPublicationCount() => db.raw.select(
    'SELECT COUNT(*) AS n FROM sync_operations o LEFT JOIN sync_publications p ON p.seq=o.publication_seq '
    "WHERE o.source='local' AND (o.publication_seq IS NULL OR p.published=0)").single['n'] as int;


  Future<SyncOutcome> _sync(LanPeer peer) async {
    final initial = _capture(requireEpochKey: false);
    final sessionCheck = initial.membership.policy.checkSession(peer.deviceId);
    if (!sessionCheck.isAllowed) throw SyncAuthorizationBlocked(sessionCheck);
    final client = LanTransport(
      keys: localDevice,
      vaultPublicId: initial.membership.policy.membership.state.vaultPublicId,
      peer: peer,
      authorize: _authorize,
    );
    _clients.add(client);
    try {
      await _pullControl(client);
      final scope = _capture(requireEpochKey: false);
      if (!_hasCurrentKey(scope)) {
        _scope = scope;
        _ackFiles = const {};
        return SyncOutcome(
          pulled: 0,
          pushed: 0,
          reclaimed: 0,
          peers: [peer.deviceId],
          waitingPeers: [peer.deviceId],
          pendingObjects:
              db.raw
                      .select('SELECT pending_count FROM sync_local WHERE id=1')
                      .single['pending_count']
                  as int,
        );
      }
      final session = await _rebuild(scope);
      final check = _guardedPolicy(scope).checkSession(peer.deviceId);
      if (!check.isAllowed) throw SyncAuthorizationBlocked(check);
      final before = _pendingPublicationCount();
      final blockedPublication = db.raw.select(
        'SELECT 1 FROM sync_publications WHERE key_epoch<? AND published=0 LIMIT 1',
        [scope.membership.policy.membership.state.epoch]).isNotEmpty;
      if(!blockedPublication) await _preparePublishedContent(scope,session.store,session.codec);
      _ensure(scope);
      final content=SyncContentTransfer(_contentCodec(scope),client,SyncTransferBudget(remaining:16*1024*1024));
      final checkpoints=SyncCheckpoints(db,content,_checkpointAuthorKeys(scope));
      await checkpoints.pullLan();_ensure(scope);
      if(checkpoints.added>0) { _needsReconciliation=true;await _reconcile(); }
      final pushed=(before-_pendingPublicationCount()).clamp(0,before);
      final outcome = await _pullOperations(
        client,
        peer.deviceId,
        scope,
        session.codec,
        session.receiver,
        pushed,
      );
      if (blockedPublication) {
        throw StateError('Old unpublished epoch requires recovery');
      }
      final media=SyncMedia(db,content,Directory('${root.parent.path}/attachments'));
      await media.pull();_ensure(scope);
      mediaPending=media.pending || checkpoints.pending;mediaTransferredBytes=content.budget.transferred;
      if(media.completed>0) { _needsReconciliation=true;await _reconcile(); }
      _contentFiles=await syncContentCatalog(db,content.codec);
      await _collectContentCache(content.codec);
      return SyncOutcome(pulled:outcome.pulled+checkpoints.added,pushed:outcome.pushed,
        reclaimed:outcome.reclaimed,peers:outcome.peers,waitingPeers:outcome.waitingPeers,
        pendingObjects:outcome.pendingObjects);
    } finally {
      await client.closeAndDrain();
      _clients.remove(client);
    }
  }

  T _value<T>(Result<T> result) => switch (result) {
    Ok<T>(:final value) => value,
    Err<T>(:final code, :final message) => throw StateError(message == null ? code : '$code: $message'),
  };

  Future<SyncOutcome> _pullOperations(
    VaultTransport client,
    String peer,
    _LanScope scope,
    EncryptedSegmentCodec codec,
    SyncSegmentReceiver receiver,
    int pushed,
  ) async {
    final files = _value(await client.list('ops/$peer'));
    _ensure(scope);
    final bySeq = <int, String>{};
    for (final file in files) {
      final seq = int.parse(file.name.split('-').last.split('.').first);
      if (seq < 1 || bySeq.containsKey(seq)) {
        throw StateError('LAN segment collision');
      }
      bySeq[seq] = file.name;
    }
    var expected = (receiver.committedWatermarks[peer] ?? 0) + 1;
    var pulled = 0;
    final waiting = <String>{};
    final sequences = bySeq.keys.toList()..sort();
    for (final seq in sequences) {
      if (seq < expected) continue;
      if (seq != expected) {
        waiting.add(peer);
        break;
      }
      final bytes = List<int>.unmodifiable(
        _value(await client.get('ops/$peer/${bySeq[seq]}')),
      );
      final segment = Segment.decode(bytes);
      if (segment.deviceId != peer ||
          segment.seq != seq ||
          bySeq[seq] !=
              VaultLayout.segmentName(
                segment.createdAt.year,
                segment.createdAt.month,
                seq,
              )) {
        throw StateError('LAN segment path mismatch');
      }
      final check = _guardedPolicy(scope)
          .checkInbound(peerDeviceId: peer, keyEpoch: segment.keyEpoch);
      final historicalSeal =
          check.decision == MembershipSyncDecision.waiting &&
          segment.sealed &&
          segment.keyEpoch < scope.membership.policy.membership.state.epoch &&
          scope.membership.epochKeys.containsKey(segment.keyEpoch);
      if (check.decision == MembershipSyncDecision.waiting && !historicalSeal) {
        waiting.add(peer);
        break;
      }
      if (!check.isAllowed && !historicalSeal) {
        throw SyncAuthorizationBlocked(check);
      }
      final operations = List<Operation>.unmodifiable(
        await codec.decode(segment),
      );
      _ensure(scope);
      late SegmentApplyResult result;
      try {
        result = await receiver.apply((
          segment: segment,
          operations: operations,
          bytes: bytes,
        ));
      } on SyncAuthorizationBlocked catch (blocked) {
        if (blocked.check.decision != MembershipSyncDecision.waiting) rethrow;
        waiting.add(peer);
        break;
      }
      pulled += result.addedOperations;
      if (result.addedOperations > 0 || result.appliedSeq >= expected) {
        _needsReconciliation = true;
        await _reconcile();
      }
      if (!segment.isSealed) {
        if (sequences.any((next) => next > seq)) waiting.add(peer);
        break;
      }
      expected = result.appliedSeq + 1;
    }
    _ensure(scope);
    await _reconcile();
    await receiver.retryAck(
      (watermarks) => _writeAck(scope, receiver, watermarks),
    );
    _ensure(scope);
    return SyncOutcome(
      pulled: pulled,
      pushed: pushed,
      reclaimed: 0,
      peers: [peer],
      pendingObjects: receiver.pendingObjects,
      waitingPeers: waiting.toList(),
    );
  }

  Future<void> _reconcile() async {
    if (!_needsReconciliation) return;
    await onCommittedChange?.call();
    _needsReconciliation = false;
  }

  Future<void> _writeAck(
    _LanScope scope,
    SyncSegmentReceiver receiver,
    Map<String, int> watermarks,
  ) async {
    _ensure(scope);
    final writer = jsonEncode(
      db.raw.select('SELECT * FROM sync_local WHERE id=1').single,
    );
    final bytes = List<int>.unmodifiable(utf8.encode(jsonEncode(watermarks)));
    final path = VaultLayout.ackPath(localDevice.deviceId);
    final file = File('${root.path}/$path');
    if (FileSystemEntity.isLinkSync(file.parent.path) ||
        FileSystemEntity.isLinkSync(file.path)) {
      throw StateError('LAN ACK cannot follow symbolic links');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp.${newId()}');
    try {
      if (writeAckBytes case final write?) {
        await write(temporary, bytes);
      } else {
        await temporary.writeAsBytes(bytes, flush: true);
      }
      _ensure(scope);
      if (base64Encode(temporary.readAsBytesSync()) != base64Encode(bytes) ||
          writer !=
              jsonEncode(
                db.raw.select('SELECT * FROM sync_local WHERE id=1').single,
              ) ||
          jsonEncode(watermarks) != jsonEncode(receiver.committedWatermarks) ||
          FileSystemEntity.isLinkSync(file.parent.path) ||
          FileSystemEntity.isLinkSync(file.path)) {
        throw StateError('LAN ACK committed state changed');
      }
      temporary.renameSync(file.path);
      _ackFiles = {path: bytes};
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<
    ({
      EncryptedSegmentCodec codec,
      VaultStore store,
      SyncSegmentReceiver receiver,
    })
  >
  _rebuild(_LanScope scope) async {
    _contentFiles=const {};
    await _catalog?.stop();
    _ensure(scope);
    final membership = scope.membership;
    final policy = _guardedPolicy(scope);
    final codec = EncryptedSegmentCodec(
      vaultPublicId: policy.membership.state.vaultPublicId,
      deviceKeys: localDevice,
      epochKeys: membership.epochKeys,
      trustedSigners: policy.membership.state.members.map(
        (id, member) => MapEntry(id, member.signingPublicKey),
      ),
    );
    final store = _GuardedLanStore(
      root: root,
      deviceId: localDevice.deviceId,
      codec: codec,
      guard: () => _ensure(scope),
      writeSegmentBytes: writeSegmentBytes,
    );
    final manifest = await store.init(vaultPublicId: codec.vaultPublicId);
    if (manifest.vaultPublicId != codec.vaultPublicId) {
      throw StateError('LAN root belongs to another vault');
    }
    _ensure(scope);
    _scope = scope;
    _catalog = SyncPublicationCatalog(
      db,
      deviceId: localDevice.deviceId,
      policy: policy,
    );
    _publisher ??= SyncPublisher(db, deviceId: localDevice.deviceId);
    return (
      codec: codec,
      store: store,
      receiver: SyncSegmentReceiver.authorized(db, policy: policy),
    );
  }
}

class _LanScope {
  _LanScope(this.membership)
    : head = membership.policy.membership.state.headHash;
  final LanSyncMembership membership;
  final String head;
}

class _GuardedLanStore extends VaultStore {
  _GuardedLanStore({
    required super.root,
    required super.deviceId,
    required super.codec,
    required this.guard,
    super.writeSegmentBytes,
  });
  final void Function() guard;

  @override
  Future<void> writePrepared({
    required String fileName,
    required List<int> bytes,
    required Set<String> knownFileNames,
    required void Function(List<Operation>, void Function()) commit,
  }) => super.writePrepared(
    fileName: fileName,
    bytes: bytes,
    knownFileNames: knownFileNames,
    commit: (operations, replace) {
      // All crypto and temporary IO have completed; no await before rename.
      guard();
      commit(operations, replace);
    },
  );
}
