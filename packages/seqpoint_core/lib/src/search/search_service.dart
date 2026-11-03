import '../db/database.dart';

/// 一条搜索命中。
class SearchHit {
  const SearchHit({
    required this.objectType,
    required this.objectId,
    required this.text,
    this.archived = false,
  });

  /// 'note' | 'item'
  final String objectType;
  final String objectId;

  /// 命中的原文。
  final String text;

  /// 来自已归档 / 已完成的对象。
  final bool archived;

  bool get isNote => objectType == 'note';
}

/// 本地全文搜索。完全离线，覆盖便签原文、事项标题、标签名，含已归档。
///
/// 中文没有空格分词，标准 FTS5 分词器会把整句当一个 token，
/// 搜"报价"匹配不到"回复张三报价"。这里用 trigram 分词（三字符滑窗），
/// 代价是索引更大、查询词至少要 3 个字符——不足 3 字符时回落到 LIKE。
class SearchService {
  SearchService(this._db);

  final SeqDatabase _db;

  /// trigram 分词器要求查询词至少这么长。
  static const minTrigramLength = 3;

  Future<List<SearchHit>> query(String q, {bool includeArchived = true}) async {
    final trimmed = q.trim();
    if (trimmed.isEmpty) return const [];
    return trimmed.characters().length >= minTrigramLength
        ? _byFts(trimmed, includeArchived)
        : _byLike(trimmed, includeArchived);
  }

  List<SearchHit> _byFts(String q, bool includeArchived) {
    // FTS5 里双引号包裹的是短语，内部的双引号需转义为两个。
    final phrase = '"${q.replaceAll('"', '""')}"';
    return _db.raw.select("""
      SELECT s.object_type, s.object_id, s.text,
             CASE WHEN n.id IS NOT NULL THEN n.status = 'closed' ELSE i.status != 'todo' END AS archived
      FROM search_index s
      LEFT JOIN notes n ON s.object_type = 'note' AND n.id = s.object_id
      LEFT JOIN items i ON s.object_type = 'item' AND i.id = s.object_id
      LEFT JOIN notes parent ON parent.id = i.note_id
      WHERE search_index MATCH ? AND (
        (n.id IS NOT NULL AND n.deleted_at IS NULL AND (? OR n.status != 'closed'))
        OR (i.id IS NOT NULL AND i.deleted_at IS NULL AND parent.deleted_at IS NULL
            AND (? OR i.status = 'todo'))
      ) ORDER BY s.rank
    """, [phrase, includeArchived, includeArchived]).map(_hit).toList();
  }

  /// 一两个字的查询：trigram 索引用不上，扫原表。数据量小，可以接受。
  List<SearchHit> _byLike(String q, bool includeArchived) {
    final pattern = '%${q.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    return _db.raw.select("""
      SELECT 'note' AS object_type, id AS object_id, raw_content AS text,
             status = 'closed' AS archived
      FROM notes WHERE deleted_at IS NULL AND raw_content LIKE ? ESCAPE '\\'
        AND (? OR status != 'closed')
      UNION ALL
      SELECT 'item', i.id, i.title, i.status != 'todo'
      FROM items i LEFT JOIN notes n ON n.id = i.note_id
      WHERE i.deleted_at IS NULL AND n.deleted_at IS NULL AND i.title LIKE ? ESCAPE '\\'
        AND (? OR i.status = 'todo')
    """, [pattern, includeArchived, pattern, includeArchived]).map(_hit).toList();
  }

  SearchHit _hit(Map<String, Object?> row) => SearchHit(
    objectType: row['object_type'] as String,
    objectId: row['object_id'] as String,
    text: row['text'] as String,
    archived: row['archived'] == 1,
  );

  // ---- 索引维护 ----

  void indexNote(String noteId, String text) =>
      _reindex('note', noteId, text);

  void indexItem(String itemId, String text) => _reindex('item', itemId, text);

  void _reindex(String type, String id, String text) {
    _db.transaction(() {
      removeFromIndex(type, id);
      if (text.trim().isEmpty) return;
      _db.raw.execute(
        'INSERT INTO search_index (object_type, object_id, text) VALUES (?,?,?)',
        [type, id, text],
      );
    });
  }

  void removeFromIndex(String objectType, String objectId) {
    _db.raw.execute(
      'DELETE FROM search_index WHERE object_type = ? AND object_id = ?',
      [objectType, objectId],
    );
  }

  /// 从现有数据重建全部索引。迁移或索引损坏后调用。
  int rebuild() {
    return _db.transaction(() {
      _db.raw.execute('DELETE FROM search_index');
      var count = 0;
      final notes = _db.raw.select(
          'SELECT id, raw_content, title FROM notes WHERE deleted_at IS NULL');
      for (final r in notes) {
        final title = r['title'] as String?;
        final body = r['raw_content'] as String? ?? '';
        final text = title == null || title.isEmpty ? body : '$title\n$body';
        if (text.trim().isEmpty) continue;
        _db.raw.execute(
          'INSERT INTO search_index (object_type, object_id, text) VALUES (?,?,?)',
          ['note', r['id'], text],
        );
        count++;
      }
      final items = _db.raw
          .select('SELECT id, title FROM items WHERE deleted_at IS NULL');
      for (final r in items) {
        final text = r['title'] as String? ?? '';
        if (text.trim().isEmpty) continue;
        _db.raw.execute(
          'INSERT INTO search_index (object_type, object_id, text) VALUES (?,?,?)',
          ['item', r['id'], text],
        );
        count++;
      }
      return count;
    });
  }
}

extension on String {
  /// 按 Unicode 码点计数，避免中文被当成多个字符导致阈值判断出错。
  Iterable<int> characters() => runes;
}
