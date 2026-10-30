import 'dart:async';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;
import 'segment_receiver_test.dart' show frame;

void main() {
  late SeqDatabase source, db;
  late SyncSegmentReceiver receiver;
  setUp(() {
    source = SeqDatabase.inMemory()..migrate(); db = SeqDatabase.inMemory()..migrate();
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='receiver'");
    NoteRepository(source, clock: FakeClock(DateTime.utc(2026, 10, 25))).insert(Note(
        id: 'n1', kind: NoteKind.text, status: NoteStatus.active, rawContent: '已提交便签',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    receiver = SyncSegmentReceiver(db);
  });
  tearDown(() { source.close(); db.close(); });
  test('ACK回调只能看到已独立提交的业务/收据/水位，向量来自DB', () async {
    final vectors = <Map<String, int>>[];
    final result = await receiver.receive(await frame(facts(source)), writeAck: (vector) async {
      expect(db.raw.autocommit, isTrue);
      expect(NoteRepository(db).byId('n1')!.rawContent, '已提交便签');
      expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
      expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
      vectors.add(vector);
    });
    expect(result.appliedSeq, 1); expect(vectors, [{'peer': 1}]);
  });
  for (final table in ['notes', 'sync_state']) {
    test('$table拒写时不调用ACK回调', () async {
      var called = 0;
      db.raw.execute('CREATE TEMP TRIGGER reject_commit BEFORE INSERT ON $table '
          "BEGIN SELECT RAISE(ABORT,'forced'); END");
      await expectLater(receiver.receive(await frame(facts(source)),
          writeAck: (_) async { called++; }), throwsStateError);
      expect(called, 0); expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    });
  }
  test('ACK失败保留已提交数据，重试同段不重复业务写且队列不被失败阻塞', () async {
    final packet = await frame(facts(source)); var called = 0;
    Future<void> write(Map<String, int> vector) async {
      called++; expect(db.raw.autocommit, isTrue); expect(vector, {'peer': 1});
      if (called == 1) throw StateError('simulated IO failure');
    }
    await expectLater(receiver.receive(packet, writeAck: write), throwsStateError);
    expect(NoteRepository(db).byId('n1')!.rawContent, '已提交便签');
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
    db.raw.execute('CREATE TEMP TRIGGER reject_repeat BEFORE UPDATE ON notes '
        "BEGIN SELECT RAISE(ABORT,'must-not-repeat'); END");
    final replay = await receiver.receive(packet, writeAck: write);
    expect(replay.duplicate, isTrue); expect(replay.addedOperations, 0); expect(called, 2);
  });
  test('开口段可入库但ACK不推进，认证封口后才确认该序号', () async {
    final vectors = <Map<String, int>>[], ops = facts(source);
    Future<void> write(Map<String, int> vector) async { vectors.add(vector); }
    await receiver.receive(await frame(ops, sealed: false), writeAck: write);
    expect(vectors, [<String, int>{}]);
    await receiver.receive(await frame(ops), writeAck: write);
    expect(vectors.last, {'peer': 1});
  });
  test('ACK排队读取执行时的新鲜DB水位，慢旧写入不会覆盖较新确认', () async {
    final started = Completer<void>(), release = Completer<void>();
    final vectors = <Map<String, int>>[];
    Future<void> write(Map<String, int> vector) async {
      vectors.add(vector);
      if (vectors.length == 1) { started.complete(); await release.future; }
    }
    final ops = facts(source);
    final first = receiver.receive(await frame(ops), writeAck: write);
    await started.future;
    final tail = Operation.fromJson({...ops.last.toJson(), 'op_id': 'tail',
      'hlc': Hlc(millis: ops.last.hlc.millis, counter: 100, deviceId: 'peer').toString(),
      'field': 'raw_content', 'value': '后段'});
    await receiver.apply(await frame([tail], seq: 2));
    final second = receiver.retryAck(write);
    release.complete(); await first; await second;
    expect(vectors, [{'peer': 1}, {'peer': 2}]);
  });
  test('队列等待期间身份改变，旧接收器不再写新的ACK', () async {
    final started = Completer<void>(), release = Completer<void>(); var called = 0;
    Future<void> write(Map<String, int> _) async {
      called++; if (called == 1) { started.complete(); await release.future; }
    }
    final first = receiver.receive(await frame(facts(source)), writeAck: write);
    await started.future;
    final second = receiver.retryAck(write);
    final rejected = expectLater(second, throwsStateError);
    db.raw.execute("UPDATE sync_local SET device_id='new-receiver'");
    release.complete(); await first; await rejected;
    expect(called, 1);
  });
  test('ACK文件失败后重开DB可补确认，纠正文件伪水位且不重复业务写', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_ack_reopen_');
    final normal = VaultStore(root: root, deviceId: 'receiver', codec: const PlainSegmentCodec());
    await normal.writeSelfAck({'peer': 999}); // 文件不是生产水位来源。
    final oldBytes = await File('${root.path}/acks/receiver.json').readAsBytes();
    final failing = VaultStore(root: root, deviceId: 'receiver', codec: const PlainSegmentCodec(),
        writeAckBytes: (temp, bytes) async {
      await temp.writeAsBytes(bytes.take(2).toList(), flush: true);
      throw const FileSystemException('forced ACK failure');
    });
    try {
      await expectLater(receiver.receive(await frame(facts(source)),
          writeAck: failing.writeSelfAck), throwsStateError);
      expect(await File('${root.path}/acks/receiver.json').readAsBytes(), oldBytes);
      final path = '${root.path}/received.db'; db.raw.execute('VACUUM INTO ?', [path]);
      final reopened = SeqDatabase.open(path)..migrate();
      try {
        reopened.raw.execute('CREATE TEMP TRIGGER reject_repeat BEFORE UPDATE ON notes '
            "BEGIN SELECT RAISE(ABORT,'must-not-repeat'); END");
        final other = SyncSegmentReceiver(reopened);
        await other.retryAck(normal.writeSelfAck); await other.retryAck(normal.writeSelfAck);
        expect(await normal.readAck('receiver'), {'peer': 1});
        expect(NoteRepository(reopened).byId('n1')!.rawContent, '已提交便签');
        expect(Directory('${root.path}/acks').listSync(), hasLength(1));
      } finally { reopened.close(); }
    } finally { root.deleteSync(recursive: true); }
  });
  test('孤立旧DB水位没有封口收据和操作证明时也不能发布ACK', () async {
    db.raw.execute("INSERT INTO sync_state(device_id,applied_seq) VALUES ('peer',1)");
    var called = 0;
    await expectLater(receiver.retryAck((_) async { called++; }), throwsStateError);
    expect(called, 0);
    db.raw.execute('INSERT INTO sync_received_segments '
        '(device_id,seq,key_epoch,created_at,op_count,sealed,segment_hash) '
        "VALUES ('peer',1,1,?,1,1,?)", [encodeTime(DateTime.utc(2026)), '0' * 64]);
    await expectLater(receiver.retryAck((_) async { called++; }), throwsStateError);
    expect(called, 0);
  });
}
