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
import 'note_line_changes.dart';

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
      title: title == null || title.trim().isEmpty ? null : title.trim(),
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

  /// Save the draft and promote its selected line in a single transaction.
  Note saveWithItem(String text, {String? noteId, required int lineIndex, DateTime? due,
      String? expectedContent, String? title, String? expectedTitle}) =>
      _db.transaction(() {
        final note = noteId == null ? capture(text, title: title) : editContent(noteId, text,
            expectedContent: expectedContent, title: title, expectedTitle: expectedTitle);
        final lines = note.lines;
        RangeError.checkValidIndex(lineIndex, lines);
        if (Note.lineTitle(lines[lineIndex]).isEmpty) throw StateError('请先输入事项内容');
        final item = Note.itemsByLine(lines, _items.byNote(note.id))[lineIndex] ??
            lineToItem(note.id, lineIndex);
        if (due != null) {
          if (item.status != ItemStatus.todo) throw StateError('只有待办中的事项可以设提醒');
          _items.update(item.copyWith(dueAt: due, updatedAt: _clock.now()));
        }
        return note;
      });

  /// 编辑正文。整理不走这里，避免覆盖用户原话。
  Note editContent(String noteId, String rawText,
      {String? expectedContent, String? title, String? expectedTitle}) => _db.transaction(() {
    final note = _requireNote(noteId);
    final newTitle = title?.trim();
    if (newTitle != null && (note.title ?? '') != (expectedTitle ?? '') && (note.title ?? '') != newTitle) {
      throw StateError('其他窗口已修改标题，请复制草稿后重新打开。');
    }
    if (expectedContent != null && note.rawContent != expectedContent && note.rawContent != rawText) {
      throw StateError('其他窗口已更新这张便签，请复制草稿后重新打开。');
    }
    final content = _relinkItems(note, rawText);
    final updated = note.copyWith(rawContent: content, title: newTitle,
        clearTitle: newTitle == '', updatedAt: _clock.now());
    _notes.update(updated);
    _activities.log(
      objectType: 'note',
      objectId: noteId,
      action: ActivityAction.noteEdited,
    );
    return updated;
  });

  static final _checkbox = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\]\s+)');

  String _relinkItems(Note note, String rawText) {
    if (note.rawContent == rawText) return rawText;
    final items = _items.byNote(note.id).where((i) => i.lineIndex != null).toList();
    if (items.isEmpty) return rawText;
    final before = note.lines;
    final after = rawText.split('\n');
    final bound = Note.itemsByLine(before, items);
    final moved = movedNoteLines(before, after);
    for (final item in items) {
      final old = item.lineIndex!;
      final index = bound[old]?.id == item.id ? moved[old] : null;
      if (index == null) {
        _items.update(item.copyWith(clearLineIndex: true, updatedAt: _clock.now()));
        continue;
      }
      final oldBox = _checkbox.firstMatch(before[old]);
      final box = _checkbox.firstMatch(after[index]);
      var status = item.status;
      if (box != null && oldBox != null && oldBox[2]!.toLowerCase() != box[2]!.toLowerCase()) {
        status = box[2] == ' ' ? ItemStatus.todo : ItemStatus.done;
      } else if (box != null) {
        after[index] = after[index].replaceRange(box[1]!.length, box[1]!.length + 1,
            status == ItemStatus.done ? 'x' : ' ');
      }
      final title = after[index].trim() == item.title ? item.title : Note.lineTitle(after[index]);
      if (index != old || title != item.title || status != item.status) {
        _items.update(item.copyWith(lineIndex: index, title: title, status: status,
            completedAt: status != item.status && status == ItemStatus.done ? _clock.now() : null,
            clearCompletedAt: status != item.status && status != ItemStatus.done, updatedAt: _clock.now()));
        if (status != item.status) _logStatusChange(item, status);
      }
    }
    return after.join('\n');
  }

  /// 把便签的某一行升级为事项。AI 关闭时的手动路径。
  Item lineToItem(String noteId, int lineIndex, {ItemSource source = ItemSource.manual}) => _db.transaction(() {
    final note = _requireNote(noteId);
    final lines = note.lines;
    if (lineIndex < 0 || lineIndex >= lines.length) {
      throw RangeError.index(lineIndex, lines, 'lineIndex');
    }
    final checked = _checkbox.firstMatch(lines[lineIndex])?[2]?.toLowerCase() == 'x';
    final now = _clock.now();
    final item = _items.insert(Item(
      id: newId(),
      noteId: noteId,
      lineIndex: lineIndex,
      title: Note.lineTitle(lines[lineIndex]),
      dueAt: const TimeParser().parse(lines[lineIndex], now.toLocal())?.dateTime,
      status: checked ? ItemStatus.done : ItemStatus.todo,
      completedAt: checked ? now : null,
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
    var updated = item.copyWith(
      status: done ? ItemStatus.done : ItemStatus.todo,
      completedAt: done ? now : null,
      clearCompletedAt: !done,
      updatedAt: now,
    );
    final note = item.noteId == null ? null : _notes.byId(item.noteId!);
    final index = item.lineIndex;
    if (note != null && index != null) {
      final lines = note.lines;
      if (Note.itemsByLine(lines, _items.byNote(note.id))[index]?.id == item.id) {
        final box = _checkbox.firstMatch(lines[index]);
        if (box != null) {
          updated = updated.copyWith(title: Note.lineTitle(lines[index]));
          final offset = box[1]!.length;
          lines[index] = lines[index].replaceRange(offset, offset + 1, done ? 'x' : ' ');
          _notes.update(note.copyWith(rawContent: lines.join('\n'), updatedAt: now));
        }
      }
    }
    _items.update(updated);
    _logStatusChange(item, updated.status);
    return updated;
  });

  void _logStatusChange(Item item, ItemStatus status) {
    _activities.log(
      objectType: 'item',
      objectId: item.id,
      action: ActivityAction.itemStatusChanged,
      oldValue: item.status.dbValue,
      newValue: status.dbValue,
    );
  }

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
