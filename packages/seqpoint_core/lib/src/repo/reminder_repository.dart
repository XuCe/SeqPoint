import '../db/database.dart';
import '../model/enums.dart';
import '../model/reminder.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import 'mappers.dart';

/// 提醒仓储。
class ReminderRepository {
  ReminderRepository(this._db);

  final SeqDatabase _db;

  Reminder insert(Reminder r) {
    final id = r.id.isEmpty ? newId() : r.id;
    _db.raw.execute(
      'INSERT INTO reminders (id, item_id, mode, trigger_at, offset_minutes, '
      'is_strong, snooze_count, last_fired_at, feedback, enabled, hlc) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        r.itemId,
        r.mode.dbValue,
        r.triggerAt == null ? null : encodeTime(r.triggerAt!),
        r.offsetMinutes,
        r.isStrong ? 1 : 0,
        r.snoozeCount,
        r.lastFiredAt == null ? null : encodeTime(r.lastFiredAt!),
        r.feedback?.dbValue,
        r.enabled ? 1 : 0,
        r.hlc,
      ],
    );
    return byId(id)!;
  }

  Reminder? byId(String id) {
    final rows = _db.raw.select('SELECT * FROM reminders WHERE id = ?', [id]);
    return rows.isEmpty ? null : RowMappers.reminder(rows.first);
  }

  List<Reminder> forItem(String itemId) => _db.raw
      .select('SELECT * FROM reminders WHERE item_id = ?', [itemId])
      .map(RowMappers.reminder)
      .toList();

  /// 待触发：启用中且触发时刻在 [until] 之前。
  List<Reminder> pending(DateTime until) => _db.raw
      .select('SELECT * FROM reminders WHERE enabled = 1 AND trigger_at IS NOT NULL '
          'AND trigger_at <= ? ORDER BY trigger_at ASC', [encodeTime(until)])
      .map(RowMappers.reminder)
      .toList();

  /// 某事项今日已触发的智能提醒次数，用于每日上限判断。
  int smartFiredCountToday(String itemId, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(start.year, start.month, start.day + 1);
    return _db.raw.select(
      "SELECT COUNT(*) AS c FROM reminders WHERE item_id = ? AND mode = 'smart' "
      'AND last_fired_at >= ? AND last_fired_at < ?',
      [itemId, encodeTime(start), encodeTime(end)],
    ).first['c'] as int;
  }

  void update(Reminder r) {
    _db.raw.execute(
      'UPDATE reminders SET mode=?, trigger_at=?, offset_minutes=?, is_strong=?, '
      'snooze_count=?, last_fired_at=?, feedback=?, enabled=?, hlc=? WHERE id=?',
      [
        r.mode.dbValue,
        r.triggerAt == null ? null : encodeTime(r.triggerAt!),
        r.offsetMinutes,
        r.isStrong ? 1 : 0,
        r.snoozeCount,
        r.lastFiredAt == null ? null : encodeTime(r.lastFiredAt!),
        r.feedback?.dbValue,
        r.enabled ? 1 : 0,
        r.hlc,
        r.id,
      ],
    );
  }

  void delete(String id) {
    _db.raw.execute('DELETE FROM reminders WHERE id = ?', [id]);
  }
}
