import 'operation.dart';

/// 字段级 LWW 合并。
///
/// 规则（对应产品设计的冲突策略）：
/// - 不同对象并行编辑 → 直接合并，不产生冲突；
/// - 同对象不同字段   → 字段级合并，手机改标签、电脑改截止都保留；
/// - 同字段并发修改   → HLC 高者胜，结果与输入顺序无关；
/// - 删除与编辑冲突   → tombstone 携带逻辑时钟，避免"幽灵复活"。
class FieldMerge {
  const FieldMerge();

  /// 把操作流物化为 {(type,id): {field: value}}。
  /// 删除后仅更新的显式restore可恢复，普通字段更新不改变可见性。
  Map<SyncObjectKey, Map<String, Object?>> materialize(Iterable<Operation> ops) {
    final winners = <SyncObjectKey, Map<String, Operation>>{};
    final tombstones = <SyncObjectKey, Operation>{};

    for (final op in ops) {
      if (op.isTombstone) {
        final cur = tombstones[op.objectKey];
        if (cur == null || op.hlc > cur.hlc) tombstones[op.objectKey] = op;
        continue;
      }
      final fields = winners.putIfAbsent(op.objectKey, () => {});
      final cur = fields[op.field];
      if (cur == null || op.hlc > cur.hlc) fields[op.field] = op;
    }

    final result = <SyncObjectKey, Map<String, Object?>>{};
    for (final entry in winners.entries) {
      final tomb = tombstones[entry.key];
      final restore = entry.value[Operation.restoreField];
      if (tomb != null && (restore == null || !(restore.hlc > tomb.hlc))) {
        continue;
      }
      result[entry.key] = {
        for (final f in entry.value.entries)
          if (f.key != Operation.restoreField) f.key: f.value.value
      };
    }
    return result;
  }

  /// 检出被并发覆盖的值，用于写入 Activity 供用户回看。
  List<Operation> losers(Iterable<Operation> ops) {
    final winners = <(String, String, String), Operation>{};
    final all = <(String, String, String), List<Operation>>{};
    for (final op in ops) {
      if (op.isTombstone || op.field == Operation.restoreField) continue;
      final key = (op.objectType, op.objectId, op.field);
      all.putIfAbsent(key, () => []).add(op);
      final cur = winners[key];
      if (cur == null || op.hlc > cur.hlc) winners[key] = op;
    }
    final result = <Operation>[];
    for (final entry in all.entries) {
      final win = winners[entry.key];
      result.addAll(entry.value.where((op) => op.opId != win?.opId));
    }
    return result;
  }
}
