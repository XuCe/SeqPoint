import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/tag_merge.dart';
import 'package:test/test.dart';

List<Operation> tag(String id, {String name = '同名', String kind = 'project',
    int builtin = 0, int sort = 0}) {
  final values = {'name': name, 'kind': kind, 'builtin': builtin,
    'color': null, 'sort': sort};
  var counter = 0;
  return values.entries.map((e) => Operation(opId: '$id-${e.key}', deviceId: id,
      hlc: Hlc(millis: 1, counter: counter++, deviceId: id), objectType: 'tag',
      objectId: id, field: e.key, value: e.value)).toList();
}

Operation delta(String id, String field, Object? value, int millis) => Operation(
    opId: '$id-$field-$millis', deviceId: 'editor',
    hlc: Hlc(millis: millis, counter: 0, deviceId: 'editor'),
    objectType: 'tag', objectId: id, field: field, value: value);

void main() {
  test('角色仅接受合法内置组合，canonical身份不可随元数据漂移', () {
    expect(builtinTypeRole('legacy', kind: 'type', builtin: 1, sort: 80), 8);
    expect(builtinTypeRole('legacy', kind: 'project', builtin: 1, sort: 80), isNull);
    expect(builtinTypeRole('legacy', kind: 'type', builtin: 0, sort: 80), isNull);
    for (final sort in [-10, 1, 90]) {
      expect(builtinTypeRole('legacy', kind: 'type', builtin: 1, sort: sort), isNull);
    }
    expect(builtinTypeRole('legacy', kind: 'type', builtin: 1), isNull);
    expect(builtinTypeRole('builtin-type:8', kind: 'project', builtin: 0, sort: 0), 8);
    expect(builtinTypeRole('builtin-type:08'), isNull);
    expect(builtinTypeRole('builtin-type:9'), isNull);
  });
  test('两端随机ID内置标签按固定角色归并，保留全部别名', () {
    final ops = <Operation>[];
    for (var i = 0; i < builtinTypeTags.length; i++) {
      for (final prefix in ['phone', 'desktop']) {
        ops.addAll(tag('$prefix-$i', name: builtinTypeTags[i],
            kind: 'type', builtin: 1, sort: i * 10));
      }
    }
    final result = const TagMerge().merge(ops.reversed);
    expect(result.tags, hasLength(9));
    for (var i = 0; i < 9; i++) {
      final id = 'builtin-type:$i';
      expect(result.aliases['phone-$i'], id);
      expect(result.aliases['desktop-$i'], id);
      expect(result.tags[id]!['name'], builtinTypeTags[i]);
      expect(result.tags[id]!['kind'], 'type');
      expect(result.tags[id]!['builtin'], 1);
      expect(result.tags[id]!['sort'], i * 10);
    }
  });
  test('旧ID角色元数据未齐先等待，补齐才归组', () {
    final ops = tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80);
    final partial = ops.where((op) => op.field != 'sort').toList();
    expect(const TagMerge().merge(partial).tags, isEmpty);
    final result = const TagMerge().merge([...partial, delta('legacy', 'sort', 80, 2)]);
    expect(result.aliases['legacy'], 'builtin-type:8');
    expect(result.tags['builtin-type:8']!['name'], '想法');
  });
  test('canonical仅name增量定位既有角色，身份元数据不漂移', () {
    final result = const TagMerge().merge([
      ...tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80),
      delta('builtin-type:8', 'name', '灵感', 2),
      delta('builtin-type:8', 'kind', 'project', 3),
      delta('builtin-type:8', 'builtin', 0, 4),
      delta('builtin-type:8', 'sort', 0, 5),
    ]);
    expect(result.tags, hasLength(1));
    expect(result.tags['builtin-type:8'], {
      'name': '灵感', 'kind': 'type', 'builtin': 1, 'color': null, 'sort': 80});
  });
  test('先跨别名合并删除/恢复，旧alias恢复不绕过较新墓碑', () {
    final ops = [...tag('a', kind: 'type', builtin: 1),
      ...tag('b', kind: 'type', builtin: 1),
      delta('a', Operation.restoreField, true, 2),
      delta('b', Operation.tombstoneField, true, 3),
      delta('a', 'name', '墓碑后编辑', 4)];
    final hidden = const TagMerge().merge(ops.reversed);
    expect(hidden.tags, isEmpty);
    expect(hidden.aliases['a'], 'builtin-type:0');
    expect(hidden.aliases['b'], 'builtin-type:0');
    final visible = const TagMerge().merge([
      delta('builtin-type:0', Operation.restoreField, true, 5), ...ops]);
    expect(visible.tags['builtin-type:0']!['name'], '墓碑后编辑');
  });
  test('普通同名保留每个ID，预留用户原名后确定性消歧，正反序一致', () {
    final ops = [...tag('b'), ...tag('a'), ...tag('c', name: '同名 (b)'),
      ...tag('d', name: '同名 (b) [2]'), ...tag('custom', kind: 'custom')];
    final result = const TagMerge().merge(ops);
    expect(result.tags, hasLength(5));
    expect(result.tags['a']!['name'], '同名');
    expect(result.tags['b']!['name'], '同名 (b) [3]');
    expect(result.tags['b']!['logical_name'], '同名');
    expect(result.tags['c']!['name'], '同名 (b)');
    expect(result.tags['d']!['name'], '同名 (b) [2]');
    expect(result.tags['custom']!['name'], '同名');
    expect(result.aliases, {'a': 'a', 'b': 'b', 'c': 'c', 'd': 'd', 'custom': 'custom'});
    expect(const TagMerge().merge(ops.reversed).tags, result.tags);
  });
  test('内置角色保留基础显示名，普通type同名仍保留其ID与逻辑名', () {
    final result = const TagMerge().merge([
      ...tag('a', name: '想法', kind: 'type'),
      ...tag('legacy', name: '想法', kind: 'type', builtin: 1, sort: 80)]);
    expect(result.tags.keys, unorderedEquals(['a', 'builtin-type:8']));
    expect(result.tags['builtin-type:8']!['name'], '想法');
    expect(result.tags['a']!['name'], '想法 (a)');
    expect(result.tags['a']!['logical_name'], '想法');
  });
  test('派生名不改原操作，后续改名解开冲突时不残留旧逻辑名', () {
    final ops = [...tag('a'), ...tag('b')];
    final original = jsonEncode(ops.map((op) => op.toJson()).toList());
    final conflicted = const TagMerge().merge(ops);
    expect(conflicted.tags['b']!['name'], '同名 (b)');
    expect(jsonEncode(ops.map((op) => op.toJson()).toList()), original);
    final renamed = const TagMerge().merge([...ops, delta('a', 'name', '另一个名字', 2)]);
    expect(renamed.tags['b']!['name'], '同名');
    expect(renamed.tags['b']!.containsKey('logical_name'), isFalse);
    expect(Operation.syncFields['tag'], isNot(contains('logical_name')));
  });
  test('普通同名删除只影响对应ID，不删除另一对象或遗失别名', () {
    final result = const TagMerge().merge([...tag('a'), ...tag('b'),
      delta('a', Operation.tombstoneField, true, 2)]);
    expect(result.tags.keys, ['b']); expect(result.tags['b']!['name'], '同名');
    expect(result.aliases, {'a': 'a', 'b': 'b'});
  });
  test('只有完整创建事实的墓碑才进入删除集合，缺字段继续等待', () {
    final tomb = delta('a', Operation.tombstoneField, true, 2);
    expect(const TagMerge().merge([tomb]).deleted, isEmpty);
    final full = const TagMerge().merge([...tag('a'), tomb]);
    expect(full.tags, isEmpty); expect(full.deleted, {'a'});
    final restored = const TagMerge().merge([...tag('a'), tomb,
      delta('a', Operation.restoreField, true, 3)]);
    expect(restored.deleted, isEmpty); expect(restored.tags.keys, ['a']);
    final alias = const TagMerge().merge([
      ...tag('old', kind: 'type', builtin: 1),
      delta('builtin-type:0', Operation.tombstoneField, true, 2)]);
    expect(alias.deleted, {'builtin-type:0'});
    expect(alias.aliases['old'], 'builtin-type:0');
  });
}
