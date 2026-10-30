import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart'
    hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

Future<LanPeer> serve(RuntimeFixture f, Map<String, List<int>> files) async {
  final server = await LanHttpsServer.start(
    securityContext: runtimeTlsContext(),
    keys: f.a.keys,
    vaultPublicId: f.a.membership.state.vaultPublicId,
    tlsFingerprint: f.pin,
    publishedFiles: () => files,
    authorize: f.a.authorize,
  );
  addTearDown(server.close);
  return LanPeer(
    deviceId: f.a.keys.deviceId,
    host: '127.0.0.1',
    port: server.port,
    tlsFingerprint: f.pin,
  );
}

void main() {
  test('global segment sequence crosses month filenames over HTTPS', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(2);
    final operations = SyncPublisher(
      f.a.db,
      deviceId: f.a.keys.deviceId,
    ).freeze().operations;
    final codec = EncryptedSegmentCodec(
      vaultPublicId: f.a.membership.state.vaultPublicId,
      deviceKeys: f.a.keys,
      epochKeys: {1: f.a.epochKey.keyBytes},
      trustedSigners: {f.a.keys.deviceId: f.a.keys.signer.publicKey},
    );
    final files = Map<String, List<int>>.of(f.a.controls);
    for (final index in [1, 0]) {
      final segment = await codec.encode(
        Segment(
          deviceId: f.a.keys.deviceId,
          keyEpoch: 1,
          seq: index + 1,
          opCount: 1,
          sealed: true,
          createdAt: DateTime.utc(2026, 10 + index),
          payload: const [],
        ),
        [operations[index]],
      );
      files['ops/${f.a.keys.deviceId}/2026${10 + index}-000${index + 1}.log'] =
          segment.encode();
    }
    final peer = await serve(f, files);
    final result = await f.b.runtime.syncOnce(peer);
    expect(result.isOk, isTrue);
    expect(result.valueOrNull!.pulled, 2);
    expect(result.valueOrNull!.waitingPeers, isEmpty);
    expect(
      f.b.db.raw
          .select('SELECT applied_seq FROM sync_state')
          .single['applied_seq'],
      2,
    );
    files['ops/${f.a.keys.deviceId}/202612-0002.log'] = files.entries
        .firstWhere((entry) => entry.key.endsWith('-0002.log'))
        .value;
    expect((await f.b.runtime.syncOnce(peer)).isOk, isFalse);
    expect(
      f.b.db.raw.select('SELECT * FROM sync_received_segments'),
      hasLength(2),
    );
  });
  test(
    'missing epoch key still exchanges verified controls and reports waiting',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      f.a.addOperations(1);
      f.b.keyAvailable = false;
      await f.start();
      expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
      final waiting = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(waiting.isOk, isTrue);
      expect(waiting.valueOrNull!.waitingPeers, [f.a.keys.deviceId]);
      expect(f.b.ingested, 1);
      expect(f.b.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(
        f.b.runtime.publishedFiles(),
        contains('members/${f.b.keys.deviceId}.json'),
      );
      expect(
        f.b.runtime.publishedFiles().keys.where(
          (path) => path.startsWith('acks/'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'old epoch remains waiting without importing or advancing ACK',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      f.a.addOperations(1);
      await f.start();
      expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
      final rotation = await MembershipEvent.create(
        parent: f.b.membership.state,
        issuer: f.b.keys,
        type: MembershipEventType.rotate,
      );
      await f.b.membership.ingest(
        rotation,
        issuerFileDeviceId: f.b.keys.deviceId,
      );
      f.b.version = Object();
      f.b.epochKey = VaultKey(epoch: 2, keyBytes: List.filled(32, 42));
      final waiting = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(waiting.isOk, isTrue);
      expect(waiting.valueOrNull!.waitingPeers, [f.a.keys.deviceId]);
      expect(waiting.valueOrNull!.pulled, 0);
      expect(f.b.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(
        f.b.db.raw.select('SELECT * FROM sync_received_segments'),
        isEmpty,
      );
      expect(f.b.reconciled, 0);
      final ack = File(
        '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json',
      );
      expect(jsonDecode(await ack.readAsString()), isEmpty);
    },
  );
  test('out-of-order HTTPS listings stop at gaps and later import contiguous prefix', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(501);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final inventory = f.a.runtime.publishedFiles();
    final files = Map<String, List<int>>.of(inventory)
      ..removeWhere((path, _) => path.endsWith('-0001.log'));
    final peer = await serve(f, files);
    final gap = (await f.b.runtime.syncOnce(peer)).valueOrNull!;
    expect(gap.pulled, 0);
    expect(gap.waitingPeers, [f.a.keys.deviceId]);
    expect(f.b.db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    for (final entry in inventory.entries.toList().reversed) {
      files[entry.key] = entry.value;
    }
    final restored = (await f.b.runtime.syncOnce(peer)).valueOrNull!;
    expect(restored.pulled, 501);
    expect(restored.reclaimed, 0);
    expect(
      f.b.db.raw
          .select('SELECT applied_seq FROM sync_state')
          .single['applied_seq'],
      1,
    );
    final ack = File(
      '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json',
    );
    expect(jsonDecode(await ack.readAsString()), {f.a.keys.deviceId: 1});
  });
}
