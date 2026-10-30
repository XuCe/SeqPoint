import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void addOperation(SeqDatabase db, int counter, {
  String device = 'writer', String source = 'local',
}) {
  db.raw.execute('INSERT INTO sync_operations '
      '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
      'VALUES (?,?,1,?,?,?,?,?,?)', [
    '$device:$counter', device, counter, 'note', 'n1', 'raw_content',
    '"value:$counter"', source,
  ]);
}

void main() {
  late SeqDatabase db;
  late SyncPublisher publisher;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    SyncBaseline(db).initialize('writer');
    publisher = SyncPublisher(db, deviceId: 'writer');
  });
  tearDown(() => db.close());

  test('按HLC冻结最多500条本机操作，排除远端且列表不可变', () {
    for (var i = 500; i >= 0; i--) { addOperation(db, i); }
    addOperation(db, 0, device: 'remote', source: 'remote');
    final batch = publisher.freeze();
    expect(batch.operations, hasLength(500));
    expect(batch.operations.first.opId, 'writer:0');
    expect(batch.operations.last.opId, 'writer:499');
    expect(batch.operations.every((op) => op.deviceId == 'writer'), isTrue);
    expect(() => batch.operations.clear(), throwsUnsupportedError);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NULL'), hasLength(502));
  });

  test('冻结后值和opId稳定，后续新增不混入当前批次且不标记已发', () {
    addOperation(db, 0);
    final batch = publisher.freeze();
    db.raw.execute('UPDATE sync_operations SET value_json=? WHERE op_id=?',
        ['"changed"', 'writer:0']);
    addOperation(db, 1);
    expect(batch.operations.single.opId, 'writer:0');
    expect(batch.operations.single.value, 'value:0');
    expect(publisher.freeze().operations, hasLength(2));
    expect(db.raw.autocommit, isTrue);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
  });

  test('超过首批的异身份本机历史也拒绝，不静默跳过', () {
    for (var i = 0; i < 500; i++) { addOperation(db, i); }
    addOperation(db, 500, device: 'other');
    expect(() => publisher.freeze(), throwsStateError);
    expect(db.raw.autocommit, isTrue);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(501));
  });

  test('空基线可冻结且不占用调用方事务', () {
    final batch = publisher.freeze();
    expect(batch.deviceId, 'writer');
    expect(batch.head, isNull);
    expect(batch.operations, isEmpty);
    expect(db.raw.autocommit, isTrue);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
  });

  test('身份变化/关闭/未ready/恢复屏障均拒绝且不改状态', () {
    for (final values in [
      ['other', 1, 1, 0], ['writer', 0, 1, 0],
      ['writer', 1, 0, 0], ['writer', 0, 0, 1],
    ]) {
      db.raw.execute('UPDATE sync_local SET device_id=?,enabled=?,baseline_ready=?,'
          'requires_new_identity=? WHERE id=1', values);
      final before = db.raw.select('SELECT * FROM sync_local').single;
      expect(() => publisher.freeze(), throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_local').single, before);
      expect(db.raw.autocommit, isTrue);
    }
  });

  test('坏身份/缺基线/真实恢复断开均不能冻结', () {
    for (final id in ['', 'bad/id', 'writer\n', 'a' * 129]) {
      expect(() => SyncPublisher(db, deviceId: id).freeze(), throwsStateError);
    }
    final empty = SeqDatabase.inMemory()..migrate();
    try {
      expect(() => SyncPublisher(empty, deviceId: 'writer').freeze(), throwsStateError);
    } finally { empty.close(); }
    db.disconnectSyncForRestore();
    expect(() => publisher.freeze(), throwsStateError);
    expect(db.raw.select('SELECT requires_new_identity FROM sync_local').single.values, [1]);
  });

  test('非法值拒绝且错误不泄漏原文，修复后可重试', () {
    addOperation(db, 0);
    db.raw.execute('UPDATE sync_operations SET value_json=?', ['{"private":"secret"}']);
    expect(() => publisher.freeze(), throwsA(isA<StateError>().having(
        (e) => e.message, 'message', isNot(contains('secret')))));
    expect(db.raw.autocommit, isTrue);
    db.raw.execute('UPDATE sync_operations SET value_json=?', ['"repaired"']);
    expect(publisher.freeze().operations.single.value, 'repaired');
  });

  test('拒绝调用方外层事务并保留现场', () {
    db.transaction(() {
      expect(() => publisher.freeze(), throwsStateError);
      expect(db.raw.autocommit, isFalse);
    });
    expect(db.raw.autocommit, isTrue);
  });
}
