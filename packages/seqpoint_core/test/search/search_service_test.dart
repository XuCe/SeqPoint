import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService service;
  late SearchService search;
  late FakeClock clock;

  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.parse('2026-09-05T09:00:00+08:00'));
    service = NoteService(
      db: db,
      notes: NoteRepository(db, clock: clock),
      items: ItemRepository(db, clock: clock),
      activities: ActivityRepository(db, clock: clock),
      clock: clock,
    );
    search = SearchService(db);
  });

  tearDown(() => db.close());

  for (final query in ['报价', '客户报价']) {
    test('$query搜索隐藏已删除父便签的事项，恢复后保留完成和删除状态', () async {
      final note = service.capture('客户报价待办\n客户报价完成\n客户报价删除');
      final todo = service.lineToItem(note.id, 0);
      final done = service.toggleItem(service.lineToItem(note.id, 1).id);
      final removed = service.lineToItem(note.id, 2);
      ItemRepository(db).update(removed.copyWith(deletedAt: clock.now()));
      final independent = ItemRepository(db).insert(Item(id: '', title: '客户报价独立',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: clock.now(), updatedAt: clock.now()));
      search.indexNote(note.id, note.rawContent);
      for (final item in [todo, done, removed, independent]) {
        search.indexItem(item.id, item.title);
      }
      Set<String> ids(List<SearchHit> hits) => hits.map((h) => h.objectId).toSet();
      expect(ids(await search.query(query)), {note.id, todo.id, done.id, independent.id});
      service.trash(note.id);
      expect(ids(await search.query(query)), {independent.id});
      expect(ids(await search.query(query, includeArchived: false)), {independent.id});
      service.restore(note.id);
      expect(ids(await search.query(query)), {note.id, todo.id, done.id, independent.id});
      expect(ids(await search.query(query, includeArchived: false)),
        {note.id, todo.id, independent.id});
      service.close(note.id);
      expect(ids(await search.query(query)), containsAll([note.id, todo.id, done.id]));
    });
  }

  test('中文子串可搜到：搜"报价"命中"回复张三报价"', () async {
    final note = service.capture('回复张三报价\n检查生产 nginx 证书');
    search.indexNote(note.id, note.rawContent);

    final hits = await search.query('张三报价');
    expect(hits, hasLength(1));
    expect(hits.first.objectId, note.id);
    expect(hits.first.isNote, isTrue);
  });

  test('不足三字的查询回落到 LIKE，仍能命中', () async {
    final note = service.capture('周报要交了');
    search.indexNote(note.id, note.rawContent);

    final hits = await search.query('周报');
    expect(hits, hasLength(1));
    expect(hits.first.objectId, note.id);
  });

  test('事项标题可被搜到', () async {
    final note = service.capture('检查生产 nginx 证书');
    final item = service.lineToItem(note.id, 0);
    search.indexItem(item.id, item.title);

    final hits = await search.query('nginx 证书');
    expect(hits.any((h) => h.objectId == item.id), isTrue);
  });

  test('软删除的便签不出现在结果里', () async {
    final note = service.capture('这条会被删掉的记录');
    search.indexNote(note.id, note.rawContent);
    expect(await search.query('会被删掉'), hasLength(1));

    service.trash(note.id);
    expect(await search.query('会被删掉'), isEmpty);
  });

  test('归档的便签默认可搜到，可选排除', () async {
    final note = service.capture('已经办完的事情记录');
    search.indexNote(note.id, note.rawContent);
    service.close(note.id);

    final all = await search.query('办完的事情');
    expect(all, hasLength(1));
    expect(all.first.archived, isTrue);

    expect(await search.query('办完的事情', includeArchived: false), isEmpty);
  });

  test('重复索引同一对象不产生重复命中', () async {
    final note = service.capture('重复索引测试内容');
    search.indexNote(note.id, note.rawContent);
    search.indexNote(note.id, note.rawContent);

    expect(await search.query('索引测试'), hasLength(1));
  });

  test('rebuild 能从现有数据重建索引', () async {
    final note = service.capture('重建索引的样例便签');
    service.lineToItem(note.id, 0);

    // 模拟旧版本遗留的缺失索引。
    db.raw.execute('DELETE FROM search_index');
    expect(await search.query('重建索引'), isEmpty);

    final count = search.rebuild();
    expect(count, 2, reason: '一条便签 + 一个事项');
    expect(await search.query('重建索引'), isNotEmpty);
  });

  test('含双引号的查询不会破坏 FTS 语法', () async {
    final note = service.capture('他说"明天再说"这件事');
    search.indexNote(note.id, note.rawContent);

    expect(() => search.query('"明天再说"'), returnsNormally);
  });

  test('空查询返回空结果', () async {
    expect(await search.query('   '), isEmpty);
  });
}
