import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

void main() {
  test(
    'offline peer waits for checkpoint chunks before committing or pruning',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      final shared = Directory('${f.root.path}/shared');
      final a = FolderTransport(shared, writerDeviceId: f.a.keys.deviceId);
      final repo = NoteRepository(f.a.db), now = DateTime.now().toUtc();
      repo.insert(
        Note(
          id: 'checkpoint',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'initial',
          createdAt: now,
          updatedAt: now,
        ),
      );
      for (var i = 0; i < 100; i++) {
        repo.update(
          repo.byId('checkpoint')!.copyWith(rawContent: 'version $i'),
        );
        final result = await f.a.runtime.syncFolder(a);
        expect(
          result.isOk,
          isTrue,
          reason: result is Err ? '${(result as Err).cause}' : null,
        );
      }
      expect(
        f.a.db.raw.select('SELECT * FROM sync_publications'),
        hasLength(1),
      );
      final incoming = Directory('${f.root.path}/incoming');
      expect(
        (await a.list('ops/${f.a.keys.deviceId}')).valueOrNull,
        hasLength(1),
      );
      final publisher = FolderTransport(
        incoming,
        writerDeviceId: f.a.keys.deviceId,
      );
      final b = FolderTransport(incoming, writerDeviceId: f.b.keys.deviceId);
      final publications = f.a.runtime.publishedFiles();
      for (final path in publications.keys) {
        expect((await publisher.put(path, publications[path]!)).isOk, isTrue);
      }
      final missing = publications.keys.firstWhere((p) => p.endsWith('.bin'));
      final saved = publications[missing]!;
      await publisher.delete(missing);
      expect((await f.b.runtime.syncFolder(b)).isOk, isTrue);
      expect(f.b.runtime.mediaPending, isTrue);
      expect(NoteRepository(f.b.db).byId('checkpoint'), isNull);
      expect(f.b.db.raw.select('SELECT * FROM sync_checkpoints'), isEmpty);
      await publisher.put(missing, saved);
      final retry = await f.b.runtime.syncFolder(b);
      expect(
        retry.isOk,
        isTrue,
        reason: retry is Err ? '${(retry as Err).cause}' : null,
      );
      expect(
        NoteRepository(f.b.db).byId('checkpoint')!.rawContent,
        'version 99',
      );
      expect(
        SyncSegmentReceiver(f.b.db).committedWatermarks[f.a.keys.deviceId],
        100,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
