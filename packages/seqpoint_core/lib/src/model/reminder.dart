import 'enums.dart';

/// 提醒。
///
/// [isStrong] 为 true 表示用户亲手设定的精确提醒，属强约束：
/// 智能策略不得延迟它，也不计入智能提醒的每日上限。
class Reminder {
  const Reminder({
    required this.id,
    required this.itemId,
    required this.mode,
    this.triggerAt,
    this.offsetMinutes,
    this.isStrong = false,
    this.snoozeCount = 0,
    this.lastFiredAt,
    this.feedback,
    this.enabled = true,
    this.hlc,
  });

  final String id;
  final String itemId;
  final ReminderMode mode;

  /// 绝对触发时刻（exact / smart / overdue / digest 使用）。
  final DateTime? triggerAt;

  /// 相对截止时间的偏移，负数表示提前（relative 使用）。
  final int? offsetMinutes;

  final bool isStrong;
  final int snoozeCount;
  final DateTime? lastFiredAt;
  final ReminderFeedback? feedback;
  final bool enabled;
  final String? hlc;

  /// 计算实际触发时刻。relative 模式需要事项的截止时间。
  DateTime? resolveTriggerAt({DateTime? itemDueAt}) {
    if (mode == ReminderMode.relative) {
      if (itemDueAt == null || offsetMinutes == null) return null;
      return itemDueAt.add(Duration(minutes: offsetMinutes!));
    }
    return triggerAt;
  }

  Reminder copyWith({
    ReminderMode? mode,
    DateTime? triggerAt,
    int? offsetMinutes,
    bool? isStrong,
    int? snoozeCount,
    DateTime? lastFiredAt,
    ReminderFeedback? feedback,
    bool? enabled,
    String? hlc,
  }) =>
      Reminder(
        id: id,
        itemId: itemId,
        mode: mode ?? this.mode,
        triggerAt: triggerAt ?? this.triggerAt,
        offsetMinutes: offsetMinutes ?? this.offsetMinutes,
        isStrong: isStrong ?? this.isStrong,
        snoozeCount: snoozeCount ?? this.snoozeCount,
        lastFiredAt: lastFiredAt ?? this.lastFiredAt,
        feedback: feedback ?? this.feedback,
        enabled: enabled ?? this.enabled,
        hlc: hlc ?? this.hlc,
      );
}
