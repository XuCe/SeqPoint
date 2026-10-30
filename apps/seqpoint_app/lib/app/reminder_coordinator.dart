import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

typedef PlannedReminder = ({Item item, DateTime fireAt});

/// 相同事项与时刻只生成一条计划；平台状态独立持久化。
Map<String, PlannedReminder> reminderPlans(SeqDatabase db, DateTime now,
    {bool includePast = false}) {
  final result = <String, PlannedReminder>{};
  void add(Item item, DateTime? time) {
    if (time == null || (!includePast && !time.isAfter(now))) return;
    final at = time.toUtc();
    result['${item.id}|${at.toIso8601String()}'] = (item: item, fireAt: at);
  }
  final reminders = ReminderRepository(db);
  for (final item in ItemRepository(db).remindable()) {
    final records = reminders.forItem(item.id);
    final snoozes = records.where((r) => r.enabled &&
      r.mode == ReminderMode.exact && r.feedback == ReminderFeedback.snoozed)
      .map((r) => r.triggerAt).whereType<DateTime>().toList()..sort();
    final until = snoozes.lastOrNull;
    void addAfterSnooze(DateTime? time) {
      if (time != null && (until == null || time.isAfter(until))) add(item, time);
    }
    add(item, until);
    addAfterSnooze(item.dueAt);
    for (final reminder in records) {
      if (!reminder.enabled ||
          (reminder.mode != ReminderMode.exact &&
           reminder.mode != ReminderMode.relative)) {
        continue;
      }
      final at = reminder.resolveTriggerAt(itemDueAt: item.dueAt);
      if (at != null && reminder.lastFiredAt != null &&
          !reminder.lastFiredAt!.isBefore(at)) {
        continue;
      }
      addAfterSnooze(at);
    }
  }
  return result;
}

class ReminderCoordinator extends ChangeNotifier {
  ReminderCoordinator({required SeqDatabase db,
    required NotificationService notifications,
    Clock clock = const SystemClock(), this.capacity})
    : assert(capacity == null || capacity > 0),
      _db = db, _notifications = notifications, _clock = clock,
      plans = NotificationPlanRepository(db);
  final SeqDatabase _db;
  final NotificationService _notifications;
  final Clock _clock;
  final int? capacity;
  final NotificationPlanRepository plans;
  Future<void> _tail = Future.value();
  Timer? _timer;
  bool _paused = false;
  bool _polling = false;
  bool _stopped = false;
  String? error;
  bool checked = false;
  int deferredCount = 0;

  /// 本机稍后提醒只覆盖此前的通知，不移动事项截止日期或生成同步操作。
  Future<void> snooze(String itemId,
      {Duration delay = const Duration(hours: 1)}) async {
    if (_stopped || _paused || delay <= Duration.zero) {
      throw StateError('当前无法稍后提醒');
    }
    _db.transaction(() {
      if (!ItemRepository(_db).remindable().any((item) => item.id == itemId)) {
        throw StateError('事项已完成、删除或不可提醒');
      }
      final repo = ReminderRepository(_db);
      final snoozes = repo.forItem(itemId).where((r) =>
        r.mode == ReminderMode.exact && r.feedback == ReminderFeedback.snoozed).toList();
      final previous = snoozes.firstOrNull;
      for (final old in snoozes.skip(1)) {
        if (old.enabled) repo.update(old.copyWith(enabled: false));
      }
      final reminder = Reminder(id: previous?.id ?? '', itemId: itemId,
        mode: ReminderMode.exact, triggerAt: _clock.now().add(delay),
        isStrong: true, feedback: ReminderFeedback.snoozed,
        snoozeCount: (previous?.snoozeCount ?? 0) + 1);
      if (previous == null) {
        repo.insert(reminder);
      } else {
        repo.update(reminder);
      }
    });
    await reconcile();
  }

