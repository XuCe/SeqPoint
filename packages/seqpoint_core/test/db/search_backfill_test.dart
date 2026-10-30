import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('v10缺失或过期的索引升级时回填一次且排除已删除对象', () async {
    final db = SeqDatabase.inMemory();
    for (var version = 1; version <= 10; version++) {
      for (final sql in migrations[version]!) { db.raw.execute(sql); }
    }
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 28);
    final notes = NoteRepository(db);
    Note create(String text, {DateTime? deletedAt}) => notes.insert(Note(
      id: '', kind: NoteKind.text, status: NoteStatus.closed,
      title: '迁移标题索引', rawContent: text, createdAt: now,
      updatedAt: now, deletedAt: deletedAt));
    final note = create('旧库苹果派');
    create('删除柠檬茶', deletedAt: now);
    final items = ItemRepository(db);
    final item = items.insert(Item(id: '', title: '旧库会议室',
      status: ItemStatus.done, priority: Priority.p2, source: ItemSource.manual,
      createdAt: now, updatedAt: now));
    items.insert(Item(id: 'deleted', title: '删除柠檬茶',
      status: ItemStatus.todo, priority: Priority.p2, source: ItemSource.manual,
      createdAt: now, updatedAt: now, deletedAt: now));
    db.raw.execute('DELETE FROM search_index');
    db.raw.execute("INSERT INTO search_index VALUES ('note','ghost','过期索引词')");
    db.raw.execute('PRAGMA user_version=10');
    db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
    final search = SearchService(db);
    expect((await search.query('苹果派')).map((h) => h.objectId), [note.id]);
    expect((await search.query('标题索引')).map((h) => h.objectId), [note.id]);
    expect((await search.query('会议室')).map((h) => h.objectId), [item.id]);
    expect(await search.query('柠檬茶'), isEmpty);
    expect(db.raw.select('SELECT * FROM search_index'), hasLength(2));
    db.migrate();
    expect(db.raw.select('SELECT * FROM search_index'), hasLength(2));
  });
}
