import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  for (final enabled in [false, true]) {
    test('索引失败时便签/事项与同步操作整体回滚（同步$enabled）', () {
      final db = SeqDatabase.inMemory()..migrate();
      addTearDown(db.close);
      if (enabled) {
        db.raw.execute("UPDATE sync_local SET device_id='writer',enabled=1");
      }
      final now = DateTime.utc(2026, 10, 28);
      final notes = NoteRepository(db);
      final items = ItemRepository(db);
      final note = notes.insert(Note(id: '', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '原始苹果派',
        createdAt: now, updatedAt: now));
      final item = items.insert(Item(id: '', title: '原始会议室',
        status: ItemStatus.todo, priority: Priority.p2, source: ItemSource.manual,
        createdAt: now, updatedAt: now));
      final beforeNotes = db.raw.select('SELECT * FROM notes');
      final beforeItems = db.raw.select('SELECT * FROM items');
      final beforeOps = db.raw.select('SELECT * FROM sync_operations');
      final beforeClock = db.raw.select('SELECT * FROM sync_local');
      db.raw.execute('DROP TABLE search_index');
      expect(() => notes.update(note.copyWith(rawContent: '不应保存')),
        throwsA(isA<SqliteException>()));
      expect(() => items.update(item.copyWith(title: '不应保存')),
        throwsA(isA<SqliteException>()));
      expect(() => notes.insert(Note(id: '', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '不应新增',
        createdAt: now, updatedAt: now)), throwsA(isA<SqliteException>()));
      expect(() => items.insert(Item(id: '', title: '不应新增',
        status: ItemStatus.todo, priority: Priority.p2, source: ItemSource.manual,
        createdAt: now, updatedAt: now)), throwsA(isA<SqliteException>()));
      expect(db.raw.select('SELECT * FROM notes'), beforeNotes);
      expect(db.raw.select('SELECT * FROM items'), beforeItems);
      expect(db.raw.select('SELECT * FROM sync_operations'), beforeOps);
      expect(db.raw.select('SELECT * FROM sync_local'), beforeClock);
    });
  }
}
