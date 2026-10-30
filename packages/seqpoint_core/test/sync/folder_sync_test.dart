import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

void main() {
  late RuntimeFixture f;
  late Directory shared;
  late FolderTransport a, b;
  setUp(() async {
    f = RuntimeFixture();
    await f.init();
    shared = await Directory('${f.root.path}/shared').create();
    a = FolderTransport(shared, writerDeviceId: f.a.keys.deviceId);
    b = FolderTransport(shared, writerDeviceId: f.b.keys.deviceId);
  });
  tearDown(() => f.dispose());
  test(
    'missing attachment chunk preserves text and retries without data loss',
    () async {
      final now = DateTime.now().toUtc();
      NoteRepository(f.a.db).insert(
        Note(
          id: 'media',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'with image',
          createdAt: now,
          updatedAt: now,
        ),
      );
      AttachmentSyncPolicy(f.a.db).setEnabled(true);
      AttachmentSyncPolicy(f.b.db).setEnabled(true);
      final source = AttachmentService(
        db: f.a.db,
        directory: Directory('${f.a.directory.path}/attachments'),
      );
      final bytes = Uint8List.fromList([
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        ...List.filled(1200000, 42),
      ]);
      final image = await source.addImage(bytes, noteId: 'media');
      _ok(await f.a.runtime.syncFolder(a));
      final files = (await a.list('content/${f.a.keys.deviceId}')).valueOrNull!;
      final chunk = files.firstWhere((f) => f.name.endsWith('.bin'));
      final path = 'content/${f.a.keys.deviceId}/${chunk.name}';
      final encrypted = (await a.get(path)).valueOrNull!;
      await a.delete(path);
      _ok(await f.b.runtime.syncFolder(b));
      expect(NoteRepository(f.b.db).byId('media')!.rawContent, 'with image');
      expect(f.b.runtime.mediaPending, isTrue);
      final destination = File('${f.b.directory.path}/attachments/${image.id}');
      expect(await destination.exists(), isFalse);
      await a.put(path, encrypted);
      _ok(await f.b.runtime.syncFolder(b));
      expect(await destination.readAsBytes(), bytes);
      expect(f.b.runtime.mediaPending, isFalse);
    },
  );
  test(
    'missing sealed segment waits without losing history, then retries',
    () async {
      f.a.addOperations(1);
      _ok(await f.a.runtime.syncFolder(a));
      f.a.addOperations(1, start: 1);
      _ok(await f.a.runtime.syncFolder(a));
      final files = (await a.list('ops/${f.a.keys.deviceId}')).valueOrNull!;
      expect(files.length, 2);
      final first = 'ops/${f.a.keys.deviceId}/${files.first.name}';
      final saved = (await a.get(first)).valueOrNull!;
      await a.delete(first);
      final waiting = await f.b.runtime.syncFolder(b);
      _ok(waiting);
      expect(waiting.valueOrNull!.waitingPeers, contains(f.a.keys.deviceId));
      expect(
        f.b.db.raw.select('SELECT * FROM sync_received_segments'),
        isEmpty,
      );
      await a.put(first, saved);
      final retry = await f.b.runtime.syncFolder(b);
      _ok(retry);
      expect(retry.valueOrNull!.pulled, 2);
      expect(
        f.b.db.raw.select('SELECT * FROM sync_received_segments'),
        hasLength(2),
      );
    },
  );
  test('writer mismatch and stopped runtime cannot publish', () async {
    expect((await f.a.runtime.syncFolder(b)).isOk, isFalse);
    expect(await shared.list().isEmpty, isTrue);
    await f.a.runtime.stop();
    expect((await f.a.runtime.syncFolder(a)).isOk, isFalse);
  });
  test(
    'encrypted directory merges A to B to A and never exports raw data',
    () async {
      final now = DateTime.utc(2026, 10, 30);
      NoteRepository(f.a.db).insert(
        Note(
          id: 'n1',
          kind: NoteKind.text,
          status: NoteStatus.active,
          rawContent: 'private-note-from-a',
          createdAt: now,
          updatedAt: now,
        ),
      );
      _ok(await f.a.runtime.syncFolder(a));
      _ok(await f.b.runtime.syncFolder(b));
      final note = NoteRepository(f.b.db).byId('n1')!;
      expect(note.rawContent, 'private-note-from-a');
      NoteRepository(f.b.db).update(
        note.copyWith(
          rawContent: 'private-edit-from-b',
          updatedAt: now.add(const Duration(seconds: 1)),
        ),
      );
      _ok(await f.b.runtime.syncFolder(b));
      _ok(await f.a.runtime.syncFolder(a));
      expect(
        NoteRepository(f.a.db).byId('n1')!.rawContent,
        'private-edit-from-b',
      );
      expect((await f.a.runtime.syncFolder(a)).valueOrNull!.pulled, 0);
      await for (final file in shared.list(
        recursive: true,
        followLinks: false,
      )) {
        if (file is! File) continue;
        expect(file.path, isNot(contains('sqlite')));
        final text = utf8.decode(
          await file.readAsBytes(),
          allowMalformed: true,
        );
        expect(text, isNot(contains('private-note-from-a')));
        expect(text, isNot(contains('private-edit-from-b')));
      }
    },
  );
}

void _ok(Result<SyncOutcome> result) => expect(
  result.isOk,
  isTrue,
  reason: result is Err<SyncOutcome> ? '${result.cause}' : null,
);
