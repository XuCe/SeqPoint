import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root; late SeqDatabase a, b; late DeviceKeys ka, kb;
  late VaultStore sa, sb; late SyncPublisher pa, pb; late FakeClock clock;
  VaultStore store(DeviceKeys keys) => VaultStore(root: Directory('${root.path}/vault'),
      deviceId: keys.deviceId, codec: EncryptedSegmentCodec(vaultPublicId: 'round-trip',
        deviceKeys: keys, epochKeys: {1: List.filled(32, 7)}, trustedSigners: {
          ka.deviceId: ka.signer.publicKey, kb.deviceId: kb.signer.publicKey,
        }));
  SyncEngine engine(SeqDatabase db, VaultStore store) =>
      SyncEngine.persistent(store: store, receiver: SyncSegmentReceiver(db, clock: clock));
  void note(SeqDatabase db, String id) => NoteRepository(db, clock: clock).insert(Note(
      id: id, kind: NoteKind.text, status: NoteStatus.active, rawContent: id,
      createdAt: clock.now(), updatedAt: clock.now()));
  void publishers() {
    pa = SyncPublisher(a, deviceId: ka.deviceId, clock: clock);
    pb = SyncPublisher(b, deviceId: kb.deviceId, clock: clock);
  }
  setUp(() async {
    root = Directory.systemTemp.createTempSync('publisher-round-trip-');
    a = SeqDatabase.open('${root.path}/a.sqlite')..migrate();
    b = SeqDatabase.open('${root.path}/b.sqlite')..migrate();
    ka = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    kb = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    clock = FakeClock(DateTime.utc(2026, 10, 31)); note(a, 'n1'); note(b, 'n2');
    SyncBaseline(a, clock: clock).initialize(ka.deviceId);
    SyncBaseline(b, clock: clock).initialize(kb.deviceId);
    sa = store(ka); sb = store(kb); publishers();
  });
  tearDown(() async { await pa.stop(); await pb.stop(); a.close(); b.close(); root.deleteSync(recursive: true); });
  test('存量基线经事务发布器双向加密接收，开放段不提前ACK且不回声发布', () async {
    await pa.publishNext(store: sa, keyEpoch: 1); await pb.publishNext(store: sb, keyEpoch: 1);
    for (final e in [engine(a, sa), engine(b, sb)]) {
      final result = await e.syncOnce(); expect(result.isOk, isTrue);
      expect(result.valueOrNull!.pendingObjects, 0);
    }
    for (final db in [a, b]) { expect(NoteRepository(db).active().map((n) => n.id), unorderedEquals(['n1', 'n2'])); }
    expect(await sa.readAck(ka.deviceId), isEmpty); expect(await sb.readAck(kb.deviceId), isEmpty);
    expect(await pa.publishNext(store: sa, keyEpoch: 1), isNull);
    expect(await pb.publishNext(store: sb, keyEpoch: 1), isNull);
  });
  test('双向并发字段经真实发布器收敛，封口后ACK且两端重开无重复', () async {
    await pa.publishNext(store: sa, keyEpoch: 1); await pb.publishNext(store: sb, keyEpoch: 1);
    await engine(a, sa).syncOnce(); await engine(b, sb).syncOnce();
    final ar = NoteRepository(a, clock: clock), br = NoteRepository(b, clock: clock);
    ar.update(ar.byId('n1')!.copyWith(rawContent: '电脑正文'));
    br.update(br.byId('n1')!.copyWith(title: '手机标题'));
    final at = (await pa.publishNext(store: sa, keyEpoch: 1))!;
    final bt = (await pb.publishNext(store: sb, keyEpoch: 1))!;
    for (final entry in [(sa, ka.deviceId, at), (sb, kb.deviceId, bt)]) {
      final ops = await entry.$1.codec.decode(Segment.decode(entry.$3.bytes));
      expect(ops.every((op) => op.deviceId == entry.$2), isTrue);
    }
    for (final e in [engine(a, sa), engine(b, sb)]) { expect((await e.syncOnce()).isOk, isTrue); }
    for (final db in [a, b]) {
      final note = NoteRepository(db).byId('n1')!;
      expect(note.rawContent, '电脑正文'); expect(note.title, '手机标题');
    }
    clock.set(DateTime.utc(2026, 11, 1));
    expect((await pa.publishNext(store: sa, keyEpoch: 1))!.sealed, isTrue);
    expect((await pb.publishNext(store: sb, keyEpoch: 1))!.sealed, isTrue);
    for (final e in [engine(a, sa), engine(b, sb)]) { expect((await e.syncOnce()).isOk, isTrue); }
    expect(await sa.readAck(ka.deviceId), {kb.deviceId: 1});
    expect(await sb.readAck(kb.deviceId), {ka.deviceId: 1});
    final counts = [a, b].map((db) => db.raw.select('SELECT COUNT(*) AS n FROM sync_operations').single['n']).toList();
    await pa.stop(); await pb.stop(); a.close(); b.close();
    a = SeqDatabase.open('${root.path}/a.sqlite')..migrate();
    b = SeqDatabase.open('${root.path}/b.sqlite')..migrate(); publishers();
    for (final e in [engine(a, sa), engine(b, sb)]) {
      final result = (await e.syncOnce()).valueOrNull!;
      expect(result.pulled, 0); expect(result.pendingObjects, 0);
    }
    expect([a, b].map((db) => db.raw.select('SELECT COUNT(*) AS n FROM sync_operations').single['n']), counts);
    expect(await pa.publishNext(store: sa, keyEpoch: 1), isNull);
    expect(await pb.publishNext(store: sb, keyEpoch: 1), isNull);
  });
}
