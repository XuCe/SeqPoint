import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

const itemKey = (type: 'item', id: 'i1');
Operation op(String dev, int ms, String field, Object? v, {String id = 'i1', String type = 'item'}) =>
    Operation(
      opId: '$dev-$ms-$type-$field-$id',
      deviceId: dev,
      hlc: Hlc(millis: ms, counter: 0, deviceId: dev),
      objectType: type,
      objectId: id,
      field: field,
      value: v,
    );

void main() {
  const merge = FieldMerge();

  test('同对象不同字段并发修改都保留', () {
    final state = merge.materialize([
      op('phone', 100, 'tags', ['运维']),
      op('pc', 101, 'due_at', '2026-09-05'),
    ])[itemKey]!;
    expect(state['tags'], ['运维']);
    expect(state['due_at'], '2026-09-05');
  });

  test('同字段并发：物理时间晚者胜', () {
    final early = op('dev-a', 100, 'priority', 'p3');
    final late = op('dev-b', 200, 'priority', 'p1');
    expect(merge.materialize([early, late])[itemKey]!['priority'], 'p1');
    expect(merge.materialize([late, early])[itemKey]!['priority'], 'p1');
  });

  test('同毫秒并发：deviceId 字典序大者胜，且与应用顺序无关', () {
    // 'dev-b' > 'dev-a'，故 dev-b 的写入胜出。规则本身不重要，
    // 重要的是任意两台设备据此得到相同结论。
    final a = op('dev-a', 100, 'priority', 'p3');
    final b = op('dev-b', 100, 'priority', 'p1');
    expect(merge.materialize([a, b])[itemKey]!['priority'], 'p1');
    expect(merge.materialize([b, a])[itemKey]!['priority'], 'p1');
  });

  test('tombstone 晚于所有写入时对象消失', () {
    final write = op('phone', 100, 'title', 'x');
    final tomb = op('pc', 200, Operation.tombstoneField, null);
    expect(merge.materialize([write, tomb]).containsKey(itemKey), isFalse);
  });

  test('OpLog 幂等且只返回对端缺的操作', () {
    final log = OpLog();
    final first = op('phone', 1, 'title', 'a');
    expect(log.append(first), isTrue);
    expect(log.append(first), isFalse, reason: '同 opId 只记一次');
    log.append(op('phone', 2, 'title', 'b'));
    log.append(op('pc', 1, 'title', 'c'));
    expect(log.summary, {'phone': 2, 'pc': 1});
    expect(log.since({'phone': 1}).length, 2);
  });
  test('跨类型同ID分别物化，不互相当作冲突', () {
    final note = op('pc', 100, 'title', '便签', type: 'note');
    final item = op('phone', 200, 'title', '事项');
    final state = merge.materialize([note, item]);
    expect(state, hasLength(2));
    expect(state[(type: 'note', id: 'i1')]!['title'], '便签');
    expect(state[itemKey]!['title'], '事项');
    expect(merge.losers([note, item]), isEmpty);
  });
  test('删除后普通字段更晚也不复活，陈旧恢复无效', () {
    final ops = [op('pc', 100, 'title', '原文'),
      op('pc', 150, Operation.restoreField, true),
      op('pc', 200, Operation.tombstoneField, true),
      op('phone', 300, 'title', '较晚编辑')];
    expect(merge.materialize(ops).containsKey(itemKey), isFalse);
    expect(merge.materialize(ops.reversed).containsKey(itemKey), isFalse);
  });
  test('明确新恢复才重新显示，标记不混入业务字段或冲突', () {
    final ops = [op('pc', 100, 'title', '原文'),
      op('pc', 200, Operation.tombstoneField, true),
      op('phone', 300, 'title', '保留编辑'),
      op('pc', 400, Operation.restoreField, true)];
    expect(merge.materialize(ops)[itemKey], {'title': '保留编辑'});
    expect(merge.materialize(ops.reversed)[itemKey], {'title': '保留编辑'});
    expect(merge.losers(ops).map((op) => op.field), ['title']);
  });
}
