import 'dart:async';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late DeviceKeys keys;
  late SyncPublisher publisher;
  late EncryptedSegmentCodec codec;
  setUp(() async {
    db = SeqDatabase.inMemory()..migrate();
    keys = await DeviceKeys.fromSeeds(List.filled(32, 5), List.filled(32, 6));
    NoteRepository(db).insert(Note(id: 'n1', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '待发布基线', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    SyncBaseline(db, clock: FakeClock(DateTime.utc(2026, 10, 25))).initialize(keys.deviceId);
    publisher = SyncPublisher(db, deviceId: keys.deviceId,
        clock: FakeClock(DateTime.utc(2026, 10, 25)));
    codec = EncryptedSegmentCodec(vaultPublicId: 'v1', deviceKeys: keys,
        epochKeys: {1: List.filled(32, 7)}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
  });
  tearDown(() => db.close());
  test('真实加密换epoch先以旧密钥封口，确认后才用新密钥和下一序号', () async {
    final rotated = EncryptedSegmentCodec(vaultPublicId: 'v1', deviceKeys: keys,
        epochKeys: {1: List.filled(32, 7), 2: List.filled(32, 8)},
        trustedSigners: {keys.deviceId: keys.signer.publicKey});
    final first = (await publisher.prepare(codec: rotated, keyEpoch: 1))!;
    db.raw.execute('UPDATE sync_publications SET published=1');
    NoteRepository(db).insert(Note(id: 'n2', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '新epoch内容', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    final sealed = (await publisher.prepare(codec: rotated, keyEpoch: 2))!;
    expect(sealed.seq, 1); expect(sealed.keyEpoch, 1); expect(sealed.sealed, isTrue);
    expect(sealed.fileName, first.fileName); expect(sealed.header.createdAt, first.header.createdAt);
    expect((await rotated.decode(Segment.decode(sealed.bytes))).every((op) => op.objectId == 'n1'), isTrue);
    db.raw.execute('UPDATE sync_publications SET published=1');
    final next = (await publisher.prepare(codec: rotated, keyEpoch: 2))!;
    expect(next.seq, 2); expect(next.keyEpoch, 2); expect(next.published, isFalse);
    expect((await rotated.decode(Segment.decode(next.bytes))).every((op) => op.objectId == 'n2'), isTrue);
    expect(db.raw.select("SELECT 1 FROM sync_operations WHERE object_id='n2' AND publication_seq=2"), isNotEmpty);
  });
  test('未知编码epoch失败不生成publication或绑定操作', () async {
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 2), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
    expect(db.raw.autocommit, isTrue);
  });
  test('已有密文篡改认证失败，保留现场字节且不重编码', () async {
    final saved = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
    final segment = Segment.decode(saved.bytes);
    final payload = [...segment.payload]; payload[0] ^= 1;
    final tampered = segment.withPayload(payload, signature: segment.signature).encode();
    db.raw.execute('UPDATE sync_publications SET segment_bytes=?', [tampered]);
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 1), throwsStateError);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], tampered);
    expect(db.raw.select('SELECT published FROM sync_publications').single['published'], 0);
    expect(db.raw.autocommit, isTrue);
  });
  test('只有新epoch密钥时不能绕过旧prepared认证', () async {
    final saved = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
    final rotated = EncryptedSegmentCodec(vaultPublicId: 'v1', deviceKeys: keys,
        epochKeys: {2: List.filled(32, 8)}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
    await expectLater(publisher.prepare(codec: rotated, keyEpoch: 2), throwsStateError);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], saved.bytes);
    expect(db.raw.autocommit, isTrue);
  });
  test('冻结后在事务外认证编码，prepared原子保存原bytes并绑定冻结操作', () async {
    final frozen = publisher.freeze();
    expect(db.raw.autocommit, isTrue);
    final prepared = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
    expect(db.raw.autocommit, isTrue);
    expect(prepared.seq, 1); expect(prepared.published, isFalse);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'],
        prepared.bytes);
    expect(() => prepared.bytes[0] = 0, throwsUnsupportedError);
    expect((await codec.decode(Segment.decode(prepared.bytes))).map((op) => op.opId),
        frozen.operations.map((op) => op.opId));
    expect(db.raw.select('SELECT publication_seq FROM sync_operations')
        .every((row) => row['publication_seq'] == 1), isTrue);
  });

  test('编码期间真实仓储新写入留在下一批，不混入已冻结字节', () async {
    final before = publisher.freeze().operations.length;
    final prepared = (await publisher.prepare(keyEpoch: 1, codec: DuringEncode(codec, () async {
      expect(db.raw.autocommit, isTrue);
      NoteRepository(db).insert(Note(id: 'n2', kind: NoteKind.text, status: NoteStatus.active,
          rawContent: '编码后新增', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    })))!;
    expect(prepared.header.opCount, before);
    expect((await codec.decode(Segment.decode(prepared.bytes))).every((op) => op.objectId == 'n1'), isTrue);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), isNotEmpty);
  });

  test('编码期间外层事务插入不能被SAVEPOINT当作独立提交', () async {
    await expectLater(publisher.prepare(keyEpoch: 1, codec: DuringEncode(codec, () async {
      db.raw.execute('BEGIN');
    })), throwsStateError);
    expect(db.raw.autocommit, isFalse);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    db.raw.execute('ROLLBACK');
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
  });

  test('并发冻结同一版本只有先提交者成功，陈旧编码不能覆盖原bytes', () async {
    final entered = Completer<void>(), resume = Completer<void>();
    final first = publisher.prepare(keyEpoch: 1, codec: DuringEncode(codec, () async {
      entered.complete(); await resume.future;
    }));
    await entered.future;
    final second = (await SyncPublisher(db, deviceId: keys.deviceId).prepare(codec: codec, keyEpoch: 1))!;
    final rejected = expectLater(first, throwsStateError);
    resume.complete(); await rejected;
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], second.bytes);
    expect(db.raw.select('SELECT * FROM sync_publications'), hasLength(1));
  });

  test('绑定中途SQL失败同时回滚publication和此前绑定，修复后可重试', () async {
    db.raw.execute('CREATE TEMP TRIGGER fail_binding BEFORE UPDATE OF publication_seq ON sync_operations '
        "WHEN OLD.hlc_counter>0 BEGIN SELECT RAISE(ABORT,'injected'); END");
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 1), throwsA(isA<Exception>()));
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
    db.raw.execute('DROP TRIGGER fail_binding');
    expect(await publisher.prepare(codec: codec, keyEpoch: 1), isNotNull);
  });

  test('编码期间关闭/换身份/丢失ready/恢复断开均拒绝prepared', () async {
    for (final change in [
      () => db.raw.execute('UPDATE sync_local SET enabled=0'),
      () => db.raw.execute("UPDATE sync_local SET device_id='other'"),
      () => db.raw.execute('UPDATE sync_local SET baseline_ready=0'),
      () => db.disconnectSyncForRestore(),
    ]) {
      db.raw.execute('UPDATE sync_local SET device_id=?,enabled=1,baseline_ready=1,requires_new_identity=0', [keys.deviceId]);
      await expectLater(publisher.prepare(keyEpoch: 1, codec: DuringEncode(codec, () async { change(); })), throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
      expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
    }
  });

  test('临时WAL双连接并发CAS及重开保留原prepared，后续新增不误绑定', () async {
    final root = Directory.systemTemp.createTempSync('publisher-cas-');
    final path = '${root.path}/test.db';
    final firstDb = SeqDatabase.open(path)..migrate();
    firstDb.raw.execute('PRAGMA journal_mode=WAL');
    final other = SeqDatabase.open(path)..migrate();
    try {
      SyncBaseline(firstDb).initialize(keys.deviceId);
      NoteRepository(firstDb).insert(Note(id: 'disk', kind: NoteKind.text, status: NoteStatus.active,
          rawContent: '临时数据', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
      final entered = Completer<void>(), resume = Completer<void>();
      final stale = SyncPublisher(firstDb, deviceId: keys.deviceId).prepare(keyEpoch: 1,
          codec: DuringEncode(codec, () async { entered.complete(); await resume.future; }));
      await entered.future;
      final saved = (await SyncPublisher(other, deviceId: keys.deviceId).prepare(codec: codec, keyEpoch: 1))!;
      NoteRepository(other).insert(Note(id: 'later', kind: NoteKind.text, status: NoteStatus.active,
          rawContent: '下一批', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
      final rejected = expectLater(stale, throwsStateError);
      resume.complete(); await rejected;
      final reopened = SeqDatabase.open(path);
      try {
        final frozen = SyncPublisher(reopened, deviceId: keys.deviceId).freeze();
        expect(frozen.head!.bytes, saved.bytes);
        expect(frozen.operations, isEmpty);
        expect(reopened.raw.select("SELECT 1 FROM sync_operations WHERE object_id='later' AND publication_seq IS NULL"), isNotEmpty);
      } finally { reopened.close(); }
    } finally {
      other.close(); firstDb.close(); root.deleteSync(recursive: true);
    }
  });
}

class DuringEncode implements SegmentCodec {
  DuringEncode(this.inner, this.before);
  final SegmentCodec inner;
  final Future<void> Function() before;
  @override
  Future<Segment> encode(Segment header, List<Operation> ops) async {
    await before();
    return inner.encode(header, ops);
  }
  @override
  Future<List<Operation>> decode(Segment segment) => inner.decode(segment);
}
