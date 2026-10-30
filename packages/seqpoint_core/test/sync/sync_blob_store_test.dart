import 'dart:io';
import 'dart:convert';

import 'package:seqpoint_core/src/crypto/xchacha20_aead.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';

import 'dart:math';

import 'package:seqpoint_core/src/sync/sync_blob_store.dart';
import 'package:test/test.dart';

void main() {
  test('compressed encrypted chunks survive restart and deduplicate without quality loss', () async {
    final root = await Directory.systemTemp.createTemp('sync-blobs-');
    addTearDown(() => root.delete(recursive: true));
    SyncBlobStore store() => SyncBlobStore(
      root: root,
      vaultId: 'v' * 43,
      deviceId: 'a' * 43,
      epochKeys: {1: List.filled(32, 7)},
    );
    final plain = List.filled(100000, 65);
    final chunk = await store().encode(plain, epoch: 1);
    expect(chunk.codec, 'gzip');
    expect(chunk.size, lessThan(plain.length ~/ 10));
    expect(await store().decode(chunk), plain);
    final again = await store().encode(plain, epoch: 1);
    expect(again.hash, chunk.hash);
    final random = Random(42),
        noise = List.generate(10000, (_) => random.nextInt(256));
    final raw = await store().encode(noise, epoch: 1);
    expect(raw.codec, 'raw');
    expect(await store().decode(raw), noise);
    await File('${root.path}/${chunk.path}').writeAsBytes([1, 2, 3]);
    await expectLater(store().decode(chunk), throwsA(isA<Exception>()));
    final repaired=await store().encode(plain,epoch:1);
    expect(repaired.hash,isNot(chunk.hash));
    expect(await store().decode(repaired),plain);
  });
  test(
    'rejects validly encrypted decompression bombs and wrong vaults',
    () async {
      final root = await Directory.systemTemp.createTemp('blob-bounds-');
      addTearDown(() => root.delete(recursive: true));
      final key = List.filled(32, 7),
          owner = 'a' * 43,
          vault = 'v' * 43,
          hash = lanSha256([0]);
      final store = SyncBlobStore(
        root: root,
        vaultId: vault,
        deviceId: owner,
        epochKeys: {1: key},
      );
      final frame = await XChaCha20Aead().seal(
        gzip.encode(List.filled(100000, 0)),
        key,
        aad: utf8.encode(
          ['seqpoint-blob-v2', vault, owner, 1, hash, 1, 'gzip'].join('\n'),
        ),
      );
      final bomb = SyncBlobChunk(
        owner: owner,
        epoch: 1,
        hash: lanSha256(frame),
        plainHash: hash,
        plainSize: 1,
        size: frame.length,
        codec: 'gzip',
      );
      await store.saveFrame(bomb, frame);
      await expectLater(store.decode(bomb), throwsFormatException);
      final normal = await store.encode([1, 2, 3], epoch: 1);
      final wrong = SyncBlobStore(
        root: root,
        vaultId: 'w' * 43,
        deviceId: owner,
        epochKeys: {1: key},
      );
      await expectLater(wrong.decode(normal), throwsStateError);
    },
  );
  test('pause during worker encryption leaves no late cache commit', () async {
    final root = await Directory.systemTemp.createTemp('blob-stop-');
    addTearDown(() => root.delete(recursive: true));
    var active = true;
    final store = SyncBlobStore(
      root: root,
      vaultId: 'v' * 43,
      deviceId: 'a' * 43,
      epochKeys: {1: List.filled(32, 7)},
      guard: () {
        if (!active) {
          throw StateError('paused');
        }
      },
    );
    final pending = store.encode(List.filled(100000, 0), epoch: 1);
    active = false;
    await expectLater(pending, throwsStateError);
    expect(await root.list(recursive: true).toList(), isEmpty);
  });
}
