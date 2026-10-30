import '../db/database.dart';
import '../model/enums.dart';
import '../model/item.dart';
import '../search/search_service.dart';
import '../sync/sync_outbox.dart';
import '../sync/operation.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import 'json_codec.dart';
import 'mappers.dart';

/// 事项仓储，含标签关联的读写。
class ItemRepository {
  ItemRepository(this._db, {Clock clock = const SystemClock()}) : _clock = clock;

  final SeqDatabase _db;
  final Clock _clock;

  void _refreshIndex(String id) {
    final item = byId(id);
    final search = SearchService(_db);
    if (item == null || item.deletedAt != null) {
      search.removeFromIndex('item', id);
    } else {
      search.indexItem(id, item.title);
    }
  }

  Map<String, Object?>? _syncRow(String id) {
    final rows = _db.raw.select('SELECT * FROM items WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.single;
  }

  Item insert(Item item) {
    final id = item.id.isEmpty ? newId() : item.id;
    return SyncOutbox(_db, clock: _clock).capture('item', id,
        read: () => _syncRow(id), write: () {
    _db.raw.execute(
      'INSERT INTO items (id, note_id, line_index, title, status, priority, '
      'source, due_at, completed_at, source_ref_json, created_at, updated_at, '
      'deleted_at, hlc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        item.noteId,
        item.lineIndex,
        item.title,
        item.status.dbValue,
        item.priority.dbValue,
        item.source.dbValue,
        item.dueAt == null ? null : encodeTime(item.dueAt!),
        item.completedAt == null ? null : encodeTime(item.completedAt!),
        encodeJsonMap(item.sourceRef?.toJson()),
        encodeTime(item.createdAt),
        encodeTime(item.updatedAt),
        item.deletedAt == null ? null : encodeTime(item.deletedAt!),
        item.hlc,
      ],
    );
    _refreshIndex(id);
    return byId(id)!;
    });
  }

