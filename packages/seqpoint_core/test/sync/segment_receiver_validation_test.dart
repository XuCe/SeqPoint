import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'segment_receiver_test.dart' show frame;

void main() {
  late SeqDatabase db;
  const op = Operation(opId: 'op', deviceId: 'peer',
      hlc: Hlc(millis: 1, counter: 0, deviceId: 'peer'),
      objectType: 'note', objectId: 'n1', field: 'raw_content', value: '局部');
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
  });
  tearDown(() => db.close());
  test('身份/条数/时间/序号极值边界拒绝且无事实或水位', () async {
    final valid = await frame([op]);
    for (final invalid in [
      (device: 'receiver', seq: 1, epoch: 1, count: 1, utc: true),
      (device: 'peer', seq: 0, epoch: 1, count: 1, utc: true),
      (device: 'peer', seq: 0x7fffffffffffffff, epoch: 1, count: 1, utc: true),
      (device: 'peer', seq: 1, epoch: 0, count: 1, utc: true),
      (device: 'peer', seq: 1, epoch: 1, count: 0, utc: true),
      (device: 'peer', seq: 1, epoch: 1, count: 501, utc: true),
      (device: 'peer', seq: 1, epoch: 1, count: 1, utc: false),
    ]) {
      final s = Segment(deviceId: invalid.device, seq: invalid.seq, keyEpoch: invalid.epoch,
          opCount: invalid.count, sealed: true, payload: valid.segment.payload,
          createdAt: invalid.utc ? DateTime.utc(2026) : DateTime(2026));
      await expectLater(SyncSegmentReceiver(db).apply(
          (segment: s, operations: [op], bytes: s.encode())), throwsStateError);
    }
    await expectLater(SyncSegmentReceiver(db).apply(await frame([op, op])), throwsStateError);
    await expectLater(SyncSegmentReceiver(db).apply(await frame([])), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
  });
  test('计算摘要期间关闭/要求新身份，提交前重新检查状态', () async {
    final packet = await frame([op]);
    final receiving = SyncSegmentReceiver(db).apply(packet);
    db.raw.execute('UPDATE sync_local SET enabled=0,requires_new_identity=1');
    await expectLater(receiving, throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
  });
  test('旧水位缺段收据时拒绝假重传，不信文件或猜已持久应用', () async {
    db.raw.execute("INSERT INTO sync_state(device_id,applied_seq) VALUES ('peer',1)");
    await expectLater(SyncSegmentReceiver(db).apply(await frame([op])), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
  });
  test('极端远端时钟拒绝且不产生收据或前缀归属', () async {
    final future = Operation.fromJson({...op.toJson(),
      'hlc': '${Hlc.maxMillis}:0:peer'});
    await expectLater(SyncSegmentReceiver(db).apply(await frame([future])), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
  });
  test('摘要异步间隙调用方开启事务，也不能误当成已独立提交', () async {
    final packet = await frame([op]);
    final receiving = SyncSegmentReceiver(db).apply(packet);
    db.raw.execute('BEGIN');
    try {
      await expectLater(receiving, throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    } finally { db.raw.execute('ROLLBACK'); }
  });
}
