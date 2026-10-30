import '../db/database.dart';
import '../model/enums.dart';
import '../model/note.dart';
import '../search/search_service.dart';
import '../sync/sync_outbox.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import 'json_codec.dart';
import 'item_repository.dart';
import 'mappers.dart';

/// 便签仓储。只做存取，业务规则在 NoteService。
class NoteRepository {
  NoteRepository(this._db, {Clock clock = const SystemClock()})
      : _clock = clock;

  final SeqDatabase _db;
  final Clock _clock;

  void _refreshIndex(String id) {
    final note = byId(id);
    final search = SearchService(_db);
    if (note == null || note.isDeleted) {
      search.removeFromIndex('note', id);
    } else {
      final title = note.title;
      search.indexNote(id, title == null || title.isEmpty
        ? note.rawContent : '$title\n${note.rawContent}');
    }
  }

  Map<String, Object?>? _syncRow(String id) {
    final rows = _db.raw.select('SELECT * FROM notes WHERE id = ?', [id]);
    return rows.isEmpty ? null : rows.single;
  }

  Note insert(Note note) {
    final id = note.id.isEmpty ? newId() : note.id;
    return SyncOutbox(_db, clock: _clock).capture('note', id,
        read: () => _syncRow(id), write: () {
    _db.raw.execute(
      'INSERT INTO notes (id, kind, title, raw_content, status, color, pinned, '
      'window_json, created_at, updated_at, closed_at, deleted_at, hlc) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        note.kind.dbValue,
        note.title,
        note.rawContent,
        note.status.dbValue,
        note.color,
        note.pinned ? 1 : 0,
        encodeJsonMap(note.window?.toJson()),
        encodeTime(note.createdAt),
        encodeTime(note.updatedAt),
        note.closedAt == null ? null : encodeTime(note.closedAt!),
        note.deletedAt == null ? null : encodeTime(note.deletedAt!),
        note.hlc,
      ],
    );
    _refreshIndex(id);
    return byId(id)!;
    });
  }

  Note? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM notes WHERE id = ?', [id]);
    return rows.isEmpty ? null : RowMappers.note(rows.first);
  }

  /// 活跃便签，置顶优先，其次按更新时间倒序。
  List<Note> active() => _db.raw
      .select("SELECT * FROM notes WHERE status = 'active' AND deleted_at IS NULL "
          'ORDER BY pinned DESC, updated_at DESC')
      .map(RowMappers.note)
      .toList();

  List<Note> closed({int limit = 200}) => _db.raw
      .select("SELECT * FROM notes WHERE status = 'closed' AND deleted_at IS NULL "
          'ORDER BY closed_at DESC LIMIT ?', [limit])
      .map(RowMappers.note)
      .toList();

  List<Note> trashed() => _db.raw
      .select('SELECT * FROM notes WHERE deleted_at IS NOT NULL '
          'ORDER BY deleted_at DESC')
      .map(RowMappers.note)
      .toList();

  void update(Note note) => SyncOutbox(_db, clock: _clock).capture('note', note.id,
      read: () => _syncRow(note.id), write: () {
    _db.raw.execute(
      'UPDATE notes SET kind=?, title=?, raw_content=?, status=?, color=?, '
      'pinned=?, window_json=?, updated_at=?, closed_at=?, deleted_at=?, hlc=? '
      'WHERE id=?',
      [
        note.kind.dbValue,
        note.title,
        note.rawContent,
        note.status.dbValue,
        note.color,
        note.pinned ? 1 : 0,
        encodeJsonMap(note.window?.toJson()),
        encodeTime(_clock.now()),
        note.closedAt == null ? null : encodeTime(note.closedAt!),
        note.deletedAt == null ? null : encodeTime(note.deletedAt!),
        note.hlc,
        note.id,
      ],
    );
    _refreshIndex(note.id);
  });

  /// 物理删除。仅回收站到期清理时调用。
  int purge({required Duration olderThan}) => _db.transaction(() {
    final cutoff = _clock.now().subtract(olderThan);
    final ids = _db.raw
        .select('SELECT id FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?',
            [encodeTime(cutoff)])
        .map((r) => r['id'] as String)
        .toList();
    for (final id in ids) {
      SyncOutbox(_db, clock: _clock).capture('note', id,
          read: () => _syncRow(id), write: () {
      final children = _db.raw.select('SELECT id FROM items WHERE note_id = ?', [id]);
      final items = ItemRepository(_db, clock: _clock);
      for (final child in children) {
        items.purge(child['id'] as String);
      }
      _db.raw.execute("DELETE FROM search_index WHERE object_type = 'note' "
          'AND object_id = ?', [id]);
      _db.raw.execute('DELETE FROM notes WHERE id = ?', [id]);
      });
    }
    return ids.length;
  });
}