  Item? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM items WHERE id = ?', [id]);
    return rows.isEmpty ? null : RowMappers.item(rows.first);
  }

  List<Item> byNote(String noteId) => _db.raw
      .select('SELECT * FROM items WHERE note_id = ? AND deleted_at IS NULL '
          'ORDER BY line_index ASC, created_at ASC', [noteId])
      .map(RowMappers.item)
      .toList();

  /// 全部未完成事项，最近创建的在前。用于"全部事项"列表。
  List<Item> openAll({int limit = 500}) => _db.raw
      .select("SELECT * FROM items WHERE status = 'todo' AND deleted_at IS NULL "
          'AND NOT EXISTS (SELECT 1 FROM notes n '
          'WHERE n.id = items.note_id AND n.deleted_at IS NOT NULL) '
          'ORDER BY created_at DESC LIMIT ?', [limit])
      .map(RowMappers.item)
      .toList();

  /// 调度必须覆盖全部未完成事项；SQLite LIMIT -1 表示不限制数量。
  List<Item> remindable() => _withoutIdeas(openAll(limit: -1));

  List<Item> _withoutIdeas(List<Item> items) {
    final tags = _db.raw.select('SELECT * FROM tags').map(RowMappers.tag)
        .where((tag) => tag.isIdea).map((tag) => tag.id).toList();
    if (tags.isEmpty) return items;
    final placeholders = List.filled(tags.length, '?').join(',');
    final excluded = _db.raw.select(
        'SELECT item_id FROM item_tags WHERE tag_id IN ($placeholders)', tags)
        .map((row) => row['item_id'] as String).toSet();
    return items.where((item) => !excluded.contains(item.id)).toList();
  }

  /// 今日视图：当天到期的未完成事项。
  List<Item> dueOn(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    // 夏令时切换日不一定有 24 小时，结束点取次日的本地零点。
    final end = DateTime(start.year, start.month, start.day + 1);
    return _withoutIdeas(_db.raw
        .select("SELECT * FROM items WHERE status = 'todo' AND deleted_at IS NULL "
            'AND NOT EXISTS (SELECT 1 FROM notes n '
            'WHERE n.id = items.note_id AND n.deleted_at IS NOT NULL) '
            'AND due_at >= ? AND due_at < ? ORDER BY due_at ASC',
            [encodeTime(start), encodeTime(end)])
        .map(RowMappers.item)
        .toList());
  }

  /// 逾期：截止时间已过且仍未完成。
  List<Item> overdue(DateTime now) => _withoutIdeas(_db.raw
      .select("SELECT * FROM items WHERE status = 'todo' AND deleted_at IS NULL "
          'AND NOT EXISTS (SELECT 1 FROM notes n '
          'WHERE n.id = items.note_id AND n.deleted_at IS NOT NULL) '
          'AND due_at IS NOT NULL AND due_at < ? ORDER BY due_at ASC',
          [encodeTime(now)])
      .map(RowMappers.item)
      .toList());

  List<Item> completedOn(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(start.year, start.month, start.day + 1);
    return _withoutIdeas(_db.raw
        .select('SELECT * FROM items WHERE deleted_at IS NULL '
            'AND NOT EXISTS (SELECT 1 FROM notes n '
            'WHERE n.id = items.note_id AND n.deleted_at IS NOT NULL) '
            'AND completed_at >= ? AND completed_at < ? '
            'ORDER BY completed_at DESC', [encodeTime(start), encodeTime(end)])
        .map(RowMappers.item)
        .toList());
  }

  /// 合并编辑期间其他窗口的改动；同一字段冲突时不写入。
  bool saveEdits(Item original, {
    required String title,
    required Priority priority,
    required DateTime? dueAt,
  }) => _db.transaction(() {
    final latest = byId(original.id);
    if (latest == null || latest.deletedAt != null) {
      throw StateError('事项已删除');
    }
    final titleChanged = title != original.title;
    final priorityChanged = priority != original.priority;
    final dueChanged = dueAt?.toUtc() != original.dueAt?.toUtc();
    if ((titleChanged && latest.title != original.title && latest.title != title) ||
        (priorityChanged && latest.priority != original.priority &&
            latest.priority != priority) ||
        (dueChanged && latest.dueAt?.toUtc() != original.dueAt?.toUtc() &&
            latest.dueAt?.toUtc() != dueAt?.toUtc())) {
      return false;
    }
    update(latest.copyWith(
      title: titleChanged ? title : latest.title,
      priority: priorityChanged ? priority : latest.priority,
      dueAt: dueChanged ? dueAt : latest.dueAt,
      clearDueAt: dueChanged && dueAt == null,
    ));
    return true;
  });

  void update(Item item) => SyncOutbox(_db, clock: _clock).capture('item', item.id,
      read: () => _syncRow(item.id), write: () {
    _db.raw.execute(
      'UPDATE items SET note_id=?, line_index=?, title=?, status=?, priority=?, '
      'source=?, due_at=?, completed_at=?, source_ref_json=?, updated_at=?, '
      'deleted_at=?, hlc=? WHERE id=?',
      [
        item.noteId,
        item.lineIndex,
        item.title,
        item.status.dbValue,
        item.priority.dbValue,
        item.source.dbValue,
        item.dueAt == null ? null : encodeTime(item.dueAt!),
        item.completedAt == null ? null : encodeTime(item.completedAt!),
        encodeJsonMap(item.sourceRef?.toJson()),
        encodeTime(_clock.now()),
        item.deletedAt == null ? null : encodeTime(item.deletedAt!),
        item.hlc,
        item.id,
      ],
    );
    _refreshIndex(item.id);
  });

  // ---- 标签关联 ----

  /// 回收站清理调用：先显式捕获关联，再删除事项，保留操作历史。
  void purge(String id) => SyncOutbox(_db, clock: _clock).capture('item', id,
      read: () => _syncRow(id), write: () {
    setTags(id, const []);
    _db.raw.execute("DELETE FROM search_index WHERE object_type = 'item' AND object_id = ?", [id]);
    _db.raw.execute('DELETE FROM items WHERE id = ?', [id]);
  });

  List<String> tagIdsOf(String itemId) => _db.raw
      .select('SELECT tag_id FROM item_tags WHERE item_id = ?', [itemId])
      .map((r) => r['tag_id'] as String)
      .toList();

  void addTag(String itemId, String tagId) => _changeTag(itemId, tagId, true);

  void _changeTag(String itemId, String tagId, bool present) {
    Map<String, Object?>? read() {
      final rows = _db.raw.select(
          'SELECT item_id,tag_id FROM item_tags WHERE item_id = ? AND tag_id = ?',
          [itemId, tagId]);
      return rows.isEmpty ? null : {...rows.single, 'present': true};
    }
    SyncOutbox(_db, clock: _clock).capture('item_tag', Operation.itemTagId(itemId, tagId),
        read: read, write: () {
      if (present) {
        _db.raw.execute('INSERT OR IGNORE INTO item_tags(item_id,tag_id) VALUES (?,?)',
            [itemId, tagId]);
      } else {
        _db.raw.execute('DELETE FROM item_tags WHERE item_id = ? AND tag_id = ?',
            [itemId, tagId]);
      }
    });
  }

  void setTags(String itemId, List<String> tagIds) {
    _db.transaction(() {
      final before = tagIdsOf(itemId).toSet();
      final after = tagIds.toSet();
      for (final tagId in before.difference(after)) {
        _changeTag(itemId, tagId, false);
      }
      for (final tagId in after.difference(before)) {
        _changeTag(itemId, tagId, true);
      }
    });
  }

  List<Item> byTag(String tagId) => _db.raw
      .select('SELECT i.* FROM items i JOIN item_tags t ON t.item_id = i.id '
          'WHERE t.tag_id = ? AND i.deleted_at IS NULL '
          'AND NOT EXISTS (SELECT 1 FROM notes n '
          'WHERE n.id = i.note_id AND n.deleted_at IS NOT NULL) '
          'ORDER BY i.created_at DESC', [tagId])
      .map(RowMappers.item)
      .toList();
}
