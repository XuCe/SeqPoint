import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Operation make({String type = 'note', String field = 'raw_content', Object? value = '文本',
  String device = 'peer', String? hlcDevice, int millis = 1, int counter = 0,
  String id = 'op1', String? objectId}) => Operation(opId: id, deviceId: device,
      hlc: Hlc(millis: millis, counter: counter, deviceId: hlcDevice ?? device),
      objectType: type, objectId: objectId ?? (type == 'item_tag' ? Operation.itemTagId('i1', 't1') : 'n1'),
      field: field, value: value);

void main() {
  test('四类合法业务字段、UTC时间及明确标记可通过', () {
    for (final (type, field, value) in <(String, String, Object?)>[
      ('note', 'raw_content', '正文\n保留'), ('note', 'title', null),
      ('item', 'status', 'todo'), ('item', 'note_id', null),
      ('tag', 'name', '项目'), ('tag', 'sort', -1),
      ('item_tag', 'item_id', 'i1'), ('item_tag', 'tag_id', 't1'),
      ('item_tag', 'present', true),
      ('note', 'created_at', '2026-10-25T00:00:00.000Z'),
      ('item', 'due_at', null), ('note', Operation.tombstoneField, true),
      ('note', Operation.restoreField, true),
    ]) {
      expect(() => validateIncomingOperation(make(type: type, field: field, value: value),
          expectedDeviceId: 'peer'), returnsNormally);
    }
  });
  test('作者/HLC不符、坏身份、未知/本机字段及错误类型拒绝', () {
    for (final operation in [
      make(device: 'other'), make(hlcDevice: 'other'), make(counter: -1),
      make(millis: -1), make(id: ''), make(objectId: '../n1'),
      make(type: 'secret'), make(field: 'window_json'), make(field: 'hlc'),
      make(field: 'raw_content', value: 1), make(field: 'pinned', value: true),
      make(field: 'status', value: 'unknown'), make(type: 'item', field: 'source_ref_json'),
      make(type: 'item', field: 'title', value: null),
      make(type: 'item', field: 'line_index', value: -1),
      make(type: 'tag', field: 'builtin', value: 2),
      make(field: Operation.restoreField, value: false),
    ]) {
      expect(() => validateIncomingOperation(operation, expectedDeviceId: 'peer'),
          throwsFormatException);
    }
  });
  test('日期必须为规范UTC且不能溢出，关联ID和字段须吻合', () {
    for (final operation in [
      make(field: 'created_at', value: null),
      make(field: 'created_at', value: '2026-02-31T00:00:00.000Z'),
      make(field: 'created_at', value: '2026-10-25T00:00:00'),
      make(field: 'created_at', value: '2026-10-25T08:00:00.000+08:00'),
      make(millis: 8640000000000001), make(id: 'bad\n'),
      make(type: 'item_tag', field: 'present', value: true, objectId: 'not-an-association'),
      make(type: 'item_tag', field: 'item_id', value: 'wrong'),
      make(type: 'item_tag', field: 'tag_id', value: 'wrong'),
      make(type: 'item_tag', field: 'present', value: false),
      make(type: 'item_tag', field: Operation.restoreField, value: true,
          objectId: Operation.itemTagId('../i1', 't1')),
    ]) {
      expect(() => validateIncomingOperation(operation, expectedDeviceId: 'peer'),
          throwsFormatException);
    }
    final id = Operation.itemTagId('a:b', 'builtin-type:8');
    expect(Operation.itemTagIds(id), (itemId: 'a:b', tagId: 'builtin-type:8'));
  });
  test('真实仓储产出的全部字段可通过严格加密段往返', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    db.raw.execute('UPDATE sync_local SET enabled = 1, device_id = ?', [keys.deviceId]);
    final tags = TagRepository(db)..ensureBuiltins();
    final items = ItemRepository(db);
    final service = NoteService(db: db, notes: NoteRepository(db), items: items,
        activities: ActivityRepository(db));
    final note = service.capture('原始行');
    final item = service.lineToItem(note.id, 0);
    items.setTags(item.id, [tags.all().first.id]);
    service.toggleItem(item.id);
    service.trash(note.id); service.restore(note.id);
    final ops = db.raw.select('SELECT * FROM sync_operations ORDER BY hlc_millis,hlc_counter')
        .map((r) => Operation(opId: r['op_id'] as String, deviceId: r['device_id'] as String,
          hlc: Hlc(millis: r['hlc_millis'] as int, counter: r['hlc_counter'] as int,
              deviceId: r['device_id'] as String), objectType: r['object_type'] as String,
          objectId: r['object_id'] as String, field: r['field'] as String,
          value: jsonDecode(r['value_json'] as String))).toList();
    final codec = EncryptedSegmentCodec(vaultPublicId: 'test', deviceKeys: keys,
        epochKeys: {1: List.filled(32, 3)}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
    final header = Segment(deviceId: keys.deviceId, keyEpoch: 1, seq: 1,
        opCount: ops.length, createdAt: DateTime.now().toUtc(), payload: []);
    final decoded = await codec.decode(await codec.encode(header, ops));
    expect(decoded.map((o) => o.toJson()), ops.map((o) => o.toJson()));
  });
}
