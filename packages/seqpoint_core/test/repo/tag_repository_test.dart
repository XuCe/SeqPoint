import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late TagRepository tags;

  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    tags = TagRepository(db)..ensureBuiltins();
  });

  tearDown(() => db.close());

  test('内置类型标签写入且幂等', () {
    final first = tags.all(kind: TagKind.type).length;
    tags.ensureBuiltins();
    expect(tags.all(kind: TagKind.type).length, first);
    expect(first, builtinTypeTags.length);
  });

  test('项目标签按名去重', () {
    final a = tags.upsert(name: '项目A', kind: TagKind.project);
    final b = tags.upsert(name: '项目A', kind: TagKind.project);
    expect(a.id, b.id);
  });

  test('内置标签不可删除，只可重命名', () {
    final idea = tags.byName('想法', TagKind.type)!;
    tags.delete(idea.id);
    expect(tags.byId(idea.id), isNotNull);
    tags.rename(idea.id, '灵感');
    expect(tags.byId(idea.id)!.name, '灵感');
  });
}
