import 'dart:convert';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Operation op(String id, int millis, int counter, String value,
    {String device = 'peer'}) => Operation(opId: id, deviceId: device,
      hlc: Hlc(millis: millis, counter: counter, deviceId: device),
      objectType: 'note', objectId: 'n1', field: 'raw_content', value: value);

void main() {
  late SeqDatabase db;
  late SyncInbox inbox;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'local'");
    inbox = SyncInbox(db);
  });
  tearDown(() => db.close());
  test('持久保存远端事实，精确重传幂等，不提前投影/写水位ACK', () {
    final operations = [op('op1', 100, 2, '正文')];
    expect(inbox.storeVerifiedBatch(peerId: 'peer', operations: operations), 1);
    expect(inbox.storeVerifiedBatch(peerId: 'peer', operations: operations), 0);
    final row = db.raw.select('SELECT * FROM sync_operations').single;
    expect(row['source'], 'remote');
    expect(jsonDecode(row['value_json'] as String), '正文');
    expect(db.raw.select('SELECT * FROM notes'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['hlc_millis'], 100); expect(state['hlc_counter'], 2);
  });
  test('opId伪重复整批拒绝，新插入部分和观察时钟一起回滚', () {
    inbox.storeVerifiedBatch(peerId: 'peer', operations: [op('op1', 100, 2, '原文')]);
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: [
      op('op2', 200, 0, '先插入'), op('op1', 100, 2, '伪造重传')]), throwsStateError);
    final row = db.raw.select('SELECT * FROM sync_operations').single;
    expect(row['op_id'], 'op1'); expect(jsonDecode(row['value_json'] as String), '原文');
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 100);
  });
  test('同writer同HLC不同操作拒绝，其他设备相同时钟可独立保存', () {
    inbox.storeVerifiedBatch(peerId: 'peer', operations: [op('op1', 100, 2, '第一条')]);
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: [op('op2', 100, 2, '冲突')]),
        throwsStateError);
    expect(inbox.storeVerifiedBatch(peerId: 'other', operations: [
      op('op3', 100, 2, '另一设备', device: 'other')]), 1);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(2));
  });
  test('未知作者/非法批次前置拒绝，不能留前半条事实', () {
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: [
      op('op1', 100, 2, '正常'), op('op2', -1, 0, '非法')]), throwsFormatException);
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: [
      op('op3', 1, 0, '作者不符', device: 'other')]), throwsFormatException);
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer',
        operations: List.filled(501, op('op4', 1, 0, '超限'))), throwsFormatException);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
  test('本机writer/关闭或要求新身份时不接收；空批次无副作用', () {
    expect(() => inbox.storeVerifiedBatch(peerId: 'local', operations: [
      op('op1', 100, 2, '伪装本机', device: 'local')]), throwsStateError);
    db.raw.execute('UPDATE sync_local SET enabled = 0, requires_new_identity = 1');
    expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: [op('op2', 1, 0, '未启用')]),
        throwsStateError);
    expect(inbox.storeVerifiedBatch(peerId: 'peer', operations: []), 0);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  test('调用方事务失败也撤销已保存事实和观察HLC', () {
    expect(() => db.transaction(() {
      inbox.storeVerifiedBatch(peerId: 'peer', operations: [op('op1', 100, 2, '正文')]);
      throw StateError('projection failed');
    }), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
  for (final failure in ['operation', 'clock']) {
    test('$failure持久写失败整批回滚且错误不泄露正文，修复可重试', () {
      final sql = failure == 'operation'
          ? "CREATE TEMP TRIGGER reject_inbox BEFORE INSERT ON sync_operations WHEN NEW.op_id = 'op2' "
          : 'CREATE TEMP TRIGGER reject_inbox BEFORE UPDATE ON sync_local ';
      db.raw.execute("${sql}BEGIN SELECT RAISE(ABORT,'fake-private-body'); END");
      final operations = [op('op1', 100, 0, 'fake-private-body'), op('op2', 101, 0, '正文')];
      expect(() => inbox.storeVerifiedBatch(peerId: 'peer', operations: operations),
          throwsA(predicate((error) => error is StateError &&
              !error.toString().contains('fake-private-body'))));
      expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
      expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
      db.raw.execute('DROP TRIGGER reject_inbox');
      expect(inbox.storeVerifiedBatch(peerId: 'peer', operations: operations), 2);
      expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 101);
    });
  }
  test('完全重开后重传幂等，下一本地时钟严格晚于远端且旧批不回拨', () {
    final dir = Directory.systemTemp.createTempSync('seqpoint_inbox_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/state.db';
    final first = SeqDatabase.open(path)..migrate();
    final remote = op('op1', 200, 7, '远端事实');
    try {
      first.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'local'");
      expect(SyncInbox(first).storeVerifiedBatch(peerId: 'peer', operations: [remote]), 1);
    } finally { first.close(); }
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      final receiver = SyncInbox(reopened);
      expect(receiver.storeVerifiedBatch(peerId: 'peer', operations: [remote]), 0);
      reopened.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('t1','old','project')");
      SyncOutbox(reopened, clock: FakeClock(DateTime.fromMillisecondsSinceEpoch(10)))
          .capture('tag', 't1',
            read: () => reopened.raw.select("SELECT * FROM tags WHERE id = 't1'").single,
            write: () => reopened.raw.execute('UPDATE tags SET name = ? WHERE id = ?', ['new', 't1']));
      final local = reopened.raw.select("SELECT * FROM sync_operations WHERE source = 'local'").single;
      expect(local['device_id'], 'local');
      expect(local['hlc_millis'], 200); expect(local['hlc_counter'], 8);
      receiver.storeVerifiedBatch(peerId: 'other', operations: [op('op2', 100, 1, '旧批次', device: 'other')]);
      final state = reopened.raw.select('SELECT * FROM sync_local').single;
      expect(state['hlc_millis'], 200); expect(state['hlc_counter'], 8);
      expect(reopened.raw.select('SELECT * FROM sync_state'), isEmpty);
    } finally { reopened.close(); }
  });
  test('远端计数器达到SQLite上限后，本地tick进位且仍可发送', () {
    inbox.storeVerifiedBatch(peerId: 'peer', operations: [
      op('remote-max', 200, 0x7fffffffffffffff, '远端')]);
    db.raw.execute("INSERT INTO tags(id,name,kind) VALUES ('t1','old','project')");
    SyncOutbox(db, clock: FakeClock(DateTime.fromMillisecondsSinceEpoch(100)))
        .capture('tag', 't1',
          read: () => db.raw.select("SELECT * FROM tags WHERE id = 't1'").single,
          write: () => db.raw.execute("UPDATE tags SET name = 'new' WHERE id = 't1'"));
    final row = db.raw.select("SELECT * FROM sync_operations WHERE source = 'local'").single;
    expect(row['hlc_millis'], 201); expect(row['hlc_counter'], 0);
    final local = Operation(opId: row['op_id'] as String, deviceId: 'local',
        hlc: Hlc(millis: row['hlc_millis'] as int, counter: row['hlc_counter'] as int, deviceId: 'local'),
        objectType: 'tag', objectId: 't1', field: 'name', value: 'new');
    expect(() => validateIncomingOperation(local, expectedDeviceId: 'local'), returnsNormally);
  });
  test('远端最多允许超前五分钟，越界整批拒绝且不推进时钟', () {
    final receiver = SyncInbox(db, clock: FakeClock(DateTime.fromMillisecondsSinceEpoch(1000)));
    expect(receiver.storeVerifiedBatch(peerId: 'peer', operations: [
      op('boundary', 301000, 0, '边界')]), 1);
    expect(() => receiver.storeVerifiedBatch(peerId: 'peer', operations: [
      op('future', 301001, 0, '超前')]), throwsFormatException);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(1));
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 301000);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
  });
  test('绝对时钟极值不能从远端灌入，历史离线操作仍可保存', () {
    final receiver = SyncInbox(db, clock: FakeClock(DateTime.fromMillisecondsSinceEpoch(1000)));
    expect(() => receiver.storeVerifiedBatch(peerId: 'peer', operations: [
      op('poison', Hlc.maxMillis, Hlc.maxCounter, '极值')]), throwsFormatException);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(receiver.storeVerifiedBatch(peerId: 'peer', operations: [op('old', 1, 0, '历史')]), 1);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 1);
  });
}
