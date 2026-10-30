import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  late SeqDatabase db;
  late FakeClock clock;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.utc(2026, 10, 26));
    NoteRepository(db).insert(Note(id: 'restored', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '保留恢复原文',
        createdAt: clock.now(), updatedAt: clock.now()));
    db.disconnectSyncForRestore();
  });
  tearDown(() => db.close());

  test('新安全身份显式提交恢复基线，普通入口仍拒绝且旧writer不复用', () {
    expect(() => SyncBaseline(db).initialize('new-writer'), throwsStateError);
    final baseline = SyncBaseline(db, clock: clock);
    expect(() => baseline.initializeRestored('new-writer',
        previousDeviceId: 'retired-writer'), returnsNormally);
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['requires_new_identity'], 0);
    expect(state['device_id'], 'new-writer');
    expect(state['enabled'], 1);
    expect(state['baseline_ready'], 1);
    expect(facts(db), isNotEmpty);
    expect(facts(db).every((op) => op.deviceId == 'new-writer'), isTrue);
    expect(NoteRepository(db).byId('restored')!.rawContent, '保留恢复原文');
  });

  test('重复或非法身份及调用方事务均不能清恢复标志', () {
    final baseline = SyncBaseline(db);
    final before = db.raw.select('SELECT * FROM sync_local').single;
    for (final pair in [('old', 'old'), ('', 'old'), ('bad/id', 'old'),
        ('new', ''), ('new', 'old\n'), ('new', 'a' * 129)]) {
      expect(() => baseline.initializeRestored(pair.$1,
          previousDeviceId: pair.$2), throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_local').single, before);
      expect(facts(db), isEmpty);
    }
    expect(() => db.transaction(() => baseline.initializeRestored('new',
        previousDeviceId: 'old')), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_local').single, before);
  });

  test('非恢复状态和不匹配旧writer不能走恢复入口', () {
    final baseline = SyncBaseline(db);
    db.raw.execute('UPDATE sync_local SET requires_new_identity=0');
    expect(() => baseline.initializeRestored('new', previousDeviceId: 'old'), throwsStateError);
    expect(facts(db), isEmpty);
    db.raw.execute("UPDATE sync_local SET requires_new_identity=1,device_id='different'");
    expect(() => baseline.initializeRestored('new', previousDeviceId: 'old'), throwsStateError);
    expect(facts(db), isEmpty);
    db.raw.execute("UPDATE sync_local SET device_id='old'");
    expect(baseline.initializeRestored('new', previousDeviceId: 'old'), greaterThan(0));
    final count = facts(db).length;
    expect(() => baseline.initializeRestored('new', previousDeviceId: 'old'), throwsStateError);
    expect(facts(db), hasLength(count));
  });

  for (final fixture in [
    ('sync_operations', 'INSERT INTO sync_operations '
        '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
        "VALUES ('prior','old',1,0,'note','restored','raw_content','null','local')"),
    ('sync_publications', 'INSERT INTO sync_publications '
        "(seq,file_name,key_epoch,segment_bytes,sealed,published) VALUES (1,'202610-0001.log',1,X'01',1,1)"),
    ('sync_received_segments', 'INSERT INTO sync_received_segments '
        '(device_id,seq,key_epoch,created_at,op_count,sealed,segment_hash) '
        "VALUES ('peer',1,1,'2026-10-26T00:00:00.000Z',1,1,'${'0' * 64}')"),
    ('sync_state', "INSERT INTO sync_state(device_id,applied_seq) VALUES ('peer',1)"),
  ]) {
    test('恢复仍有${fixture.$1}时保留历史并拒绝切writer', () {
      db.raw.execute(fixture.$2);
      final state = db.raw.select('SELECT * FROM sync_local').single;
      final rows = db.raw.select('SELECT * FROM ${fixture.$1}').toList();
      expect(() => SyncBaseline(db).initializeRestored('new',
          previousDeviceId: 'old'), throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_local').single, state);
      expect(db.raw.select('SELECT * FROM ${fixture.$1}'), rows);
      expect(NoteRepository(db).byId('restored')!.rawContent, '保留恢复原文');
    });
  }

  test('基线写失败完整回滚身份/恢复标志/时钟/操作，排除故障后可提交', () {
    final baseline = SyncBaseline(db, clock: clock);
    final before = db.raw.select('SELECT * FROM sync_local').single;
    db.raw.execute('CREATE TEMP TRIGGER reject_recovery BEFORE INSERT ON sync_operations '
        "WHEN NEW.field='raw_content' BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => baseline.initializeRestored('new', previousDeviceId: 'old'), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_local').single, before);
    expect(facts(db), isEmpty);
    expect(NoteRepository(db).byId('restored')!.rawContent, '保留恢复原文');
    db.raw.execute('DROP TRIGGER reject_recovery');
    expect(baseline.initializeRestored('new', previousDeviceId: 'old'), greaterThan(0));
    expect(db.raw.select('SELECT requires_new_identity FROM sync_local').single.values, [0]);
  });

  test('另一连接只见等待或完整新身份基线，重开后继续使用新writer', () {
    final directory = Directory.systemTemp.createTempSync('restored-identity-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/recovered.db';
    final writer = SeqDatabase.open(path)..migrate();
    writer.raw.execute('PRAGMA journal_mode=WAL');
    final observer = SeqDatabase.open(path)..migrate();
    final note = Note(id: 'n', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '恢复存量', createdAt: clock.now(), updatedAt: clock.now());
    late List<String> ids;
    try {
      NoteRepository(writer).insert(note);
      writer.disconnectSyncForRestore();
      var observations = 0;
      writer.raw.createFunction(functionName: 'observe_restore', directOnly: false,
          argumentCount: const AllowedArgumentCount(0), function: (_) {
        observations++;
        final state = observer.raw.select('SELECT * FROM sync_local').single;
        expect(state['requires_new_identity'], 1); expect(state['enabled'], 0);
        expect(state['device_id'], isNull); expect(state['baseline_ready'], 0);
        expect(facts(observer), isEmpty); return 0;
      });
      writer.raw.execute('CREATE TEMP TRIGGER observe_recovery AFTER INSERT ON sync_operations '
          'BEGIN SELECT observe_restore(); END');
      final count = SyncBaseline(writer, clock: clock).initializeRestored('new',
          previousDeviceId: 'old');
      expect(count, greaterThan(0)); expect(observations, count);
      expect(facts(observer), hasLength(count));
      expect(facts(observer).every((op) => op.deviceId == 'new'), isTrue);
      ids = facts(observer).map((op) => op.opId).toList();
    } finally { observer.close(); writer.close(); }
    final reopened = SeqDatabase.open(path)..migrate();
    try {
      final state = reopened.raw.select('SELECT * FROM sync_local').single;
      expect(state['requires_new_identity'], 0); expect(state['baseline_ready'], 1);
      expect(state['device_id'], 'new'); expect(state['enabled'], 1);
      expect(facts(reopened).map((op) => op.opId), ids);
      NoteRepository(reopened, clock: clock).update(note.copyWith(rawContent: '新身份后续修改'));
      expect(facts(reopened), hasLength(ids.length + 1));
      expect(facts(reopened).last.deviceId, 'new');
      expect(SyncBaseline(reopened).initialize('new'), 0);
    } finally { reopened.close(); }
  });
}
