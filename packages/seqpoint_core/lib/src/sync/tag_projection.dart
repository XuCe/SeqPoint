import '../db/database.dart';
import '../util/ids.dart';
import 'operation.dart';
import 'tag_merge.dart';

/// 仅由SyncProjector在抑制捕获的事务内调用；不以业务行补齐事实。
TagMergeResult projectTags(SeqDatabase db, Iterable<Operation> operations) {
  final view = const TagMerge().merge(operations);
  final existing = db.raw.select('SELECT id,kind,name FROM tags');
  final retired = existing.where((r) => view.deleted.contains(
      view.aliases[r['id']] ?? r['id'])).toList();
  if (retired.any((r) => db.raw.select('SELECT 1 FROM item_tags WHERE tag_id=? LIMIT 1',
      [r['id']]).isNotEmpty)) { return view; }
  final touched = {...view.tags.keys, ...retired.map((r) => r['id'] as String),
    for (final alias in view.aliases.entries)
      if (view.tags.containsKey(alias.value)) alias.key};
  for (final held in existing.where((r) => !touched.contains(r['id']))) {
    if (view.tags.values.any((v) => v['kind'] == held['kind'] && v['name'] == held['name'])) {
      return view; // 未建立基线的名称占用保持原样，等待事实补齐。
    }
  }
  for (final row in retired) { db.raw.execute('DELETE FROM tags WHERE id=?', [row['id']]); }
  final nonce = newId();
  for (final row in existing.where((r) => touched.contains(r['id']))) {
    db.raw.execute('UPDATE tags SET name=? WHERE id=?',
        ['__seqpoint_pending_${nonce}_${row['id']}', row['id']]);
  }
  for (final entry in view.tags.entries) {
    final v = entry.value;
    db.raw.execute('INSERT INTO tags(id,name,kind,builtin,color,sort,logical_name) '
        'VALUES (?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,'
        'kind=excluded.kind,builtin=excluded.builtin,color=excluded.color,'
        'sort=excluded.sort,logical_name=excluded.logical_name',
        [entry.key, v['name'], v['kind'], v['builtin'], v['color'], v['sort'], v['logical_name']]);
  }
  for (final alias in view.aliases.entries) {
    if (alias.key == alias.value || !view.tags.containsKey(alias.value)) continue;
    db.raw.execute('INSERT OR IGNORE INTO item_tags(item_id,tag_id) '
        'SELECT item_id,? FROM item_tags WHERE tag_id=?', [alias.value, alias.key]);
    db.raw.execute('DELETE FROM tags WHERE id=?', [alias.key]);
  }
  return view;
}

int pendingTagCount(SeqDatabase db, TagMergeResult view) {
  final actual = {for (final row in db.raw.select('SELECT * FROM tags')) row['id']: row};
  var pending = 0;
  for (final id in view.aliases.values.toSet()) {
    final desired = view.tags[id];
    if (desired == null) {
      if (!view.deleted.contains(id) || actual.keys.any((old) =>
          (view.aliases[old] ?? old) == id)) { pending++; }
    } else {
      final row = actual[id];
      if (row == null || const ['name', 'kind', 'builtin', 'color', 'sort', 'logical_name']
          .any((field) => row[field] != desired[field])) { pending++; }
    }
  }
  return pending;
}
