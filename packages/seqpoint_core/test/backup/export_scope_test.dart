import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService service;
  late ItemRepository items;
  late ActivityRepository activities;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    items = ItemRepository(db);
    activities = ActivityRepository(db);
    service = NoteService(db: db, notes: NoteRepository(db), items: items,
        activities: activities);
  });
  tearDown(() => db.close());
  Set<Object?> ids(Map<String, Object?> json, String table) =>
      (json[table] as List).map((r) => (r as Map)['id']).toSet();

  test('归档开关排除父签及其事项，默认仍包含归档', () {
    final note = service.capture('已归档事项');
    final item = service.lineToItem(note.id, 0);
    service.close(note.id);
    expect(ids(JsonExporter(db).build(), 'notes'), contains(note.id));
    final active = JsonExporter(db, includeArchived: false).build();
    expect(ids(active, 'notes'), isEmpty);
    expect(ids(active, 'items'), isNot(contains(item.id)));
  });

  test('关联标签提醒活动只跟随已导出对象，并区分对象类型', () {
    final keepNote = service.capture('保留');
    final keep = service.lineToItem(keepNote.id, 0);
    final dropNote = service.capture('删除');
    final drop = service.lineToItem(dropNote.id, 0);
    service.trash(dropNote.id);
    final tags = TagRepository(db);
    final used = tags.upsert(name: '保留标签', kind: TagKind.custom);
    final hidden = tags.upsert(name: '隐藏标签', kind: TagKind.custom);
    tags.upsert(name: '未关联标签', kind: TagKind.custom);
    items.setTags(keep.id, [used.id]);
    items.setTags(drop.id, [hidden.id]);
    final reminders = ReminderRepository(db);
    final reminder = reminders.insert(Reminder(id: '', itemId: keep.id,
        mode: ReminderMode.exact));
    reminders.insert(Reminder(id: '', itemId: drop.id, mode: ReminderMode.exact));
    for (final entry in [('tag', used.id), ('reminder', reminder.id),
        ('tag', keep.id), ('unknown', keep.id)]) {
      activities.log(objectType: entry.$1, objectId: entry.$2, action: 'test');
    }
    final json = JsonExporter(db).build();
    expect(ids(json, 'tags'), {used.id});
    expect((json['item_tags'] as List).single,
        {'item_id': keep.id, 'tag_id': used.id});
    expect(ids(json, 'reminders'), {reminder.id});
    final exportedActivities = json['activities'] as List;
    expect(exportedActivities, hasLength(4));
    expect(exportedActivities.every((r) => (r as Map)['object_id'] != drop.id &&
        r['object_id'] != dropNote.id && r['object_type'] != 'unknown'), isTrue);
    expect(exportedActivities.where((r) => (r as Map)['object_type'] == 'tag')
        .map((r) => (r as Map)['object_id']), [used.id]);
  });

  test('回收站父签下未删事项不泄漏，独立完成事项保留', () {
    final note = service.capture('删除父签');
    final child = service.lineToItem(note.id, 0);
    service.trash(note.id);
    final solo = items.insert(Item(id: '', title: '独立已完成',
        status: ItemStatus.done, priority: Priority.p2,
        source: ItemSource.manual, createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026)));
    final json = JsonExporter(db).build();
    expect(ids(json, 'items'), {solo.id});
    final trash = JsonExporter(db, includeTrashed: true).build();
    expect(ids(trash, 'items'), contains(child.id));
    expect(ids(trash, 'notes'), contains(note.id));
  });
}
