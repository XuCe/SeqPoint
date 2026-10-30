import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late SyncPublisher publisher;
  late FakeClock clock;
  var counter = 0;
  const codec = PlainSegmentCodec(); // 只测试发布编排；真实加密见publisher_prepare_test。
  void add([String value = 'x']) {
    final id = counter++;
    db.raw.execute('INSERT INTO sync_operations '
        '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
        "VALUES (?,'writer',1,?,'note','n1','raw_content',?,'local')",
        ['writer:$id', id, jsonEncode(value)]);
  }
  Future<PublicationSnapshot?> prepare([int epoch = 1]) => publisher.prepare(codec: codec, keyEpoch: epoch);
  void published() => db.raw.execute('UPDATE sync_publications SET published=1');
  setUp(() {
    counter = 0; db = SeqDatabase.inMemory()..migrate();
    SyncBaseline(db).initialize('writer');
    clock = FakeClock(DateTime.utc(2026, 10, 31, 23, 59));
    publisher = SyncPublisher(db, deviceId: 'writer', clock: clock);
  });
  tearDown(() => db.close());
  test('精确8MiB明文立即封口，多1字节则保留待发且不产生publication', () async {
    for (final extra in [0, 1]) {
      db.raw.execute('DELETE FROM sync_operations');
      db.raw.execute('DELETE FROM sync_publications');
      counter = 0; add('');
      final overhead = utf8.encode(jsonEncode(
          publisher.freeze().operations.map((op) => op.toJson()).toList())).length;
      db.raw.execute('UPDATE sync_operations SET value_json=?',
          [jsonEncode('x' * (EncryptedSegmentCodec.maxPlaintextBytes - overhead + extra))]);
      if (extra == 0) {
        final full = (await prepare())!;
        expect(full.header.opCount, 1); expect(full.sealed, isTrue);
        expect(Segment.decode(full.bytes).payload.length, EncryptedSegmentCodec.maxPlaintextBytes);
      } else {
        await expectLater(prepare(), throwsStateError);
        expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
        expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
      }
    }
  });
  test('同月同epoch且无新操作返回空，不重编码或改发布状态', () async {
    expect(await prepare(), isNull);
    add(); final first = (await prepare())!; published();
    expect(await publisher.prepare(codec: NoEncodeCodec(), keyEpoch: 1), isNull);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], first.bytes);
    expect(db.raw.select('SELECT published FROM sync_publications').single['published'], 1);
  });
  test('prepared优先复用原bytes，即使新增操作也不重编码', () async {
    add(); final first = (await prepare())!; add();
    final retry = (await publisher.prepare(codec: NoEncodeCodec(), keyEpoch: 2))!;
    expect(retry.bytes, first.bytes); expect(retry.fileName, first.fileName);
    expect(retry.keyEpoch, 1); expect(retry.published, isFalse);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
  });
  test('开放tail仅追加冻结前缀并保留原月份/时间/序号', () async {
    add(); final first = (await prepare())!; published(); add();
    final tail = (await prepare())!;
    expect(tail.seq, first.seq); expect(tail.header.createdAt, first.header.createdAt);
    expect((await codec.decode(Segment.decode(tail.bytes))).map((op) => op.opId), ['writer:0', 'writer:1']);
    expect(tail.sealed, isFalse); expect(tail.published, isFalse);
  });
  test('跨月与epoch变化先原位置封口，再使用全局下一seq', () async {
    add(); final october = (await prepare())!; published(); add();
    clock.advance(const Duration(minutes: 2));
    final sealed = (await prepare())!;
    expect(sealed.seq, 1); expect(sealed.sealed, isTrue);
    expect(sealed.fileName, october.fileName); expect(sealed.header.createdAt, october.header.createdAt);
    expect(sealed.header.opCount, 1); published();
    final november = (await prepare())!;
    expect(november.seq, 2); expect(november.fileName, contains('202611-'));
    published(); add();
    final oldEpoch = (await prepare(2))!;
    expect(oldEpoch.seq, 2); expect(oldEpoch.keyEpoch, 1); expect(oldEpoch.sealed, isTrue);
    published();
    final newEpoch = (await prepare(2))!;
    expect(newEpoch.seq, 3); expect(newEpoch.keyEpoch, 2);
  });
  test('满500条显式封口且第501条留待下一全局序号', () async {
    for (var i = 0; i < 501; i++) { add(); }
    final full = (await prepare())!;
    expect(full.header.opCount, 500); expect(full.sealed, isTrue); published();
    final next = (await prepare())!;
    expect(next.seq, 2); expect(next.header.opCount, 1);
  });
  test('按UTF8 JSON实际字节装箱，未满500也封口，单操作超限不丢弃', () async {
    final large = '你' * (1400 * 1024);
    add(large); add(large);
    final first = (await prepare())!;
    expect(first.header.opCount, 1); expect(first.sealed, isTrue);
    expect(first.bytes.length, lessThanOrEqualTo(VaultStore.maxSegmentFileBytes));
    published(); final next = (await prepare())!; expect(next.seq, 2); published();
    add('x' * EncryptedSegmentCodec.maxPlaintextBytes);
    final closed = (await prepare())!; expect(closed.seq, 2); expect(closed.sealed, isTrue); published();
    await expectLater(prepare(), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), hasLength(2));
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
  });
}
class NoEncodeCodec extends PlainSegmentCodec {
  @override
  Future<Segment> encode(Segment header, List<Operation> ops) => throw StateError('禁止重新编码prepared');
}
