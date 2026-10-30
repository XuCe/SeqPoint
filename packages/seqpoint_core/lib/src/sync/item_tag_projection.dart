import '../db/database.dart';
import 'operation.dart';
import 'tag_merge.dart';

/// 关联身份已编码双方ID；仅明确marker决定关系，present不能复活。
/// 调用方持有投影事务；缺身份归组或依赖时保留事实等待重试。
int projectItemTags(SeqDatabase db, Iterable<Operation> operations, TagMergeResult tags) {
  final winners = <({String itemId, String tagId}), Operation>{};
  final candidates = <({String itemId, String tagId})>{};
  final pending = <({String itemId, String tagId})>{};
  for (final op in operations) {
    if (op.objectType != 'item_tag') continue;
    final pair = Operation.itemTagIds(op.objectId);
    final tagId = tags.aliases[pair.tagId] ?? pair.tagId;
    final key = (itemId: pair.itemId, tagId: tagId);
    candidates.add(key);
    if (!tags.tags.containsKey(tagId) && !tags.deleted.contains(tagId)) {
      pending.add(key); continue;
    }
    if (op.field != Operation.restoreField && !op.isTombstone) continue;
    final prior = winners[key];
    if (prior == null || op.hlc > prior.hlc) winners[key] = op;
  }
  for (final entry in winners.entries) {
    final key = entry.key;
    final add = !entry.value.isTombstone && !tags.deleted.contains(key.tagId);
    if (add && (db.raw.select('SELECT 1 FROM items WHERE id=?', [key.itemId]).isEmpty ||
        db.raw.select('SELECT 1 FROM tags WHERE id=?', [key.tagId]).isEmpty)) {
      pending.add(key); continue;
    }
    final aliases = {key.tagId, for (final alias in tags.aliases.entries)
      if (alias.value == key.tagId) alias.key};
    for (final alias in aliases) {
      db.raw.execute('DELETE FROM item_tags WHERE item_id=? AND tag_id=?', [key.itemId, alias]);
    }
    if (add) {
      db.raw.execute('INSERT OR IGNORE INTO item_tags(item_id,tag_id) VALUES (?,?)',
          [key.itemId, key.tagId]);
    }
  }
  pending.addAll(candidates.where((key) => !winners.containsKey(key)));
  return pending.length;
}
