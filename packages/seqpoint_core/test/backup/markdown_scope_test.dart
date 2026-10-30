import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late Directory dir;
  late ItemRepository items;
  late NoteService service;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    dir = Directory.systemTemp.createTempSync('seqpoint_md_');
    items = ItemRepository(db);
    service = NoteService(db: db, notes: NoteRepository(db), items: items,
        activities: ActivityRepository(db));
  });
  tearDown(() { db.close(); dir.deleteSync(recursive: true); });
  Item add(String title, {String? noteId, int? line, ItemStatus status = ItemStatus.todo}) =>
      items.insert(Item(id: '', title: title, noteId: noteId, lineIndex: line,
          status: status, priority: Priority.p2, source: ItemSource.manual,
          dueAt: DateTime(2026, 10, 27), createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026)));
  Future<String> contents() async {
    final index = await MarkdownExporter(db).export(dir);
    return index.parent.listSync().whereType<File>()
        .map((f) => f.readAsStringSync()).join('\n');
  }

  test('内存构建提供完整Markdown且不创建目录或文件', () {
    service.capture('内存导出内容');
    final files = MarkdownExporter(db).build();
    expect(files['README.md'], contains('内存导出内容'));
    expect(files.values.join('\n'), contains('内存导出内容'));
    expect(dir.listSync(), isEmpty);
  });

  test('独立事项包含完成状态、期限、标签及索引', () async {
    final item = add('独立已完成', status: ItemStatus.done);
    final tag = TagRepository(db).upsert(name: '项目', kind: TagKind.project);
    items.setTags(item.id, [tag.id]);
    final output = await contents();
    expect(output, contains('- [x] 独立已完成 (2026-10-27'));
    expect(output, contains('#项目'));
    expect(output, contains('[独立事项]('));
  });

  test('行号为空、重复或越界的关联事项均输出一次且保留期限', () async {
    final note = service.capture('正文保留');
    for (final line in [null, 0, 0, 99, -1]) {
      add('事项$line', noteId: note.id, line: line);
    }
    final output = await contents();
    expect('- [ ]'.allMatches(output), hasLength(5));
    expect('(2026-10-27'.allMatches(output), hasLength(5));
  });
  test('同标题且ID前缀相同的便签都有独立文件', () async {
    for (var i = 0; i < 2; i++) {
      final note = service.capture('同名正文');
      db.raw.execute('UPDATE notes SET id = ? WHERE id = ?',
          ['samepref-$i', note.id]);
    }
    final index = await MarkdownExporter(db).export(dir);
    expect(index.parent.listSync().whereType<File>(), hasLength(3));
    expect(index.readAsStringSync().split('\n')
        .where((line) => line.startsWith('- [')), hasLength(2));
  });

  test('旧行号事项不覆盖编辑后的便签原文', () async {
    final note = service.capture('原事项', title: '固定标题');
    service.lineToItem(note.id, 0);
    service.editContent(note.id, '必须保留的新正文');
    final output = await contents();
    expect(output, contains('必须保留的新正文'));
    expect('- [ ] 原事项'.allMatches(output), hasLength(1));
  });

  test('README链接编码文件名并转义标题', () async {
    service.capture(r'Meeting notes [草稿]#% (x)\path');
    final index = await MarkdownExporter(db).export(dir);
    final note = index.parent.listSync().whereType<File>()
        .singleWhere((f) => f.path != index.path);
    const label = r'Meeting notes \[草稿\]#% (x)\\path';
    final link = index.readAsLinesSync().singleWhere((line) => line.startsWith('- ['));
    expect(link, startsWith('- [$label]('));
    final destination = link.substring(link.lastIndexOf('](') + 2, link.length - 1);
    expect(destination, isNot(contains(RegExp(r'[ #()]'))));
    expect(Uri.decodeComponent(destination), note.uri.pathSegments.last);
  });

  test('独立事项取消状态可读，归档/回收站/软删事项按范围过滤', () async {
    add('独立取消事项', status: ItemStatus.canceled);
    final deleted = add('已删独立事项');
    items.update(deleted.copyWith(deletedAt: DateTime.utc(2026)));
    final archived = service.capture('归档内容');
    service.close(archived.id);
    final trash = service.capture('回收站内容');
    add('回收站关联', noteId: trash.id);
    service.trash(trash.id);
    final output = await contents();
    expect(output, contains('~~独立取消事项~~ · 已取消'));
    expect(output, contains('归档内容'));
    expect(output, isNot(contains('已删独立事项')));
    expect(output, isNot(contains('回收站')));
    final active = await MarkdownExporter(db, includeArchived: false).export(dir);
    expect(active.readAsStringSync(), isNot(contains('归档内容')));
  });
}
