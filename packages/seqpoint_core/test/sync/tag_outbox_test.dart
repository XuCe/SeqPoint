import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late TagRepository tags;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    tags = TagRepository(db);
    db.raw.execute("UPDATE sync_local SET enabled = 1, device_id = 'pc'");
  });
  tearDown(() => db.close());
  test('内置标签创建捕获且重复初始化保持ID/操作不变', () {
    tags.ensureBuiltins();
    final ids = tags.all().map((t) => t.id).toSet();
    expect(ids, hasLength(builtinTypeTags.length));
    final ops = db.raw.select('SELECT * FROM sync_operations');
    expect(ops, isNotEmpty);
    expect(ops.every((r) => r['object_type'] == 'tag'), isTrue);
    tags.ensureBuiltins();
    expect(tags.all().map((t) => t.id).toSet(), ids);
    expect(db.raw.select('SELECT * FROM sync_operations'), hasLength(ops.length));
  });
  test('upsert重复无操作，改名只记录name，内置标签仍可改名', () {
    tags.ensureBuiltins(); // 与真实启动顺序一致；下方删历史仅为隔离改名断言。
    final tag = tags.upsert(name: '项目A', kind: TagKind.project);
    expect(db.raw.select('SELECT * FROM sync_operations'), isNotEmpty);
    db.raw.execute('DELETE FROM sync_operations');
    expect(tags.upsert(name: '项目A', kind: TagKind.project).id, tag.id);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    tags.rename(tag.id, '项目B');
    expect(db.raw.select('SELECT field FROM sync_operations').single['field'], 'name');
    tags.ensureBuiltins();
    final builtin = tags.all(kind: TagKind.type).first;
    db.raw.execute('DELETE FROM sync_operations');
    tags.rename(builtin.id, '自定义显示名');
    expect(tags.byId(builtin.id)!.builtin, isTrue);
    expect(db.raw.select('SELECT field FROM sync_operations').single['field'], 'name');
  });
  test('upsert操作失败不留下标签，修复后可重试', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_tag_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => tags.upsert(name: '项目A', kind: TagKind.project), throwsA(isA<SqliteException>()));
    expect(tags.all(), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    db.raw.execute('DROP TRIGGER reject_tag_op');
    expect(tags.upsert(name: '项目A', kind: TagKind.project).name, '项目A');
  });
  test('改名唯一冲突或操作失败都保留旧标签和HLC', () {
    final a = tags.upsert(name: 'A', kind: TagKind.project);
    tags.upsert(name: 'B', kind: TagKind.project);
    db.raw.execute('DELETE FROM sync_operations');
    final before = db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single;
    expect(() => tags.rename(a.id, 'B'), throwsA(isA<SqliteException>()));
    db.raw.execute('CREATE TEMP TRIGGER reject_rename_op BEFORE INSERT ON sync_operations '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(() => tags.rename(a.id, 'C'), throwsA(isA<SqliteException>()));
    expect(tags.byId(a.id)!.name, 'A');
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local').single, before);
  });
  test('内置批次中途操作失败，已完成的标签/操作/HLC一起回滚', () {
    db.raw.execute('CREATE TEMP TRIGGER reject_second_builtin BEFORE INSERT ON sync_operations '
        'WHEN (SELECT count(*) FROM tags) > 1 '
        "BEGIN SELECT RAISE(ABORT,'forced'); END");
    expect(tags.ensureBuiltins, throwsA(isA<SqliteException>()));
    expect(tags.all(), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(db.raw.select('SELECT hlc_millis FROM sync_local').single['hlc_millis'], 0);
  });
}
