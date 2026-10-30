import '../ai/rules/time_parser.dart';
import '../model/activity.dart';
import '../db/database.dart';
import '../model/enums.dart';
import '../model/item.dart';
import '../model/note.dart';
import '../repo/activity_repository.dart';
import '../repo/item_repository.dart';
import '../repo/note_repository.dart';
import '../util/clock.dart';
import '../util/ids.dart';

/// 便签与事项的核心业务规则。产品初衷的五要素在这里成形。
///
/// 关键约束：
/// - 零属性即可保存（先记后整理）；
/// - 原始文字永不因整理而丢失；
/// - 纯文字便签不会被自动关闭；
/// - 所有事项完成时提示关闭，"关闭"是产品的情绪终点。
class NoteService {
  NoteService({
    required SeqDatabase db,
    required NoteRepository notes,
    required ItemRepository items,
    required ActivityRepository activities,
    Clock clock = const SystemClock(),
  })  : _db = db,
        _notes = notes,
        _items = items,
        _activities = activities,
        _clock = clock;

  final SeqDatabase _db;
  final NoteRepository _notes;
  final ItemRepository _items;
  final ActivityRepository _activities;
  final Clock _clock;

  /// 随手记：只要文字就能存。
  Note capture(String rawText, {String? title, String? color}) => _db.transaction(() {
    final now = _clock.now();
    final note = _notes.insert(Note(
      id: newId(),
      kind: NoteKind.text,
      status: NoteStatus.active,
      rawContent: rawText,
      title: title,
      color: color,
      createdAt: now,
      updatedAt: now,
    ));
    _activities.log(
      objectType: 'note',
      objectId: note.id,
      action: ActivityAction.noteCreated,
    );
    return note;
  });

  /// 编辑正文。整理不走这里，避免覆盖用户原话。
  Note editContent(String noteId, String rawText) => _db.transaction(() {
    final note = _requireNote(noteId);
    final updated = note.copyWith(rawContent: rawText, updatedAt: _clock.now());
    _notes.update(updated);
    _activities.log(
      objectType: 'note',
      objectId: noteId,
      action: ActivityAction.noteEdited,
    );
    return updated;
  });

  /// 把便签的某一行升级为事项。AI 关闭时的手动路径。
  Item lineToItem(String noteId, int lineIndex, {ItemSource source = ItemSource.manual}) => _db.transaction(() {
    final note = _requireNote(noteId);
    final lines = note.lines;
    if (lineIndex < 0 || lineIndex >= lines.length) {
      throw RangeError.index(lineIndex, lines, 'lineIndex');
    }
    final now = _clock.now();
    final item = _items.insert(Item(
      id: newId(),
      noteId: noteId,
      lineIndex: lineIndex,
      title: lines[lineIndex].trim(),
      dueAt: const TimeParser().parse(lines[lineIndex], now.toLocal())?.dateTime,
      status: ItemStatus.todo,
      priority: Priority.p4,
      source: source,
      createdAt: now,
      updatedAt: now,
    ));
    _activities.log(
      objectType: 'item',
      objectId: item.id,
      action: ActivityAction.itemCreated,
      newValue: item.title,
    );
    return item;
  });

  /// 勾选 / 取消勾选。
  Item toggleItem(String itemId) => _db.transaction(() {
    final item = _items.byId(itemId);
    if (item == null) throw StateError('事项不存在: $itemId');
    final now = _clock.now();
    final done = item.status != ItemStatus.done;
    final updated = item.copyWith(
      status: done ? ItemStatus.done : ItemStatus.todo,
      completedAt: done ? now : null,
      clearCompletedAt: !done,
      updatedAt: now,
    );
    _items.update(updated);
    _activities.log(
      objectType: 'item',
      objectId: itemId,
      action: ActivityAction.itemStatusChanged,
      oldValue: item.status.dbValue,
      newValue: updated.status.dbValue,
    );
    return updated;
  });

  /// 便签上是否所有事项都已完成。纯文字便签返回 false（不该被自动关闭）。
  bool allItemsDone(String noteId) {
    final items = _items.byNote(noteId);
    if (items.isEmpty) return false;
    return items.every((i) => i.status != ItemStatus.todo);
  }

  /// 关闭（归档）便签。等同于把便签从桌上揭走。
  Note close(String noteId) => _db.transaction(() {
    final note = _requireNote(noteId);
    final now = _clock.now();
    final updated = note.copyWith(
      status: NoteStatus.closed,
      closedAt: now,
      updatedAt: now,
    );
    _notes.update(updated);
    _activities.log(
      objectType: 'note',
      objectId: noteId,
      action: ActivityAction.noteClosed,
    );
    return updated;
  });

  Note reopen(String noteId) => _db.transaction(() {
    final note = _requireNote(noteId);
    final updated = note.copyWith(
      status: NoteStatus.active,
      clearClosedAt: true,
      updatedAt: _clock.now(),
    );
    _notes.update(updated);
    _activities.log(
      objectType: 'note',
      objectId: noteId,
      action: ActivityAction.noteReopened,
    );
    return updated;
  });

  /// 软删除到回收站。
  Note trash(String noteId) => _db.transaction(() {
    final note = _requireNote(noteId);
    final now = _clock.now();
    final updated = note.copyWith(deletedAt: now, updatedAt: now);
    _notes.update(updated);
    _activities.log(
      objectType: 'note',
      objectId: noteId,
      action: ActivityAction.noteTrashed,
    );
    return updated;
  });

  Note restore(String noteId) {
    final note = _requireNote(noteId);
    final updated =
        note.copyWith(clearDeletedAt: true, updatedAt: _clock.now());
    _notes.update(updated);
    return updated;
  }

  /// 回收站到期清理，默认 30 天。
  int purgeTrash({Duration olderThan = const Duration(days: 30)}) =>
      _notes.purge(olderThan: olderThan);

  Note _requireNote(String id) {
    final note = _notes.byId(id);
    if (note == null) throw StateError('便签不存在: $id');
    return note;
  }
}
