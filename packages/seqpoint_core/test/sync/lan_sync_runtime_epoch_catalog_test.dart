import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';

void main() {
  test('catalog authenticates old sealed publications and excludes old open or unpublished bytes', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(500);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    await rotateRuntimePair(f);
    f.a.addOperations(1, start: 500);
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final snapshot = f.a.snapshot()!;
    final catalog = SyncPublicationCatalog(
      f.a.db,
      deviceId: f.a.keys.deviceId,
      policy: snapshot.policy,
    );
    addTearDown(catalog.stop);
    EncryptedSegmentCodec codec(Map<int, List<int>> keys) =>
        EncryptedSegmentCodec(
          vaultPublicId: f.a.membership.state.vaultPublicId,
          deviceKeys: f.a.keys,
          epochKeys: keys,
          trustedSigners: {f.a.keys.deviceId: f.a.keys.signer.publicKey},
        );
    await expectLater(
      catalog.refresh(codec: codec({2: f.a.epochKey.keyBytes})),
      throwsStateError,
    );
    expect(catalog.snapshot(), isEmpty);
    final full = codec(snapshot.epochKeys);
    await catalog.refresh(codec: full);
    expect(catalog.snapshot(), hasLength(2));
    final old = f.a.db.raw
        .select('SELECT * FROM sync_publications WHERE seq=1')
        .single;
    final sealed = Segment.decode(old['segment_bytes'] as List<int>);
    final open = await full.encode(
      Segment(
        deviceId: sealed.deviceId,
        keyEpoch: 1,
        seq: 1,
        opCount: sealed.opCount,
        createdAt: sealed.createdAt,
        payload: const [],
        sealed: false,
      ),
      await full.decode(sealed),
    );
    f.a.db.raw.execute(
      'UPDATE sync_publications SET sealed=0,segment_bytes=? WHERE seq=1',
      [open.encode()],
    );
    await catalog.refresh(codec: full);
    expect(catalog.snapshot(), hasLength(1));
    f.a.db.raw.execute(
      'UPDATE sync_publications SET sealed=1,published=0,segment_bytes=? WHERE seq=1',
      [sealed.encode()],
    );
    await catalog.refresh(codec: full);
    expect(catalog.snapshot(), hasLength(1));
  });
}
