import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('内置角色改名关闭重开后仍用于今日与提醒查询', () {
    final temp = Directory.systemTemp.createTempSync('seqpoint-idea-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final path = '${temp.path}/test.sqlite';
    var db = SeqDatabase.open(path)..migrate();
    final tags = TagRepository(db)..ensureBuiltins();
    tags.rename('builtin-type:8', '灵感');
    tags.rename('builtin-type:0', '想法');
    final day = DateTime(2026, 10, 26);
    final repo = ItemRepository(db);
    for (final role in [0, 8]) {
      final id = 'item-$role';
      repo.insert(Item(id: id, title: id, status: ItemStatus.todo,
          priority: Priority.p4, source: ItemSource.manual,
          createdAt: day, updatedAt: day, dueAt: day));
      repo.addTag(id, 'builtin-type:$role');
    }
    db.close();
    db = SeqDatabase.open(path)..migrate();
    addTearDown(db.close);
    TagRepository(db).ensureBuiltins();
    final reopened = ItemRepository(db);
    expect(TagRepository(db).all(), hasLength(9));
    expect(reopened.remindable().map((i) => i.id), ['item-0']);
    expect(reopened.dueOn(day).map((i) => i.id), ['item-0']);
    expect(reopened.overdue(day.add(const Duration(hours: 1)))
        .map((i) => i.id), ['item-0']);
  });
  test('今日和提醒按角色排除想法，项目与自定义同名保留', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final repo = ItemRepository(db);
    final day = DateTime(2026, 10, 26);
    const tags = [
      Tag(id: 'builtin-type:8', name: '灵感', kind: TagKind.type,
          builtin: true, sort: 80),
      Tag(id: 'builtin-type:0', name: '想法', kind: TagKind.type,
          builtin: true),
      Tag(id: 'project', name: '想法 (项目)', logicalName: '想法',
          kind: TagKind.project),
      Tag(id: 'custom', name: '想法 (自定义)', logicalName: '想法',
          kind: TagKind.custom),
      Tag(id: 'ordinary', name: '想法 (普通类型)', logicalName: '想法',
          kind: TagKind.type),
      Tag(id: 'legacy-idea', name: '遗留灵感', kind: TagKind.type,
          builtin: true, sort: 80),
      Tag(id: 'legacy-other', name: '想法 (遗留其他)', logicalName: '想法',
          kind: TagKind.type, builtin: true, sort: 10),
    ];
    for (final tag in tags) {
      db.raw.execute('INSERT INTO tags(id,name,kind,builtin,sort,logical_name) '
          'VALUES (?,?,?,?,?,?)', [tag.id, tag.name, tag.kind.dbValue,
          tag.builtin ? 1 : 0, tag.sort, tag.logicalName]);
      repo.insert(Item(id: tag.id, title: tag.name, status: ItemStatus.todo,
          priority: Priority.p4, source: ItemSource.manual,
          createdAt: day, updatedAt: day,
          dueAt: day.add(const Duration(hours: 1))));
      repo.addTag(tag.id, tag.id);
    }
    const visible = ['builtin-type:0', 'project', 'custom', 'legacy-other'];
    expect(repo.openAll(), hasLength(7));
    expect(repo.remindable().map((i) => i.id), unorderedEquals(visible));
    expect(repo.dueOn(day).map((i) => i.id), unorderedEquals(visible));
    expect(repo.overdue(day.add(const Duration(hours: 2))).map((i) => i.id),
        unorderedEquals(visible));
    for (final item in repo.openAll()) {
      repo.update(item.copyWith(status: ItemStatus.done, completedAt: day));
    }
    expect(repo.completedOn(day).map((i) => i.id), unorderedEquals(visible));
  });
}
