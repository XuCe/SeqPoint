part of 'lan_sync_runtime.dart';

extension FolderSyncRuntime on LanSyncRuntime {
  Future<SyncOutcome> _syncFolder(FolderTransport client) async {
    final initial = _capture(requireEpochKey: false);
    if (client.writerDeviceId != localDevice.deviceId) {
      throw StateError('Folder writer mismatch');
    }
    final ownPath = 'members/${localDevice.deviceId}.json';
    final ownControl = controlFiles()[ownPath];
    if (ownControl != null) {
      _value(
        await client.put(
          ownPath,
          ownControl,
          guard: () => _ensure(initial, requireEpochKey: false),
        ),
      );
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
    if (db.raw.select(
      'SELECT 1 FROM sync_publications WHERE key_epoch<? AND published=0 LIMIT 1',
      [scope.membership.policy.membership.state.epoch],
    ).isNotEmpty) {
      throw StateError('Old unpublished epoch requires recovery');
    }
    final before = _pendingPublicationCount();
    final hasHistorical = db.raw.select(
      'SELECT 1 FROM sync_publications WHERE key_epoch<? LIMIT 1',
      [scope.membership.policy.membership.state.epoch],
    ).isNotEmpty;
    await _preparePublishedContent(
      scope,
      session.store,
      session.codec,
      forceCheckpoint: hasHistorical,
    );
    await _publisher!.sealHead(store: session.store);
    await _catalog!.refresh(codec: session.codec);
    await _exportFolder(client, scope);
    return _pullFolderPeers(
      client,
      scope,
      peers,
      session.codec,
      session.receiver,
      (before - _pendingPublicationCount()).clamp(0, before),
    );
  }

  Future<Result<SyncOutcome>> syncFolder(FolderTransport client) async {
    try {
      return Ok(await _enqueue(() => _syncFolder(client)));
    } catch (error) {
      return Err('folder_sync_failed', cause: error);
    }
  }

  Future<void> _exportFolder(FolderTransport client, _LanScope scope) async {
    final publications = publishedFiles();
    for (final path in publications.keys) {
      _ensure(scope);
      _value(
        await client.put(
          path,
          publications[path]!,
          guard: () => _ensure(scope),
        ),
      );
      _ensure(scope);
    }
    // Syncthing may deliver deletions first; readers wait for complete checkpoints.
    final checkpoint =
        'checkpoints/${localDevice.deviceId}/${localDevice.deviceId}.json';
    if (publications.keys.contains(checkpoint)) {
      final rows = db.raw.select(
        'SELECT local_floor FROM sync_checkpoints WHERE author=?',
        [localDevice.deviceId],
      );
      if (rows.isNotEmpty) {
        _value(
          await client.pruneOperations(
            rows.single['local_floor'] as int,
            guard: () => _ensure(scope),
          ),
        );
      }
    }
  }

  Future<SyncOutcome> _pullFolderPeers(
    FolderTransport client,
    _LanScope scope,
    List<String> peers,
    EncryptedSegmentCodec codec,
    SyncSegmentReceiver receiver,
    int pushed,
  ) async {
    final contentCodec = _contentCodec(scope);
    final budget = SyncTransferBudget(remaining: 16 * 1024 * 1024);
    final waiting = <String>{};
    var pulled = 0;
    mediaPending = false;
    for (final peer in peers) {
      _ensure(scope);
      final content = SyncContentTransfer(
        contentCodec,
        client,
        budget,
        providerDeviceId: peer,
      );
      final checkpoints = SyncCheckpoints(
        db,
        content,
        _checkpointAuthorKeys(scope),
      );
      await checkpoints.pullLan();
      _ensure(scope);
      if (checkpoints.added > 0) {
        _needsReconciliation = true;
        await _reconcile();
      }
      final outcome = await _pullOperations(
        client,
        peer,
        scope,
        codec,
        receiver,
        0,
      );
      pulled += outcome.pulled + checkpoints.added;
      waiting.addAll(outcome.waitingPeers);
      final media = SyncMedia(
        db,
        content,
        Directory('${root.parent.path}/attachments'),
      );
      await media.pull();
      _ensure(scope);
      mediaPending |= media.pending || checkpoints.pending;
      if (media.completed > 0) {
        _needsReconciliation = true;
        await _reconcile();
      }
    }
    _contentFiles = await syncContentCatalog(db, contentCodec);
    await _exportFolder(client, scope);
    await _collectContentCache(contentCodec);
    mediaTransferredBytes = budget.transferred;
    return SyncOutcome(
      pulled: pulled,
      pushed: pushed,
      reclaimed: 0,
      peers: const [],
      waitingPeers: waiting.toList(),
      pendingObjects: receiver.pendingObjects,
    );
  }
}
