import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late ItemRepository items;
  late Item item;
  late Tag a, b;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    items = ItemRepository(db);
    final service = NoteService(db: db, notes: NoteRepository(db), items: items,
        activities: ActivityRepository(db));
    item = service.lineToItem(service.capture('标签事项').id, 0);
    a = TagRepository(db).upsert(name: 'A', kind: TagKind.project);
    b = TagRepository(db).upsert(name: 'B', kind: TagKind.project);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('仅变更关联集合；重复设置/添加不删除重建或重复发操作', () {
    items.setTags(item.id, [a.id]);
    final created = db.raw.select('SELECT * FROM sync_operations');
    expect(created, isNotEmpty);
    expect(created.every((r) => r['object_type'] == 'item_tag'), isTrue);
    db.raw.execute('DELETE FROM sync_operations');
    db.raw.execute('CREATE TEMP TRIGGER reject_unchanged_delete BEFORE DELETE ON item_tags '
        "BEGIN SELECT RAISE(ABORT,'unchanged association deleted'); END");
    items.setTags(item.id, [a.id, a.id]);
    items.addTag(item.id, a.id);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_unchanged_delete');
    items.setTags(item.id, [b.id, b.id]);
    final removed = db.raw.select('SELECT * FROM sync_operations WHERE object_id = ?',
        [Operation.itemTagId(item.id, a.id)]).single;
    expect(removed['field'], Operation.tombstoneField);
    expect(items.tagIdsOf(item.id), [b.id]);
  });
  test('关联写或操作写失败保留旧集合且无半条操作', () {
    items.setTags(item.id, [a.id]);
    db.raw.execute('DELETE FROM sync_operations');
    expect(() => items.setTags(item.id, ['missing']), throwsA(isA<SqliteException>()));
    expect(items.tagIdsOf(item.id), [a.id]);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    final before = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    db.raw.execute('CREATE TEMP TRIGGER reject_new_link BEFORE INSERT ON sync_operations '
        "WHEN NEW.object_type = 'item_tag' AND NEW.field = 'present' "
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => items.setTags(item.id, [b.id]), throwsA(isA<SqliteException>()));
    expect(items.tagIdsOf(item.id), [a.id]);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, before);
  });
  test('关联ID确定且双方ID含分隔符时仍无歧义', () {
    final id = Operation.itemTagId('a:b', 'c');
    expect(id, Operation.itemTagId('a:b', 'c'));
    expect(id, isNot(Operation.itemTagId('a', 'b:c')));
    expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
  });
}
