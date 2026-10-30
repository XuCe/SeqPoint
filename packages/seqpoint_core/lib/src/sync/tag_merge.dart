import '../model/tag.dart';
import 'field_merge.dart';
import 'operation.dart';

typedef TagMergeResult = ({Map<String, String> aliases,
    Map<String, Map<String, Object?>> tags, Set<String> deleted});

/// 仅派生视图，不修改已签名事实；角色归组必须早于生命周期合并。
class TagMerge {
  const TagMerge();

  TagMergeResult merge(Iterable<Operation> operations) {
    final ops = operations.where((op) => op.objectType == 'tag').toList();
    final raw = <String, Map<String, Operation>>{};
    for (final op in ops) {
      final fields = raw.putIfAbsent(op.objectId, () => {});
      final prior = fields[op.field];
      if (prior == null || op.hlc > prior.hlc) fields[op.field] = op;
    }
    final aliases = <String, String>{};
    for (final entry in raw.entries) {
      final fields = entry.value;
      final role = builtinTypeRole(entry.key, kind: fields['kind']?.value as String?,
          builtin: fields['builtin']?.value as int?, sort: fields['sort']?.value as int?);
      aliases[entry.key] = role == null ? entry.key : 'builtin-type:$role';
    }
    final mapped = ops.map((op) => Operation(
        opId: op.opId, deviceId: op.deviceId, hlc: op.hlc, objectType: 'tag',
        objectId: aliases[op.objectId]!, field: op.field, value: op.value)).toList();
    final visible = const FieldMerge().materialize(mapped);
    final grouped = const FieldMerge().materialize(mapped.where((op) => !op.isTombstone));
    final tags = <String, Map<String, Object?>>{};
    final deleted = <String>{};
    for (final entry in grouped.entries) {
      final values = entry.value;
      final role = builtinTypeRole(entry.key.id);
      if (role != null) {
        values.addAll({'kind': 'type', 'builtin': 1, 'sort': role * 10});
      }
      if (Operation.syncFields['tag']!.every(values.containsKey)) {
        if (visible.containsKey(entry.key)) { tags[entry.key.id] = values; }
        else { deleted.add(entry.key.id); }
      }
    }
    assignTagDisplayNames(tags);
    return (aliases: aliases, tags: tags, deleted: deleted);
  }
}

/// 同步投影与本机内置初始化共用；先预留所有业务原名，再分配显示后缀。
void assignTagDisplayNames(Map<String, Map<String, Object?>> tags) {
    final ordered = tags.entries.toList()..sort((a, b) {
      final aRole = builtinTypeRole(a.key, kind: a.value['kind'] as String?,
          builtin: a.value['builtin'] as int?, sort: a.value['sort'] as int?);
      final bRole = builtinTypeRole(b.key, kind: b.value['kind'] as String?,
          builtin: b.value['builtin'] as int?, sort: b.value['sort'] as int?);
      if ((aRole == null) != (bRole == null)) return aRole == null ? 1 : -1;
      return a.key.compareTo(b.key);
    });
    final used = <(String, String)>{};
    final duplicates = <MapEntry<String, Map<String, Object?>>>[];
    for (final entry in ordered) {
      if (!used.add((entry.value['kind'] as String, entry.value['name'] as String))) {
        duplicates.add(entry);
      }
    }
    for (final entry in duplicates) {
      final values = entry.value;
      final kind = values['kind'] as String, logical = values['name'] as String;
      final base = '$logical (${entry.key})';
      var display = base, suffix = 2;
      while (used.contains((kind, display))) { display = '$base [${suffix++}]'; }
      used.add((kind, display));
      values['logical_name'] = logical;
      values['name'] = display;
    }
}
