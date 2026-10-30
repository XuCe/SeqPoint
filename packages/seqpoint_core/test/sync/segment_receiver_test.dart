import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

Future<VerifiedSegment> frame(List<Operation> ops, {int seq = 1, bool sealed = true,
    int epoch = 1, DateTime? createdAt}) async {
  final segment = await const PlainSegmentCodec().encode(Segment(deviceId: 'peer',
      keyEpoch: epoch, seq: seq, opCount: ops.length, createdAt: createdAt ?? DateTime.utc(2026, 10, 25),
      payload: const [], sealed: sealed), ops);
  return (segment: segment, operations: ops, bytes: segment.encode());
}

void main() {
  late SeqDatabase source, db;
  late SyncSegmentReceiver receiver;
  setUp(() {
    source = SeqDatabase.inMemory()..migrate(); db = SeqDatabase.inMemory()..migrate();
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    NoteRepository(source, clock: FakeClock(DateTime.utc(2026, 10, 25))).insert(Note(
        id: 'n1', kind: NoteKind.text, status: NoteStatus.active, rawContent: '完整便签',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    receiver = SyncSegmentReceiver(db);
  });
  tearDown(() { source.close(); db.close(); });
  test('封口段事实/投影/收据/水位同事务提交，远端操作记所属段', () async {
    final ops = facts(source);
    final result = await receiver.apply(await frame(ops));
    expect(result.addedOperations, ops.length); expect(result.appliedSeq, 1);
    expect(result.pendingObjects, 0);
    expect(NoteRepository(db).byId('n1')!.rawContent, '完整便签');
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
    expect(db.raw.select('SELECT publication_seq FROM sync_operations')
        .every((r) => r['publication_seq'] == 1), isTrue);
  });
  for (final table in ['notes', 'sync_received_segments', 'sync_state']) {
    test('$table拒写时事实/业务/收据/水位/时钟均不半提交', () async {
      final packet = await frame(facts(source));
      db.raw.execute('CREATE TEMP TRIGGER reject_stage BEFORE INSERT ON $table '
          "BEGIN SELECT RAISE(ABORT,'forced'); END");
      await expectLater(receiver.apply(packet), throwsStateError);
      for (final name in ['notes', 'search_index', 'sync_operations', 'sync_received_segments', 'sync_state']) {
        expect(db.raw.select('SELECT * FROM $name'), isEmpty);
      }
      final state = db.raw.select('SELECT * FROM sync_local').single;
      expect(state['hlc_millis'], 0); expect(state['hlc_counter'], 0);
      expect(state['pending_count'], 0);
      db.raw.execute('DROP TRIGGER reject_stage');
      expect((await receiver.apply(packet)).appliedSeq, 1);
    });
  }
  test('事实持久接收仍可待投影，后续段补齐后状态归零', () async {
    final ops = facts(source);
    final first = await receiver.apply(await frame(ops.where((op) => op.field == 'raw_content').toList()));
    expect(first.pendingObjects, 1); expect(first.appliedSeq, 1);
    expect(NoteRepository(db).byId('n1'), isNull);
    final second = await receiver.apply(await frame(
        ops.where((op) => op.field != 'raw_content').toList(), seq: 2));
    expect(second.pendingObjects, 0); expect(second.appliedSeq, 2);
    expect(NoteRepository(db).byId('n1')!.rawContent, '完整便签');
  });
  test('开口段持续重读补tail，只有认证封口才推进水位，同count封口不重写业务', () async {
    final ops = facts(source);
    final first = await receiver.apply(await frame(ops.take(5).toList(), sealed: false));
    expect(first.appliedSeq, 0); expect(first.pendingObjects, 1);
    final grown = await receiver.apply(await frame(ops, sealed: false));
    expect(grown.appliedSeq, 0); expect(grown.addedOperations, ops.length - 5);
    expect(grown.pendingObjects, 0);
    db.raw.execute('CREATE TEMP TRIGGER reject_repeat BEFORE UPDATE ON notes '
        "BEGIN SELECT RAISE(ABORT,'must-not-repeat'); END");
    final sealed = await receiver.apply(await frame(ops));
    expect(sealed.appliedSeq, 1); expect(sealed.addedOperations, 0);
    expect(db.raw.select('SELECT sealed FROM sync_received_segments').single['sealed'], 1);
  });
  test('封口重传幂等不写业务，封口后换字节/复用操作到下一段均拒绝', () async {
    final ops = facts(source); final packet = await frame(ops);
    await receiver.apply(packet);
    db.raw.execute('CREATE TEMP TRIGGER reject_repeat BEFORE UPDATE ON notes '
        "BEGIN SELECT RAISE(ABORT,'must-not-repeat'); END");
    final replay = await receiver.apply(packet);
    expect(replay.duplicate, isTrue); expect(replay.addedOperations, 0);
    await expectLater(receiver.apply(await frame(ops, epoch: 2)), throwsStateError);
    await expectLater(receiver.apply(await frame(ops, seq: 2)), throwsStateError);
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
  });
  test('开口段缩短/重排/改旧值/改变固定header均拒绝，保留已提交前缀', () async {
    final ops = facts(source), prefix = facts(source).take(5).toList();
    await receiver.apply(await frame(prefix, sealed: false));
    final changed = ops.toList();
    final index = changed.indexWhere((op) => op.field == 'raw_content');
    changed[index] = Operation.fromJson({...changed[index].toJson(), 'value': '改写旧值'});
    for (final packet in [await frame(prefix.take(4).toList(), sealed: false),
      await frame(ops.reversed.toList(), sealed: false), await frame(changed, sealed: false),
      await frame(ops, sealed: false, epoch: 2),
      await frame(ops, sealed: false, createdAt: DateTime.utc(2026, 10, 26))]) {
      await expectLater(receiver.apply(packet), throwsStateError);
    }
    expect(db.raw.select('SELECT op_count FROM sync_received_segments').single['op_count'], 5);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(5));
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 0);
    expect((await receiver.apply(await frame(ops))).appliedSeq, 1);
  });
  test('缺段反序先等待，补前段后可前进，重传旧段返回最高水位', () async {
    final ops = facts(source), packet = await frame(ops);
    final nextOp = Operation.fromJson({...ops.last.toJson(), 'op_id': 'tail',
      'hlc': Hlc(millis: ops.last.hlc.millis, counter: 100, deviceId: 'peer').toString(),
      'field': 'raw_content', 'value': '后段'});
    final next = await frame([nextOp], seq: 2);
    await expectLater(receiver.apply(next), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
    await receiver.apply(packet); expect((await receiver.apply(next)).appliedSeq, 2);
    expect(NoteRepository(db).byId('n1')!.rawContent, '后段');
    expect((await receiver.apply(packet)).appliedSeq, 2);
  });
  test('拒绝嵌套在调用方未提交事务内接收', () async {
    final packet = await frame(facts(source));
    await expectLater(db.transaction(() => receiver.apply(packet)), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
  });
  test('关闭重开承接开口前缀补tail，再重开验证封口重传', () async {
    final ops = facts(source), sealed = await frame(facts(source));
    await receiver.apply(await frame(ops.take(5).toList(), sealed: false));
    final directory = Directory.systemTemp.createTempSync('seqpoint_receipts_');
    final path = '${directory.path}/received.db'; db.raw.execute('VACUUM INTO ?', [path]);
    var reopened = SeqDatabase.open(path)..migrate();
    try {
      final other = SyncSegmentReceiver(reopened);
      final grown = await other.apply(await frame(ops, sealed: false));
      expect(grown.addedOperations, ops.length - 5); expect(grown.appliedSeq, 0);
      expect((await other.apply(sealed)).appliedSeq, 1);
      reopened.close(); reopened = SeqDatabase.open(path)..migrate();
      final replay = await SyncSegmentReceiver(reopened).apply(sealed);
      expect(replay.duplicate, isTrue); expect(replay.addedOperations, 0);
      expect(NoteRepository(reopened).byId('n1')!.rawContent, '完整便签');
    } finally { reopened.close(); directory.deleteSync(recursive: true); }
  });
  test('并发相同段只提交一次，另一请求用同一持久收据返回', () async {
    final packet = await frame(facts(source));
    final results = await Future.wait([receiver.apply(packet), receiver.apply(packet)]);
    expect(results.map((r) => r.addedOperations), unorderedEquals([0, packet.operations.length]));
    expect(results.where((r) => r.duplicate), hasLength(1));
    expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
    expect(db.raw.select('SELECT * FROM notes'), hasLength(1));
  });
}
