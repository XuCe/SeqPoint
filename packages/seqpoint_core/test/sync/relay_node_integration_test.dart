import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'relay_node_fixture.dart';

void main() {
  test(
    'offline A upload, node restart, offline B reply, A receives, retry deduplicates',
    () async {
      final f = RelayNodeFixture();
      await f.init();
      addTearDown(f.close);
      final a = f.runtime.a, b = f.runtime.b;
      final now = DateTime.utc(2026, 10, 30);
      NoteRepository(a.db).insert(
        Note(
          id: 'cloud-note',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'A offline message',
          createdAt: now,
          updatedAt: now,
        ),
      );
      final upload = await a.runtime.syncRelay(f.client(a));
      expect(upload.isOk, isTrue, reason: '$upload');
      await a.runtime.pause();
      await f.stop();
      await f.start();
      final receive = await b.runtime.syncRelay(f.client(b));
      expect(
        receive.isOk,
        isTrue,
        reason: receive is Err ? '${(receive as Err).cause}' : null,
      );
      expect(
        NoteRepository(b.db).byId('cloud-note')?.rawContent,
        'A offline message',
      );
      NoteRepository(b.db).insert(
        Note(
          id: 'reply',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'B replies later',
          createdAt: now,
          updatedAt: now,
        ),
      );
      expect((await b.runtime.syncRelay(f.client(b))).isOk, isTrue);
      await b.runtime.pause();
      a.runtime.resume();
      expect((await a.runtime.syncRelay(f.client(a))).isOk, isTrue);
      expect(NoteRepository(a.db).byId('reply')?.rawContent, 'B replies later');
      final count = a.db.raw
          .select('SELECT COUNT(*) AS n FROM sync_operations')
          .single['n'];
      final retry = await a.runtime.syncRelay(f.client(a));
      expect(retry.isOk, isTrue);
      expect((retry as Ok<SyncOutcome>).value.pulled, 0);
      expect(
        a.db.raw
            .select('SELECT COUNT(*) AS n FROM sync_operations')
            .single['n'],
        count,
      );
    },
    skip: Platform.environment['SEQPOINT_NODE_BINARY'] == null
        ? 'Set SEQPOINT_NODE_BINARY to compiled node'
        : false,
  );
  test(
    'failed upload keeps committed publication retryable',
    () async {
      final f = RelayNodeFixture();
      await f.init();
      addTearDown(f.close);
      final a = f.runtime.a, b = f.runtime.b;
      final now = DateTime.utc(2026, 10, 30);
      NoteRepository(a.db).insert(
        Note(
          id: 'retry',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'survives network failure',
          createdAt: now,
          updatedAt: now,
        ),
      );
      a.segmentWriter = (file, bytes) async {
        await file.writeAsBytes(bytes, flush: true);
        await f.stop();
      };
      expect(await a.runtime.syncRelay(f.client(a)), isA<Err<SyncOutcome>>());
      expect(
        a.db.raw.select('SELECT 1 FROM sync_publications WHERE published=1'),
        isNotEmpty,
      );
      a.segmentWriter = null;
      await f.start();
      expect((await a.runtime.syncRelay(f.client(a))).isOk, isTrue);
      expect((await b.runtime.syncRelay(f.client(b))).isOk, isTrue);
      expect(
        NoteRepository(b.db).byId('retry')?.rawContent,
        'survives network failure',
      );
      final client = f.client(a);
      addTearDown(client.close);
      expect((await client.get('checkpoints/${a.keys.deviceId}.json')).isOk,isTrue);
      final usage = await client.usedBytes();
      expect((usage as Ok<int>).value, greaterThan(0));
      expect(
        (await client.list(
          'ops/${a.keys.deviceId}',
        ) as Ok<List<RemoteFile>>).value,
        isEmpty,
      );
    },
    skip: Platform.environment['SEQPOINT_NODE_BINARY'] == null
        ? 'Set SEQPOINT_NODE_BINARY to compiled node'
        : false,
  );
}
