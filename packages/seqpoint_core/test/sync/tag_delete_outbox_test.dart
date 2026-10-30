import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late TagRepository tags;
  late ItemRepository items;
  late Item one, two;
  late Tag a, b;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    tags = TagRepository(db); items = ItemRepository(db);
    final service = NoteService(db: db, notes: NoteRepository(db), items: items,
        activities: ActivityRepository(db));
    final note = service.capture('一\n二');
    one = service.lineToItem(note.id, 0); two = service.lineToItem(note.id, 1);
    a = tags.upsert(name: 'A', kind: TagKind.project);
    b = tags.upsert(name: 'B', kind: TagKind.project);
    items.setTags(one.id, [a.id, b.id]); items.setTags(two.id, [a.id]);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('删除标签前显式捕获所有关联墓碑，事项和其他标签保留', () {
    tags.delete(a.id);
    expect(tags.byId(a.id), isNull);
    expect(items.tagIdsOf(one.id), [b.id]);
    expect(items.tagIdsOf(two.id), isEmpty);
    final ops = db.raw.select('SELECT * FROM sync_operations');
    expect(ops, hasLength(3));
    expect(ops.every((r) => r['field'] == Operation.tombstoneField), isTrue);
    expect(ops.map((r) => r['object_id']).toSet(), {
      a.id, Operation.itemTagId(one.id, a.id), Operation.itemTagId(two.id, a.id)});
    expect(items.byId(one.id), isNotNull);
  });
  test('合并只迁移缺失目标关联，保留目标并记录源墓碑', () {
    tags.merge(fromId: a.id, intoId: b.id);
    expect(tags.byId(a.id), isNull);
    expect(tags.byId(b.id), isNotNull);
    expect(items.tagIdsOf(one.id), [b.id]);
    expect(items.tagIdsOf(two.id), [b.id]);
    final ops = db.raw.select('SELECT * FROM sync_operations');
    expect(ops.where((r) => r['object_id'] == Operation.itemTagId(one.id, b.id)), isEmpty);
    expect(ops.where((r) => r['object_id'] == a.id).single['field'], Operation.tombstoneField);
    expect(ops.where((r) => r['field'] == 'present'), hasLength(1));
  });
  test('内置删除/合并自身不变更关联、标签或操作', () {
    tags.ensureBuiltins();
    final builtin = tags.all(kind: TagKind.type).first;
    items.addTag(one.id, builtin.id);
    db.raw.execute('DELETE FROM sync_operations');
    tags.delete(builtin.id);
    expect(tags.byId(builtin.id), isNotNull);
    expect(items.tagIdsOf(one.id), contains(builtin.id));
    tags.merge(fromId: a.id, intoId: a.id);
    expect(tags.byId(a.id), isNotNull);
    expect(items.tagIdsOf(two.id), [a.id]);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });
  for (final action in ['delete', 'merge']) {
    test('$action源标签操作失败还原全部关联/标签/HLC', () {
      db.raw.execute('CREATE TEMP TRIGGER reject_tag_tombstone BEFORE INSERT ON sync_operations '
          "WHEN NEW.object_type = 'tag' AND NEW.field = '__tombstone__' "
          "BEGIN SELECT RAISE(ABORT,'forced'); END");
      expect(() => action == 'delete' ? tags.delete(a.id) : tags.merge(fromId: a.id, intoId: b.id),
          throwsA(isA<SqliteException>()));
      expect(tags.byId(a.id), isNotNull);
      expect(items.tagIdsOf(one.id).toSet(), {a.id, b.id});
      expect(items.tagIdsOf(two.id), [a.id]);
      expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
    });
  }
}