  // 主引擎轮询共享数据库，也覆盖便签子引擎及同步写入。
  Future<void> start() {
    if (_stopped) return Future.value();
    _paused = false;
    // 系统可能在应用停止期间清空闹钟，以原ID恢复可覆盖的未来计划。
    for (final plan in plans.active()) {
      if (plan.state == 'scheduled' && plan.fireAt.isAfter(_clock.now())) {
        plans.setState(plan.id, 'pending');
      }
    }
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_polling || _paused || _stopped) return;
      _polling = true;
      unawaited(reconcile().whenComplete(() => _polling = false));
    });
    return reconcile();
  }

  Future<void> pause() async {
    _timer?.cancel();
    _timer = null;
    _paused = true;
    await _tail;
  }

  Future<void> reconcile() => _tail = _tail.then((_) async {
    if (_stopped || _paused) return;
    try {
      final granted = await _notifications.requestPermission();
      if (_stopped) return;
      await _apply(reminderPlans(_db, _clock.now()), granted);
      error = granted ? null : '通知权限未启用';
    } catch (e) {
      error = '提醒调度失败：$e';
    }
    checked = true;
    if (!_stopped) notifyListeners();
  });

  Future<void> _apply(Map<String, PlannedReminder> desired, bool granted) async {
    final valid = reminderPlans(_db, _clock.now(), includePast: true);
    final pendingCatchUp = _prepareCatchUp(valid);
    for (final entry in desired.entries) {
      plans.ensure(key: entry.key, itemId: entry.value.item.id,
        fireAt: entry.value.fireAt);
    }
    final hasOverdue = valid.values.any(
      (value) => !value.fireAt.isAfter(_clock.now()));
    bool wanted(NotificationPlan plan) => desired.containsKey(plan.key) ||
      (plan.key.startsWith('catchup|') && (plan.state != 'scheduled' || plan.fireAt.isAfter(_clock.now())
        ? plan.key == pendingCatchUp : hasOverdue));
    final eligible = plans.active().where((p) => wanted(p) &&
      (p.state != 'scheduled' || p.fireAt.isAfter(_clock.now()))).toList()
      ..sort((a, b) {
        final order = a.fireAt.compareTo(b.fireAt);
        return order == 0 ? a.id.compareTo(b.id) : order;
      });
    final selected = eligible.take(capacity ?? eligible.length)
      .map((p) => p.id).toSet();
    deferredCount = eligible.length - selected.length;
    for (final plan in plans.active()) {
      if (plan.state == 'scheduled' && !plan.fireAt.isAfter(_clock.now()) &&
          (valid.containsKey(plan.key) ||
            (plan.key.startsWith('catchup|') && hasOverdue))) {
        plans.setState(plan.id, 'retired');
        continue;
      }
      if (!wanted(plan) || plan.state == 'cancel_pending' ||
          (!selected.contains(plan.id) && plan.state == 'scheduled')) {
        plans.setState(plan.id, 'cancel_pending');
        await _notifications.cancel(plan.id);
        if (_stopped) return;
        plans.setState(plan.id,
          wanted(plan) ? 'pending' : 'retired');
      }
    }
    if (!granted) return;
    final pending = plans.active()
      ..sort((a, b) => a.fireAt.compareTo(b.fireAt));
    for (final plan in pending) {
      if (_stopped) return;
      if (plan.state != 'pending' || !selected.contains(plan.id)) continue;
      final value = desired[plan.key];
      final catchUp = plan.key.startsWith('catchup|');
      if (value == null && !catchUp) continue;
      await _notifications.schedule(NotificationRequest(
        id: plan.id,
        title: catchUp ? '启动时发现${plan.key.split('|').last}项漏期提醒'
          : value!.item.title,
        body: catchUp ? '点击查看今日事项' : '事项到期提醒',
        fireAt: plan.fireAt.isAfter(_clock.now()) ? plan.fireAt
          : _clock.now().add(const Duration(seconds: 1)),
        itemId: plan.itemId, actions: const [],
      ));
      if (_stopped) return;
      plans.setState(plan.id, 'scheduled');
    }
  }

  String? _prepareCatchUp(Map<String, PlannedReminder> valid) {
    return _db.transaction(() {
      final missed = <NotificationPlan>[];
      final overdue = <int, NotificationPlan>{};
      for (final entry in valid.entries) {
        final value = entry.value;
        if (value.fireAt.isAfter(_clock.now())) continue;
        final plan = plans.ensure(key: entry.key, itemId: value.item.id,
          fireAt: value.fireAt, reactivate: false);
        overdue[plan.id] = plan;
        if (plan.state == 'pending') {
          missed.add(plan);
          plans.setState(plan.id, 'retired');
        }
      }
      final pending = plans.active().where((p) => p.key.startsWith('catchup|') &&
        (p.state != 'scheduled' || p.fireAt.isAfter(_clock.now()))).toList();
      final members = missed.map((p) => p.id).toSet();
      for (final group in pending) {
        final encoded = group.key.split('|')[1];
        if (!encoded.startsWith('v2:')) {
          // 旧格式未记录完整成员，重建尚未投递的当前有效汇总。
          members.addAll(overdue.keys);
        } else {
          members.addAll(encoded.substring(3).split(',').map(int.parse)
            .where(overdue.containsKey));
        }
      }
      if (members.isEmpty) return null;
      final ids = members.toList()..sort();
      final count = ids.map((id) => overdue[id]!.itemId).toSet().length;
      final key = 'catchup|v2:${ids.join(',')}|$count';
      plans.ensure(key: key, itemId: '@today',
        fireAt: _clock.now().add(const Duration(seconds: 1)), reactivate: pending.isNotEmpty);
      return key;
    });
  }

  @override
  void dispose() {
    _stopped = true;
    _timer?.cancel();
    super.dispose();
  }
}
