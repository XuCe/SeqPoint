import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'publisher_prepare_test.dart' show DuringEncode;
import 'sync_publisher_test.dart' show addOperation;

void main() {
  late SeqDatabase db;
  late SyncPublisher publisher;
  late FakeClock clock;
  const codec = PlainSegmentCodec();
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    SyncBaseline(db).initialize('writer');
    clock = FakeClock(DateTime.utc(2026, 10, 31, 23, 59));
    publisher = SyncPublisher(db, deviceId: 'writer', clock: clock);
    addOperation(db, 0);
  });
  tearDown(() => db.close());

  test('头字段不变但原bytes改变也必须使CAS失败', () async {
    final first = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
    db.raw.execute('UPDATE sync_publications SET published=1');
    addOperation(db, 1);
    final segment = Segment.decode(first.bytes);
    final changed = segment.withPayload([...segment.payload, 32]).encode();
    await expectLater(publisher.prepare(keyEpoch: 1,
        codec: DuringEncode(codec, () async {
          db.raw.execute('UPDATE sync_publications SET segment_bytes=?', [changed]);
        })).then<void>((_) {}), throwsStateError);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], changed);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
  });

  test('最终文件超过12MiB时在事务外拒绝且不绑定操作', () async {
    await expectLater(publisher.prepare(codec: OversizedCodec(), keyEpoch: 1), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(1));
    expect(db.raw.autocommit, isTrue);
  });

  test('封口编码期间先提交版本获胜，陈旧封口不能覆盖原prepared', () async {
    await publisher.prepare(codec: codec, keyEpoch: 1);
    db.raw.execute('UPDATE sync_publications SET published=1');
    clock.advance(const Duration(minutes: 2));
    PublicationSnapshot? winner;
    await expectLater(publisher.prepare(keyEpoch: 1,
        codec: DuringEncode(codec, () async {
          expect(db.raw.autocommit, isTrue);
          winner = await SyncPublisher(db, deviceId: 'writer', clock: clock)
              .prepare(codec: codec, keyEpoch: 1);
        })).then<void>((_) {}), throwsStateError);
    expect(winner!.sealed, isTrue);
    expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], winner!.bytes);
    expect(db.raw.select('SELECT published FROM sync_publications').single['published'], 0);
    expect(db.raw.autocommit, isTrue);
  });
}

class OversizedCodec extends PlainSegmentCodec {
  @override
  Future<Segment> encode(Segment header, List<Operation> ops) async =>
      header.withPayload(List.filled(VaultStore.maxSegmentFileBytes, 0));
}
