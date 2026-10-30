import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

void main() {
  test(
    'pause rejects rounds and resume can explicitly restart its HTTPS server',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      await f.start();
      await f.b.runtime.pause();
      expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
      expect(f.b.runtime.publishedFiles(), isEmpty);
      f.b.runtime.resume();
      f.ports[f.b.keys.deviceId] = await f.b.runtime.startServer(
        securityContext: runtimeTlsContext(),
        tlsFingerprint: f.pin,
      );
      expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    },
  );
  test('committed reconciliation failure retries before acknowledging on next round', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(1);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    f.b.afterCommit = () async {
      throw StateError('forced reminder failure');
    };
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
    expect(f.b.db.raw.select('SELECT * FROM sync_operations'), hasLength(1));
    expect(
      File('${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json')
          .existsSync(),
      isFalse,
    );
    f.b.afterCommit = null;
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    expect(f.b.reconciled, 2);
  });
  for (final change in ['membership', 'disabled', 'stop']) {
    test(
      'final segment IO fence blocks $change before published rename',
      () async {
        final f = RuntimeFixture();
        await f.init();
        addTearDown(f.dispose);
        f.a.addOperations(1);
        await f.start();
        final entered = Completer<void>(), release = Completer<void>();
        f.a.segmentWriter = (file, bytes) async {
          entered.complete();
          await release.future;
          await file.writeAsBytes(bytes, flush: true);
        };
        final accepted = f.a.runtime.syncOnce(f.peer(f.b));
        await entered.future;
        Future<void>? stopping;
        var stopped = false;
        if (change == 'membership') {
          f.a.ready = false;
          f.a.version = Object();
        }
        if (change == 'disabled') {
          f.a.db.raw.execute('UPDATE sync_local SET enabled=0');
        }
        if (change == 'stop') {
          stopping = f.a.runtime.stop().then((_) {
            stopped = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(stopped, isFalse);
        }
        release.complete();
        expect((await accepted).isOk, isFalse);
        await stopping;
        expect(
          f.a.db.raw
              .select('SELECT published FROM sync_publications')
              .single['published'],
          0,
        );
        expect(f.a.runtime.publishedFiles(), isEmpty);
        expect(
          Directory('${f.a.directory.path}/vault/ops/${f.a.keys.deviceId}')
              .listSync()
              .whereType<File>(),
          isEmpty,
        );
      },
    );
  }
  test(
    'control save failure blocks inbound business and ACK publication',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      f.a.addOperations(1);
      await f.start();
      expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
      f.b.beforeSave = () async {
        throw FileSystemException('forced control failure');
      };
      final result = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(result.isOk, isFalse);
      expect(f.b.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(
        f.b.db.raw.select('SELECT * FROM sync_received_segments'),
        isEmpty,
      );
      expect(f.b.runtime.publishedFiles(), isEmpty);
      expect(
        File('${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json')
            .existsSync(),
        isFalse,
      );
    },
  );

  test('stop drains accepted control save, rejects rounds and leaves no late import', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(1);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final entered = Completer<void>(), release = Completer<void>();
    f.b.beforeSave = () async {
      entered.complete();
      await release.future;
    };
    final accepted = f.b.runtime.syncOnce(f.peer(f.a));
    await entered.future;
    var stopped = false;
    final stop = f.b.runtime.stop().then((_) {
      stopped = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(stopped, isFalse);
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
    release.complete();
    await stop;
    expect((await accepted).isOk, isFalse);
    expect(f.b.ingested, 1);
    expect(f.b.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(f.b.runtime.publishedFiles(), isEmpty);
    expect(() => f.b.runtime.resume(), throwsStateError);
  });
  test(
    'two disk databases persist outbox over pinned TLS and survive reopen',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      final now = DateTime.utc(2026, 10, 25);
      NoteRepository(f.a.db).insert(
        Note(
          id: 'n1',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'TLS committed',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await f.start();
      final publication = await f.a.runtime.syncOnce(f.peer(f.b));
      expect(
        publication.isOk,
        isTrue,
        reason: publication is Err<SyncOutcome> ? '${publication.cause}' : null,
      );
      final imported = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(imported.isOk, isTrue);
      expect(imported.valueOrNull!.pulled, greaterThan(0));
      expect(imported.valueOrNull!.reclaimed, 0);
      expect(NoteRepository(f.b.db).byId('n1')!.rawContent, 'TLS committed');
      expect(f.b.reconciled, 1);
      expect(f.b.ingested, 1);
      final ackPath =
          '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json';
      expect(jsonDecode(await File(ackPath).readAsString()), isEmpty);
      expect(
        f.b.runtime.publishedFiles(),
        contains('acks/${f.b.keys.deviceId}.json'),
      );
      final duplicate = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(duplicate.valueOrNull!.pulled, 0);
      expect(f.b.reconciled, 1);
      await f.b.runtime.stop();
      f.b.db.close();
      await f.b.open();
      expect(NoteRepository(f.b.db).byId('n1')!.rawContent, 'TLS committed');
      expect(
        f.b.db.raw.select('SELECT * FROM sync_received_segments'),
        hasLength(1),
      );
    },
  );
}
