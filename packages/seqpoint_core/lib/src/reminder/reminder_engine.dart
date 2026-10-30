import '../model/enums.dart';
import '../model/item.dart';
import '../model/reminder.dart';
import '../util/clock.dart';
import 'reminder_policy.dart';

/// 一条待发出的通知。平台层负责真正调度与展示。
class ReminderPlan {
  const ReminderPlan({
    required this.itemId,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.mode,
    this.reminderId,
    this.isStrong = false,
    this.reason,
  });

  final String itemId;
  final DateTime fireAt;
  final String title;
  final String body;
  final ReminderMode mode;

  /// 由已有 Reminder 触发时带上它的 id；智能提醒是引擎新生成的，为 null。
  final String? reminderId;

  /// 用户亲设的强提醒，不受智能策略与每日上限约束。
  final bool isStrong;

  /// 可解释性：为何收到这条提醒。
  final String? reason;
}

/// 抑制原因，用于诊断与"为什么没提醒我"的解释。
enum SuppressReason { quietHours, dailyCap, dedupe, ideaTag, notActionable }

/// 提醒决策引擎。纯函数式，不碰数据库，便于单测。
///
/// 硬规则（智能策略不得绕过）：
/// - 用户亲设的精确提醒必须按时触发，绝不延迟；
/// - 同一事项的智能提醒每日不超过上限（强提醒不计入）；
/// - 勿扰时段内不发，除非 P0 且用户显式允许穿透；
/// - 连续被忽略的低重要度事项转入汇总，不再单独打扰；
/// - "想法"类事项永不提醒。
class ReminderEngine {
  ReminderEngine({
    this.policy = const ReminderPolicy(),
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  final ReminderPolicy policy;
  final Clock _clock;

  /// 计算某事项此刻应发出的提醒。返回空表示不该提醒。
  ///
  /// [smartFiredToday] 今日已发出的智能提醒次数；
  /// [isIdea] 该事项是否被打上"想法"标签；
  /// [ignoredStreak] 连续忽略次数，用于降频。
  List<ReminderPlan> planFor({
    required Item item,
    required List<Reminder> reminders,
    int smartFiredToday = 0,
    bool isIdea = false,
    int ignoredStreak = 0,
    DateTime? at,
  }) {
    final now = at ?? _clock.now();
    if (!item.isOpen) return const [];
    if (isIdea) return const [];

    final plans = <ReminderPlan>[];

    // 1) 用户亲设的提醒：到点就发，不受任何智能策略影响。
    for (final r in reminders) {
      if (!r.enabled) continue;
      final trigger = r.resolveTriggerAt(itemDueAt: item.dueAt);
      if (trigger == null) continue;
      if (trigger.isAfter(now)) continue;
      if (_alreadyFired(r, trigger)) continue;

      final strong = r.isStrong || r.mode == ReminderMode.exact;
      if (!strong && _suppressed(now, item, strong: false) != null) continue;

      plans.add(ReminderPlan(
        reminderId: r.id,
        itemId: item.id,
        fireAt: trigger,
        title: item.title,
        body: _bodyFor(item, now),
        mode: r.mode,
        isStrong: strong,
        reason: strong ? '你为这件事设定了提醒' : _reasonFor(item, now),
      ));
    }

    // 2) 智能提醒：只在没有强提醒覆盖时补位。
    if (plans.any((p) => p.isStrong)) return plans;
    final smart = _planSmart(
      item: item,
      now: now,
      smartFiredToday: smartFiredToday,
      ignoredStreak: ignoredStreak,
    );
    if (smart != null) plans.add(smart);

    return plans;
  }

  /// 智能提醒的时机规则（对应设计文档第 7 章的默认策略表）：
  /// - 有具体时刻 → 提前 15 分钟；
  /// - 只有日期   → 当天 09:00；
  /// - 无时间但措辞急 → 工作时段内一次；
  /// - 无时间普通 → 不单独提醒，只进晚间汇总；
  /// - 逾期       → 次日上午一次，之后升级为整理建议。
  ReminderPlan? _planSmart({
    required Item item,
    required DateTime now,
    required int smartFiredToday,
    required int ignoredStreak,
  }) {
    if (smartFiredToday >= policy.maxSmartPerItemPerDay) return null;
    // 连续被忽略的低重要度事项转入汇总，不再单独打扰。
    if (ignoredStreak >= 2 && !item.isImportant) return null;

    final due = item.dueAt;
    if (due == null) return null; // 无时间的普通事项只进汇总

    final overdue = due.isBefore(now);
    final DateTime fireAt;
    final String reason;

    if (overdue) {
      fireAt = now;
      reason = '已经过了截止时间，还没完成';
    } else {
      final lead = due.subtract(policy.leadTimeBeforeDue);
      if (now.isBefore(lead)) return null; // 还没到提醒窗口
      fireAt = now;
      reason = '${_formatClock(due)} 到期，现在还没开始';
    }

    if (_suppressed(now, item, strong: false) != null) return null;

    return ReminderPlan(
      itemId: item.id,
      fireAt: fireAt,
      title: item.title,
      body: reason,
      mode: overdue ? ReminderMode.overdue : ReminderMode.smart,
      reason: reason,
    );
  }

  /// 晚间汇总：把未完成事项聚成一条。返回 null 表示今晚无需汇总。
  ReminderPlan? planDigest(List<Item> openItems, {DateTime? at}) {
    final now = at ?? _clock.now();
    final pending = openItems.where((i) => i.isOpen).toList();
    if (pending.isEmpty) return null;

    final fireAt = policy.digestAt.onDay(now);
    return ReminderPlan(
      itemId: '',
      fireAt: fireAt,
      title: '今天还有 ${pending.length} 件事没完成',
      body: pending.take(3).map((i) => i.title).join('、'),
      mode: ReminderMode.digest,
      reason: '每天 ${_formatTimeOfDay(policy.digestAt)} 的汇总',
    );
  }

  /// 连续延期或逾期达到阈值时，提醒升级为"重新规划 / 放弃"的整理建议。
  bool shouldEscalate({required int snoozeOrOverdueCount}) =>
      snoozeOrOverdueCount >= policy.overdueEscalateAfter;

  /// 稍后处理的候选间隔。
  List<Duration> snoozeOptions() => const [
        Duration(minutes: 15),
        Duration(hours: 1),
        Duration(hours: 4),
        Duration(days: 1),
      ];

  /// 计算"今晚"这个稍后选项的具体时刻。
  DateTime snoozeUntilTonight(DateTime now) {
    final tonight = policy.digestAt.onDay(now);
    return tonight.isAfter(now) ? tonight : DateTime(tonight.year,
        tonight.month, tonight.day + 1, tonight.hour, tonight.minute);
  }

  /// 判断此刻是否该抑制提醒，返回原因；null 表示可以发。
  SuppressReason? _suppressed(DateTime at, Item item, {required bool strong}) {
    if (strong) return null;
    if (policy.isQuiet(at)) {
      final canBreak = item.priority == Priority.p0 && policy.allowP0Breakthrough;
      if (!canBreak) return SuppressReason.quietHours;
    }
    return null;
  }

  /// 去重：同一提醒在窗口内已经发过就不再发。
  bool _alreadyFired(Reminder r, DateTime trigger) {
    final last = r.lastFiredAt;
    if (last == null) return false;
    if (!last.isBefore(trigger)) return true;
    return trigger.difference(last).abs() < policy.dedupeWindow;
  }

  String _bodyFor(Item item, DateTime now) {
    final due = item.dueAt;
    if (due == null) return '该处理这件事了';
    if (due.isBefore(now)) return '已经过了截止时间';
    return '${_formatClock(due)} 到期';
  }

  String _reasonFor(Item item, DateTime now) =>
      item.isOverdue(now) ? '已逾期' : '临近截止时间';

  static String _formatClock(DateTime t) {
    final local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  static String _formatTimeOfDay(TimeOfDayValue t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
}
