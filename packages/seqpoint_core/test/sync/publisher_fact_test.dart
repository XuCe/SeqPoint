import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'publisher_prepare_test.dart' show DuringEncode;
import 'sync_publisher_test.dart' show addOperation;

void main() {
  late SeqDatabase db;
  late SyncPublisher publisher;
  const codec = PlainSegmentCodec();
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    SyncBaseline(db).initialize('writer');
    publisher = SyncPublisher(db, deviceId: 'writer');
  });
  tearDown(() => db.close());

  test('解码期间关闭/换身份/丢ready/开启外层事务均拒绝原prepared', () async {
    addOperation(db, 0);
    final saved = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
    for (final sql in [
      'UPDATE sync_local SET enabled=0', "UPDATE sync_local SET device_id='other'",
      'UPDATE sync_local SET baseline_ready=0', 'BEGIN',
    ]) {
      db.raw.execute("UPDATE sync_local SET enabled=1,device_id='writer',baseline_ready=1");
      await expectLater(publisher.prepare(keyEpoch: 1,
          codec: DuringDecode(() => db.raw.execute(sql))).then<void>((_) {}), throwsStateError);
      if (!db.raw.autocommit) db.raw.execute('ROLLBACK');
      expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], saved.bytes);
    }
  });

  test('绑定触发器中途变值时撤销publication/绑定和事实修改', () async {
    addOperation(db, 0);
    db.raw.execute('CREATE TEMP TRIGGER mutate_fact AFTER UPDATE OF publication_seq ON sync_operations '
        'BEGIN UPDATE sync_operations SET value_json=\'"changed"\' WHERE op_id=NEW.op_id; END');
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 1), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    final row = db.raw.select('SELECT * FROM sync_operations').single;
    expect(row['value_json'], '"value:0"'); expect(row['publication_seq'], isNull);
    expect(db.raw.autocommit, isTrue);
  });

  test('认证prefix必须与已绑定事实逐项相同，prepared重试也不能绕过', () async {
    for (final published in [0, 1]) {
      for (final change in [
        'UPDATE sync_operations SET value_json=\'"changed"\'',
        "UPDATE sync_operations SET op_id='other'",
      ]) {
        db.raw.execute('DELETE FROM sync_operations');
        db.raw.execute('DELETE FROM sync_publications');
        addOperation(db, 0);
        final saved = (await publisher.prepare(codec: codec, keyEpoch: 1))!;
        db.raw.execute('UPDATE sync_publications SET published=?', [published]);
        db.raw.execute(change);
        await expectLater(publisher.prepare(codec: codec, keyEpoch: 1).then<void>((_) {}),
            throwsStateError, reason: '$published: $change');
        expect(db.raw.select('SELECT segment_bytes FROM sync_publications').single['segment_bytes'], saved.bytes);
        expect(db.raw.select('SELECT published FROM sync_publications').single['published'], published);
        expect(db.raw.autocommit, isTrue);
      }
    }
  });

  test('编码期间冻结事实值/字段/对象/HLC改变或删除时原子拒绝', () async {
    for (final change in [
      'UPDATE sync_operations SET value_json=\'"changed"\'',
      "UPDATE sync_operations SET field='title'",
      "UPDATE sync_operations SET object_id='other'",
      'UPDATE sync_operations SET hlc_millis=2',
      'DELETE FROM sync_operations',
    ]) {
      db.raw.execute('DELETE FROM sync_operations');
      addOperation(db, 0);
      await expectLater(publisher.prepare(keyEpoch: 1,
          codec: DuringEncode(codec, () async { db.raw.execute(change); })),
          throwsStateError, reason: change);
      expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
      expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
      expect(db.raw.autocommit, isTrue);
    }
  });
}

class DuringDecode extends PlainSegmentCodec {
  DuringDecode(this.after);
  final void Function() after;
  @override
  Future<List<Operation>> decode(Segment segment) async {
    final ops = await super.decode(segment); after(); return ops;
  }
}
