import 'package:test/test.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  test('本地事项创建编辑及删除恢复自动维护三字全文索引', () async {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 28);
    final repo = ItemRepository(db);
    final search = SearchService(db);
    var item = repo.insert(Item(id: '', title: '安排苹果派试吃',
      status: ItemStatus.todo, priority: Priority.p2, source: ItemSource.manual,
      createdAt: now, updatedAt: now));
    expect((await search.query('苹果派')).map((h) => h.objectId), [item.id]);
    item = item.copyWith(title: '安排柠檬茶试喝'); repo.update(item);
    expect(await search.query('苹果派'), isEmpty);
    expect((await search.query('柠檬茶')).map((h) => h.objectId), [item.id]);
    item = item.copyWith(deletedAt: now); repo.update(item);
    expect(await search.query('柠檬茶'), isEmpty);
    expect(db.raw.select("SELECT * FROM search_index WHERE object_type='item'"), isEmpty);
    repo.update(item.copyWith(clearDeletedAt: true));
    expect((await search.query('柠檬茶')).map((h) => h.objectId), [item.id]);
  });

  test('本地便签创建编辑及删除恢复自动维护三字全文索引', () async {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 28);
    final repo = NoteRepository(db);
    final search = SearchService(db);
    var note = repo.insert(Note(id: '', kind: NoteKind.text, status: NoteStatus.active,
      title: '原生标题索引', rawContent: '今天品尝苹果派', createdAt: now, updatedAt: now));
    expect((await search.query('苹果派')).map((h) => h.objectId), [note.id]);
    expect((await search.query('标题索引')).map((h) => h.objectId), [note.id]);
    note = note.copyWith(title: '更新标题', rawContent: '改喝柠檬茶'); repo.update(note);
    expect(await search.query('苹果派'), isEmpty);
    expect((await search.query('柠檬茶')).map((h) => h.objectId), [note.id]);
    note = note.copyWith(deletedAt: now); repo.update(note);
    expect(await search.query('柠檬茶'), isEmpty);
    expect(db.raw.select("SELECT * FROM search_index WHERE object_type='note'"), isEmpty);
    repo.update(note.copyWith(clearDeletedAt: true));
    expect((await search.query('柠檬茶')).map((h) => h.objectId), [note.id]);
  });
}
