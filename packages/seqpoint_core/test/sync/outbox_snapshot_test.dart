import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  late SeqDatabase db;
  const row = <String, Object?>{'name': '业务名', 'kind': 'project', 'builtin': 0,
    'color': null, 'sort': 999, 'window_json': '不应进入协议'};
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    db.raw.execute("UPDATE sync_local SET device_id='writer',enabled=1");
  });
  tearDown(() => db.close());
  test('完整快照只在初始事务生成字段与明确创建标记，实际操作均过协议校验', () {
    final outbox = SyncOutbox(db);
    expect(() => outbox.recordInitialSnapshot('tag', 't', row), throwsStateError);
    final count = db.transaction(() => outbox.recordInitialSnapshot('tag', 't', row));
    expect(count, 6);
    final operations = facts(db);
    expect(operations.map((op) => op.field), contains(Operation.restoreField));
    expect(operations.map((op) => op.field), isNot(contains('window_json')));
    for (final op in operations) { validateIncomingOperation(op, expectedDeviceId: 'writer'); }
    db.raw.execute('UPDATE sync_local SET baseline_ready=1');
    expect(() => db.transaction(() => outbox.recordInitialSnapshot('tag', 'other', row)), throwsStateError);
    expect(facts(db), hasLength(count));
  });
  test('坏对象ID或不可上wire的字段值使快照操作/时钟整体回滚', () {
    final outbox = SyncOutbox(db);
    expect(() => db.transaction(() => outbox.recordInitialSnapshot('tag', 'bad/id', row)), throwsStateError);
    expect(() => db.transaction(() => outbox.recordInitialSnapshot('tag', 't', {...row, 'kind': 'invalid'})), throwsFormatException);
    expect(facts(db), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
}
