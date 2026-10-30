/// 提醒策略配置。全部可在设置中调整，这里是默认值。
class ReminderPolicy {
  const ReminderPolicy({
    this.workStart = const TimeOfDayValue(9, 0),
    this.workEnd = const TimeOfDayValue(19, 0),
    this.quietStart = const TimeOfDayValue(22, 0),
    this.quietEnd = const TimeOfDayValue(8, 0),
    this.digestAt = const TimeOfDayValue(20, 0),
    this.maxSmartPerItemPerDay = 2,
    this.dedupeWindow = const Duration(minutes: 30),
    this.overdueEscalateAfter = 3,
    this.allowP0Breakthrough = false,
    this.leadTimeBeforeDue = const Duration(minutes: 15),
  });

  final TimeOfDayValue workStart;
  final TimeOfDayValue workEnd;

  /// 勿扰时段，默认 22:00–08:00。
  final TimeOfDayValue quietStart;
  final TimeOfDayValue quietEnd;

  /// 晚间汇总时刻，默认 20:00。
  final TimeOfDayValue digestAt;

  /// 同一事项每日智能提醒上限。用户亲设的强提醒不计入。
  final int maxSmartPerItemPerDay;

  /// 同类提醒去重窗口。
  final Duration dedupeWindow;

  /// 连续延期 / 逾期多少次后，提醒升级为"重新规划"建议卡。
  final int overdueEscalateAfter;

  /// 是否允许 P0 事项穿透勿扰时段。需用户显式开启。
  final bool allowP0Breakthrough;

  /// 有具体时刻的事项，提前多久提醒。
  final Duration leadTimeBeforeDue;

  bool isQuiet(DateTime t) {
    t = t.toLocal();
    final m = t.hour * 60 + t.minute;
    final start = quietStart.minutes;
    final end = quietEnd.minutes;
    return start <= end ? (m >= start && m < end) : (m >= start || m < end);
  }

  bool isWorkTime(DateTime t) {
    t = t.toLocal();
    final m = t.hour * 60 + t.minute;
    return m >= workStart.minutes && m < workEnd.minutes;
  }
}

/// 轻量时刻值，避免核心层依赖 Flutter 的 TimeOfDay。
class TimeOfDayValue {
  const TimeOfDayValue(this.hour, this.minute);
  final int hour;
  final int minute;
  int get minutes => hour * 60 + minute;

  DateTime onDay(DateTime day) {
    final local = day.toLocal();
    return DateTime(local.year, local.month, local.day, hour, minute);
  }
}
