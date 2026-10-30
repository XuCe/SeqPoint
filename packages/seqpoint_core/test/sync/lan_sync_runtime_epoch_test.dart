import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';

void main() {
  test('published sealed old head authenticates with history key before new epoch segment', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(500);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    await rotateRuntimePair(f);
    f.a.addOperations(1, start: 500);
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final imported = await f.b.runtime.syncOnce(f.peer(f.a));
    expect(imported.isOk, isTrue);
    expect(imported.valueOrNull!.pulled, 1);
    expect(imported.valueOrNull!.waitingPeers, isEmpty);
    expect(
      f.b.db.raw
          .select('SELECT key_epoch FROM sync_received_segments ORDER BY seq')
          .map((row) => row['key_epoch']),
      [1, 2],
    );
  });
  test('historical exact seal changes only receipt and watermark bookkeeping', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(2);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    await rotateRuntimePair(f);
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    f.b.db.raw.execute('UPDATE sync_local SET hlc_millis=0,hlc_counter=0');
    for (final mutation in ['INSERT', 'UPDATE', 'DELETE']) {
      f.b.db.raw.execute(
        'CREATE TEMP TRIGGER reject_${mutation.toLowerCase()} '
        'BEFORE $mutation ON sync_operations BEGIN SELECT RAISE(ABORT,\'facts touched\'); END',
      );
    }
    f.b.db.raw.execute(
      'CREATE TEMP TRIGGER reject_clock BEFORE UPDATE OF hlc_millis,hlc_counter,pending_count ON sync_local '
      "BEGIN SELECT RAISE(ABORT,'clock touched'); END",
    );
    final result = await f.b.runtime.syncOnce(f.peer(f.a));
    expect(result.isOk, isTrue);
    expect(result.valueOrNull!.pulled, 0);
    expect(result.valueOrNull!.waitingPeers, isEmpty);
    expect(
      f.b.db.raw
          .select('SELECT hlc_millis FROM sync_local')
          .single['hlc_millis'],
      0,
    );
    expect(
      f.b.db.raw
          .select('SELECT sealed FROM sync_received_segments')
          .single['sealed'],
      1,
    );
    expect(
      f.b.db.raw
          .select('SELECT applied_seq FROM sync_state')
          .single['applied_seq'],
      1,
    );
  });
  test('old unpublished preparation stays blocked while current inbound can commit', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(1);
    await f.start();
    f.a.segmentWriter = (_, _) async {
      throw FileSystemException('forced unpublished tail');
    };
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isFalse);
    final prepared = List<int>.of(
      f.a.db.raw
              .select(
                'SELECT segment_bytes '
                'FROM sync_publications',
              )
              .single['segment_bytes']
          as List<int>,
    );
    f.a.segmentWriter = null;
    await rotateRuntimePair(f);
    f.b.addOperations(1);
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isFalse);
    final row = f.a.db.raw.select('SELECT * FROM sync_publications').single;
    expect(row['published'], 0);
    expect(row['key_epoch'], 1);
    expect(row['segment_bytes'], prepared);
    expect(
      f.a.db.raw.select("SELECT * FROM sync_operations WHERE source='local'"),
      hasLength(1),
    );
    expect(
      f.a.db.raw.select("SELECT * FROM sync_operations WHERE source='remote'"),
      hasLength(1),
    );
    expect(
      f.a.runtime.publishedFiles().keys.where(
        (path) => path.startsWith('ops/'),
      ),
      isEmpty,
    );
    expect(
      Directory('${f.a.directory.path}/vault/ops/${f.a.keys.deviceId}')
          .listSync()
          .whereType<File>(),
      isEmpty,
    );
  });
  test('known exact old open tail seals over TLS before importing current epoch operations', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    final now = DateTime.utc(2026, 10, 26);
    final note = Note(
      id: 'epoch-note',
      kind: NoteKind.text,
      status: NoteStatus.active,
      rawContent: 'epoch one',
      createdAt: now,
      updatedAt: now,
    );
    NoteRepository(f.a.db).insert(note);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
    final originalCount = f.b.db.raw
        .select('SELECT * FROM sync_operations')
        .length;
    expect(
      f.b.db.raw
          .select('SELECT sealed FROM sync_received_segments')
          .single['sealed'],
      0,
    );
    await rotateRuntimePair(f);
    NoteRepository(f.a.db).update(note.copyWith(rawContent: 'epoch two'));
    final totalCount = f.a.db.raw
        .select('SELECT * FROM sync_operations')
        .length;
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final imported = await f.b.runtime.syncOnce(f.peer(f.a));
    expect(imported.isOk, isTrue);
    expect(imported.valueOrNull!.waitingPeers, isEmpty);
    expect(imported.valueOrNull!.pulled, totalCount - originalCount);
    expect(NoteRepository(f.b.db).byId(note.id)!.rawContent, 'epoch two');
    expect(
      f.b.db.raw.select('SELECT * FROM sync_operations'),
      hasLength(totalCount),
    );
    final receipts = f.b.db.raw.select(
      'SELECT * FROM sync_received_segments ORDER BY seq',
    );
    expect(receipts.map((row) => row['key_epoch']), [1, 2]);
    expect(receipts.map((row) => row['sealed']), [1, 0]);
    final ack = File(
      '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json',
    );
    expect(jsonDecode(await ack.readAsString()), {f.a.keys.deviceId: 1});
    final replay = await f.b.runtime.syncOnce(f.peer(f.a));
    expect(replay.valueOrNull!.pulled, 0);
    expect(replay.valueOrNull!.waitingPeers, isEmpty);
  });
}
