import 'package:sqlite3/sqlite3.dart';

import '../model/activity.dart';
import '../model/enums.dart';
import '../model/item.dart';
import '../model/note.dart';
import '../model/reminder.dart';
import '../model/tag.dart';
import '../util/clock.dart';
import 'json_codec.dart';

/// 数据库行 → 领域对象。集中放这里，避免每个仓储各写一份。
abstract final class RowMappers {
  static Note note(Row r) => Note(
        id: r['id'] as String,
        kind: parseEnum(NoteKind.values, r['kind'] as String?, NoteKind.text),
        status: parseEnum(
            NoteStatus.values, r['status'] as String?, NoteStatus.active),
        rawContent: r['raw_content'] as String? ?? '',
        title: r['title'] as String?,
        color: r['color'] as String?,
        pinned: (r['pinned'] as int? ?? 0) == 1,
        window: NoteWindow.fromJson(decodeJsonMap(r['window_json'] as String?)),
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
        closedAt: decodeTime(r['closed_at'] as String?),
        deletedAt: decodeTime(r['deleted_at'] as String?),
        hlc: r['hlc'] as String?,
      );

  static Item item(Row r) => Item(
        id: r['id'] as String,
        noteId: r['note_id'] as String?,
        lineIndex: r['line_index'] as int?,
        title: r['title'] as String? ?? '',
        status: parseEnum(
            ItemStatus.values, r['status'] as String?, ItemStatus.todo),
        priority:
            parseEnum(Priority.values, r['priority'] as String?, Priority.p4),
        source: parseEnum(
            ItemSource.values, r['source'] as String?, ItemSource.manual),
        dueAt: decodeTime(r['due_at'] as String?),
        completedAt: decodeTime(r['completed_at'] as String?),
        sourceRef:
            SourceRef.fromJson(decodeJsonMap(r['source_ref_json'] as String?)),
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
        deletedAt: decodeTime(r['deleted_at'] as String?),
        hlc: r['hlc'] as String?,
      );

  static Tag tag(Row r) => Tag(
        id: r['id'] as String,
        name: r['name'] as String,
        logicalName: r['logical_name'] as String?,
        kind: parseEnum(TagKind.values, r['kind'] as String?, TagKind.custom),
        builtin: (r['builtin'] as int? ?? 0) == 1,
        color: r['color'] as String?,
        sort: r['sort'] as int? ?? 0,
      );

  static Reminder reminder(Row r) => Reminder(
        id: r['id'] as String,
        itemId: r['item_id'] as String,
        mode: parseEnum(
            ReminderMode.values, r['mode'] as String?, ReminderMode.exact),
        triggerAt: decodeTime(r['trigger_at'] as String?),
        offsetMinutes: r['offset_minutes'] as int?,
        isStrong: (r['is_strong'] as int? ?? 0) == 1,
        snoozeCount: r['snooze_count'] as int? ?? 0,
        lastFiredAt: decodeTime(r['last_fired_at'] as String?),
        feedback: r['feedback'] == null
            ? null
            : parseEnum(ReminderFeedback.values, r['feedback'] as String?,
                ReminderFeedback.ignored),
        enabled: (r['enabled'] as int? ?? 1) == 1,
        hlc: r['hlc'] as String?,
      );

  static Activity activity(Row r) => Activity(
        id: r['id'] as String,
        objectType: r['object_type'] as String,
        objectId: r['object_id'] as String,
        action: r['action'] as String,
        oldValue: r['old_value'] as String?,
        newValue: r['new_value'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}
