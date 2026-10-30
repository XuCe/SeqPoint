import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Map<String, List<List<Object?>>> _snapshot(SeqDatabase db) => {
  for (final table in ['notes', 'items', 'tags', 'item_tags', 'reminders',
    'attachments', 'search_index', 'activities'])
    table: db.raw.select('SELECT * FROM $table ORDER BY rowid')
      .map((r) => r.values.toList()).toList(),
};

void main() {
  late SeqDatabase db;
  late FakeClock clock;
  late NoteRepository notes;
  late ItemRepository items;
  late NoteService service;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime(2026, 10, 23, 12));
    notes = NoteRepository(db, clock: clock);
    items = ItemRepository(db, clock: clock);
    service = NoteService(db: db, notes: notes, items: items,
      activities: ActivityRepository(db, clock: clock), clock: clock);
  });
  tearDown(() => db.close());

  test('回收站到期便签连同各状态及单独删除的事项一起清理', () {
    final note = service.capture('未完成事项\n已完成事项\n单独删除事项\n已取消事项');
    final children = [for (var i = 0; i < 4; i++) service.lineToItem(note.id, i)];
    service.toggleItem(children[1].id);
    items.update(children[2].copyWith(deletedAt: clock.now()));
    items.update(children[3].copyWith(status: ItemStatus.canceled));
    service.trash(note.id);
    clock.advance(const Duration(days: 31));
    late int removed;
    expect(() => removed = service.purgeTrash(), returnsNormally);
    expect(removed, 1);
    expect(notes.byId(note.id), isNull);
    for (final item in children) {
      expect(items.byId(item.id), isNull);
    }
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
    expect(service.purgeTrash(), 0);
  });

  test('整批清理中途失败回滚便签事项索引和级联数据，重试成功', () {
    final tag = TagRepository(db).upsert(name: '回滚标签', kind: TagKind.custom);
    for (final title in ['待清理甲', '待清理乙']) {
      final note = service.capture(title);
      final item = service.lineToItem(note.id, 0);
      items.setTags(item.id, [tag.id]);
      db.raw.execute('INSERT INTO reminders (id,item_id,mode) VALUES (?,?,?)',
        ['r-${item.id}', item.id, 'exact']);
      db.raw.execute('INSERT INTO attachments (id,note_id,item_id,created_at) VALUES (?,?,?,?)',
        ['a-${item.id}', note.id, item.id, clock.now().toIso8601String()]);
      service.trash(note.id);
    }
    clock.advance(const Duration(days: 31));
    final active = service.capture('正常保留');
    final activeItem = service.lineToItem(active.id, 0);
    final before = _snapshot(db);
    db.raw.execute('CREATE TRIGGER reject_last_purge BEFORE DELETE ON notes '
      'WHEN (SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL) = 1 '
      "BEGIN SELECT RAISE(ABORT, 'purge blocked'); END;");
    expect(() => service.purgeTrash(), throwsA(predicate((e) => e.toString().contains('purge blocked'))));
    expect(_snapshot(db), before);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_last_purge');
    expect(service.purgeTrash(), 2);
    expect(notes.byId(active.id), isNotNull);
    expect(items.byId(activeItem.id), isNotNull);
    for (final table in ['item_tags', 'reminders', 'attachments']) {
      expect(db.raw.select('SELECT * FROM $table'), isEmpty);
    }
    expect(db.raw.select('SELECT object_type,object_id FROM search_index').map((r) => r.values.toList()),
      unorderedEquals([['note', active.id], ['item', activeItem.id]]));
    expect(_snapshot(db)['activities'], before['activities']);
  });

  test('按归属清理提醒附件标签关联与搜索索引，保留正常关联及共享标签', () {
    final tag = TagRepository(db).upsert(name: '共享标签', kind: TagKind.custom);
    final doomed = service.capture('删除链路');
    final doomedItem = service.lineToItem(doomed.id, 0);
    final kept = service.capture('保留链路');
    final keptItem = service.lineToItem(kept.id, 0);
    for (final (note, item) in [(doomed, doomedItem), (kept, keptItem)]) {
      items.setTags(item.id, [tag.id]);
      db.raw.execute('INSERT INTO reminders (id,item_id,mode) VALUES (?,?,?)',
        ['r-${item.id}', item.id, 'exact']);
      for (final (type, noteId, itemId) in [('note', note.id, null),
        ('item', null, item.id), ('both', note.id, item.id)]) {
        db.raw.execute('INSERT INTO attachments (id,note_id,item_id,created_at) VALUES (?,?,?,?)',
          ['$type-${item.id}', noteId, itemId, clock.now().toIso8601String()]);
      }
    }
    service.trash(doomed.id);
    clock.advance(const Duration(days: 31));
    expect(service.purgeTrash(), 1);
    expect(notes.byId(doomed.id), isNull);
    expect(items.byId(doomedItem.id), isNull);
    expect(notes.byId(kept.id), isNotNull);
    expect(items.byId(keptItem.id), isNotNull);
    expect(db.raw.select('SELECT id FROM tags').single['id'], tag.id);
    expect(db.raw.select('SELECT item_id FROM item_tags').single['item_id'], keptItem.id);
    expect(db.raw.select('SELECT item_id FROM reminders').single['item_id'], keptItem.id);
    expect(db.raw.select('SELECT id FROM attachments').map((r) => r['id']),
      unorderedEquals([for (final type in ['note', 'item', 'both']) '$type-${keptItem.id}']));
    expect(db.raw.select('SELECT object_type,object_id FROM search_index').map((r) => r.values.toList()),
      unorderedEquals([['note', kept.id], ['item', keptItem.id]]));
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('空回收站重复清理不改数据，零保留期限可清理已删除便签', () {
    final kept = service.capture('正常便签');
    final keptItem = service.lineToItem(kept.id, 0);
    final before = _snapshot(db);
    expect(service.purgeTrash(), 0);
    expect(service.purgeTrash(), 0);
    expect(_snapshot(db), before);
    final doomed = service.capture('刚放入回收站');
    service.lineToItem(doomed.id, 0);
    service.trash(doomed.id);
    final recent = _snapshot(db);
    expect(service.purgeTrash(), 0);
    expect(_snapshot(db), recent);
    clock.advance(const Duration(microseconds: 1));
    expect(service.purgeTrash(olderThan: Duration.zero), 1);
    expect(notes.byId(doomed.id), isNull);
    expect(notes.byId(kept.id), isNotNull);
    expect(items.byId(keptItem.id), isNotNull);
    final cleared = _snapshot(db);
    expect(service.purgeTrash(olderThan: Duration.zero), 0);
    expect(_snapshot(db), cleared);
  });

  test('清理不改变正常、归档、恢复、近期或恰好到期的便签及独立事项', () {
    final target = service.capture('到期回收站');
    final targetItem = service.lineToItem(target.id, 0);
    service.trash(target.id);
    final active = service.capture('正常便签');
    service.lineToItem(active.id, 0);
    final archived = service.capture('归档便签');
    service.lineToItem(archived.id, 0);
    service.close(archived.id);
    final restored = service.capture('恢复便签');
    service.lineToItem(restored.id, 0);
    service.trash(restored.id);
    clock.advance(const Duration(days: 1));
    final boundary = service.capture('恰好30天');
    service.lineToItem(boundary.id, 0);
    service.trash(boundary.id);
    clock.advance(const Duration(days: 30));
    final recent = service.capture('刚删除');
    service.lineToItem(recent.id, 0);
    service.trash(recent.id);
    service.restore(restored.id);
    items.insert(Item(id: '', title: '独立事项', status: ItemStatus.todo,
      priority: Priority.p1, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now()));
    const noteSql = 'SELECT * FROM notes WHERE id <> ? ORDER BY id';
    const itemSql = 'SELECT * FROM items WHERE note_id IS NULL OR note_id <> ? ORDER BY id';
    final beforeNotes = db.raw.select(noteSql, [target.id]).map((r) => r.values.toList()).toList();
    final beforeItems = db.raw.select(itemSql, [target.id]).map((r) => r.values.toList()).toList();
    expect(service.purgeTrash(), 1);
    expect(notes.byId(target.id), isNull);
    expect(items.byId(targetItem.id), isNull);
    expect(db.raw.select(noteSql, [target.id]).map((r) => r.values.toList()).toList(), beforeNotes);
    expect(db.raw.select(itemSql, [target.id]).map((r) => r.values.toList()).toList(), beforeItems);
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
}
