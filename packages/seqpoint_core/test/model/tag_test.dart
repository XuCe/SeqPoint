import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('想法优先固定角色，改名不漂移，普通type兼容逻辑名', () {
    expect(const Tag(id: 'legacy', name: '灵感', kind: TagKind.type,
        builtin: true, sort: 80).isIdea, isTrue);
    expect(const Tag(id: 'legacy', name: '想法', kind: TagKind.type,
        builtin: true, sort: 0).isIdea, isFalse);
    expect(const Tag(id: 'builtin-type:8', name: '灵感', kind: TagKind.type).isIdea, isTrue);
    expect(const Tag(id: 'ordinary', name: '想法 (ordinary)', logicalName: '想法',
        kind: TagKind.type).isIdea, isTrue);
    for (final kind in [TagKind.project, TagKind.custom]) {
      expect(Tag(id: 'ordinary', name: '想法', logicalName: '想法', kind: kind).isIdea, isFalse);
    }
  });
  test('复制未改显示名保留逻辑名，真实改名清除派生元数据', () {
    const tag = Tag(id: 't', name: '同名 (t)', logicalName: '同名', kind: TagKind.project);
    expect(tag.copyWith(color: '#fff').logicalName, '同名');
    expect(tag.copyWith(name: '同名 (t)').logicalName, '同名');
    expect(tag.copyWith(name: '用户新名').logicalName, isNull);
  });
  test('仓储行映射读取本机逻辑名', () {
    final db = SeqDatabase.inMemory()..migrate(); addTearDown(db.close);
    final repo = TagRepository(db);
    final tag = repo.upsert(name: '同名', kind: TagKind.project);
    db.raw.execute('UPDATE tags SET name=?,logical_name=? WHERE id=?',
        ['同名 (t)', '同名', tag.id]);
    final read = repo.byId(tag.id)!;
    expect(read.name, '同名 (t)'); expect(read.logicalName, '同名');
  });
}
