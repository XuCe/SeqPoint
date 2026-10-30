import 'dart:convert';
import '../db/database.dart';
import '../model/enums.dart';
import '../model/tag.dart';
import '../sync/sync_outbox.dart';
import '../sync/operation.dart';
import '../sync/tag_merge.dart';
import '../util/ids.dart';
import 'item_repository.dart';
import 'mappers.dart';

/// 标签仓储。两维标签的建、改、并、删。
class TagRepository {
  TagRepository(this._db);

  final SeqDatabase _db;

  Map<String, Object?>? _syncRow(String id) {
    final rows = _db.raw.select('SELECT * FROM tags WHERE id = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    return {...row, 'name': row['logical_name'] ?? row['name']};
  }

  /// 首次启动写入内置任务类型标签。幂等。
  void ensureBuiltins() {
    _db.transaction(() {
      final roles = _builtinRoles();
      if (roles == null) return; // 未知旧ID事实不齐，等待基线而非猜角色。
      for (var i = 0; i < builtinTypeTags.length; i++) {
        if (roles.contains(i)) continue;
        final id = 'builtin-type:$i';
        SyncOutbox(_db).capture('tag', id, read: () => _syncRow(id),
            write: () => _insertBuiltin(id, builtinTypeTags[i], i * 10));
      }
    });
  }

  Set<int>? _builtinRoles() {
    final roles = all().map((t) => builtinTypeRole(t.id, kind: t.kind.dbValue,
        builtin: t.builtin ? 1 : 0, sort: t.sort)).whereType<int>().toSet();
    final facts = <String, Map<String, Object?>>{};
    for (final row in _db.raw.select('''
      SELECT object_id,field,value_json FROM (
        SELECT object_id,field,value_json,ROW_NUMBER() OVER (
          PARTITION BY object_id,field ORDER BY hlc_millis DESC,
          hlc_counter DESC,device_id DESC) AS rank
        FROM sync_operations WHERE object_type='tag'
      ) WHERE rank=1
    ''')) {
      facts.putIfAbsent(row['object_id'] as String, () => {})[row['field'] as String] =
          jsonDecode(row['value_json'] as String);
    }
    for (final entry in facts.entries) {
      final values = entry.value;
      final role = builtinTypeRole(entry.key, kind: values['kind'] as String?,
          builtin: values['builtin'] as int?, sort: values['sort'] as int?);
      if (role != null) { roles.add(role); }
      else if (!Operation.syncFields['tag']!.every(values.containsKey)) { return null; }
    }
    return roles;
  }

  void _insertBuiltin(String id, String name, int sort) {
    final existing = all();
    final rows = <String, Map<String, Object?>>{
      for (final tag in existing) tag.id: {'name': tag.logicalName ?? tag.name,
        'kind': tag.kind.dbValue, 'builtin': tag.builtin ? 1 : 0, 'sort': tag.sort},
      id: {'name': name, 'kind': 'type', 'builtin': 1, 'sort': sort},
    };
    assignTagDisplayNames(rows);
    final changed = existing.where((tag) => tag.name != rows[tag.id]!['name'] ||
        tag.logicalName != rows[tag.id]!['logical_name']).toList();
    _db.withoutSyncCapture(() {
      final nonce = newId();
      for (final tag in changed) {
        _db.raw.execute('UPDATE tags SET name=? WHERE id=?',
            ['__seqpoint_pending_${nonce}_${tag.id}', tag.id]);
      }
      for (final tag in changed) {
        _db.raw.execute('UPDATE tags SET name=?,logical_name=? WHERE id=?',
            [rows[tag.id]!['name'], rows[tag.id]!['logical_name'], tag.id]);
      }
      _db.raw.execute('INSERT INTO tags(id,name,kind,builtin,sort,logical_name) '
          "VALUES (?,?,'type',1,?,?)", [id, rows[id]!['name'], sort, rows[id]!['logical_name']]);
    });
  }

  Tag upsert({required String name, required TagKind kind, String? color}) {
    final existing = byName(name, kind);
    if (existing != null) return existing;
    final id = newId();
    return SyncOutbox(_db).capture('tag', id, read: () => _syncRow(id), write: () {
    _db.raw.execute(
      'INSERT INTO tags (id, name, kind, builtin, color, sort) VALUES (?,?,?,0,?,999)',
      [id, name, kind.dbValue, color],
    );
    return byId(id)!;
    });
  }

  Tag? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM tags WHERE id = ?', [id]);
    return rows.isEmpty ? null : RowMappers.tag(rows.first);
  }

  Tag? byName(String name, TagKind kind) {
    final rows = _db.raw.select(
      'SELECT * FROM tags WHERE name = ? AND kind = ?',
      [name, kind.dbValue],
    );
    return rows.isEmpty ? null : RowMappers.tag(rows.first);
  }

  List<Tag> all({TagKind? kind}) {
    final rows = kind == null
        ? _db.raw.select('SELECT * FROM tags ORDER BY kind, sort, name')
        : _db.raw.select(
            'SELECT * FROM tags WHERE kind = ? ORDER BY sort, name',
            [kind.dbValue],
          );
    return rows.map(RowMappers.tag).toList();
  }

  void rename(String id, String newName) => SyncOutbox(_db).capture('tag', id,
      read: () => _syncRow(id), write: () =>
          _db.raw.execute('UPDATE tags SET name=?,logical_name=NULL '
              'WHERE id=? AND name<>?', [newName, id, newName]));

  /// 合并标签：把 [fromId] 的关联迁到 [intoId]，然后删除 [fromId]。
  void merge({required String fromId, required String intoId}) {
    if (fromId == intoId) return;
    SyncOutbox(_db).capture('tag', fromId, read: () => _syncRow(fromId), write: () {
      if (byId(fromId) == null) return;
      if (byId(intoId) == null) throw StateError('合并目标标签不存在');
      final items = ItemRepository(_db);
      final links = _db.raw.select('SELECT item_id FROM item_tags WHERE tag_id = ?', [fromId]);
      for (final link in links) {
        final itemId = link['item_id'] as String;
        items.setTags(itemId, [
          ...items.tagIdsOf(itemId).where((tagId) => tagId != fromId), intoId]);
      }
      _db.raw.execute('DELETE FROM tags WHERE id = ? AND builtin = 0', [
        fromId,
      ]);
    });
  }

  /// 删除非内置标签。内置标签只能重命名。
  void delete(String id) => SyncOutbox(_db).capture('tag', id,
      read: () => _syncRow(id), write: () {
    final tag = byId(id);
    if (tag == null || tag.builtin) return;
    final items = ItemRepository(_db);
    final links = _db.raw.select('SELECT item_id FROM item_tags WHERE tag_id = ?', [id]);
    for (final link in links) {
      final itemId = link['item_id'] as String;
      items.setTags(itemId, items.tagIdsOf(itemId).where((tagId) => tagId != id).toList());
    }
    _db.raw.execute('DELETE FROM tags WHERE id = ? AND builtin = 0', [id]);
  });

  /// 某标签下的事项数，用于标签管理页显示。
  int usageCount(String tagId) =>
      _db.raw.select(
            'SELECT COUNT(*) AS c FROM item_tags t JOIN items i ON i.id = t.item_id '
            'WHERE t.tag_id = ? AND i.deleted_at IS NULL '
            'AND NOT EXISTS (SELECT 1 FROM notes n '
            'WHERE n.id = i.note_id AND n.deleted_at IS NOT NULL)',
            [tagId],
          ).first['c']
          as int;
}
