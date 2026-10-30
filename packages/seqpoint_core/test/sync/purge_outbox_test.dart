import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late FakeClock clock;
  late NoteService service;
  late Note note;
  late Item one, two;
  late Tag tag;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.utc(2026, 10, 25));
    final items = ItemRepository(db, clock: clock);
    service = NoteService(db: db, notes: NoteRepository(db, clock: clock), items: items,
        activities: ActivityRepository(db, clock: clock), clock: clock);
    note = service.capture('一\n二');
    one = service.lineToItem(note.id, 0); two = service.lineToItem(note.id, 1);
    tag = TagRepository(db).upsert(name: 'A', kind: TagKind.project);
    items.setTags(one.id, [tag.id]); items.setTags(two.id, [tag.id]);
    service.trash(note.id);
    NotificationPlanRepository(db).ensure(key: 'plan1', itemId: one.id, fireAt: clock.now());
    db.raw.execute('INSERT INTO search_index(object_type,object_id,text) VALUES (?,?,?)',
        ['note', note.id, '一二']);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('到期清理捕获便签/所有事项/关联墓碑，保留通知撤销记录', () {
    clock.advance(const Duration(days: 30));
    expect(service.purgeTrash(), 0);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    clock.advance(const Duration(milliseconds: 1));
    expect(service.purgeTrash(), 1);
    expect(db.raw.select('SELECT * FROM notes'), isEmpty);
    expect(db.raw.select('SELECT * FROM items'), isEmpty);
    expect(db.raw.select('SELECT * FROM item_tags'), isEmpty);
    final ops = db.raw.select('SELECT * FROM sync_operations');
    expect(ops, hasLength(5));
    expect(ops.every((r) => r['field'] == Operation.tombstoneField), isTrue);
    expect(TagRepository(db).byId(tag.id), isNotNull);
    expect(db.raw.select('SELECT * FROM notification_plans'), hasLength(1));
    expect(db.raw.select('SELECT * FROM search_index'), isEmpty);
    expect(service.purgeTrash(), 0);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(5));
  });
  for (final type in ['item_tag', 'item', 'note']) {
    test('$type墓碑失败回滚整个清理，修复后可重试', () {
      clock.advance(const Duration(days: 31));
      final beforeIndex = db.raw.select('SELECT * FROM search_index');
      db.raw.execute('CREATE TEMP TABLE reject_type(value TEXT)');
      db.raw.execute('INSERT INTO reject_type(value) VALUES (?)', [type]);
      db.raw.execute('CREATE TEMP TRIGGER reject_purge BEFORE INSERT ON sync_operations '
          "WHEN NEW.field = '__tombstone__' AND NEW.object_type = (SELECT value FROM reject_type) "
          "BEGIN SELECT RAISE(ABORT,'forced'); END");
      expect(service.purgeTrash, throwsA(isA<SqliteException>()));
      expect(NoteRepository(db).byId(note.id)!.deletedAt, isNotNull);
      expect(ItemRepository(db).byId(one.id), isNotNull);
      expect(ItemRepository(db).byId(two.id), isNotNull);
      expect(db.raw.select('SELECT * FROM item_tags'), hasLength(2));
      expect(db.raw.select('SELECT * FROM search_index'), beforeIndex);
      expect(db.raw.select('SELECT * FROM notification_plans'), hasLength(1));
      expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
      expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
      db.raw.execute('DROP TRIGGER reject_purge');
      expect(service.purgeTrash(), 1);
      expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(5));
    });
  }
}
