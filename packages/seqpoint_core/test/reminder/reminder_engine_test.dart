import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Item makeItem({
  String id = 'i1',
  String title = '回复张三报价',
  DateTime? dueAt,
  ItemStatus status = ItemStatus.todo,
  Priority priority = Priority.p4,
}) =>
    Item(
      id: id,
      title: title,
      status: status,
      priority: priority,
      source: ItemSource.manual,
      dueAt: dueAt,
      createdAt: DateTime(2026, 9, 5),
      updatedAt: DateTime(2026, 9, 5),
    );

Reminder makeReminder({
  String id = 'r1',
  String itemId = 'i1',
  ReminderMode mode = ReminderMode.exact,
  DateTime? triggerAt,
  int? offsetMinutes,
  bool isStrong = true,
  DateTime? lastFiredAt,
  bool enabled = true,
}) =>
    Reminder(
      id: id,
      itemId: itemId,
      mode: mode,
      triggerAt: triggerAt,
      offsetMinutes: offsetMinutes,
      isStrong: isStrong,
      lastFiredAt: lastFiredAt,
      enabled: enabled,
    );

void main() {
  final engine = ReminderEngine();
  // 工作时段内的参照时刻
  final workTime = DateTime(2026, 9, 5, 14, 0);
  // 勿扰时段内（默认 22:00–08:00）
  final quietTime = DateTime(2026, 9, 5, 23, 30);

  test('UTC瞬时按本地勿扰/工作时段、汇总日期与到期文案处理', () {
    const policy = ReminderPolicy();
    for (final local in [workTime, quietTime]) {
      expect(policy.isQuiet(local.toUtc()), policy.isQuiet(local));
      expect(policy.isWorkTime(local.toUtc()), policy.isWorkTime(local));
      expect(policy.digestAt.onDay(local.toUtc()), policy.digestAt.onDay(local));
    }
    final due = DateTime(2026, 9, 5, 15);
    final local = engine.planFor(item: makeItem(dueAt: due),
        reminders: [makeReminder(triggerAt: workTime)], at: workTime).first;
    final utc = engine.planFor(item: makeItem(dueAt: due.toUtc()),
        reminders: [makeReminder(triggerAt: workTime.toUtc())], at: workTime.toUtc()).first;
    expect(utc.body, local.body);
    expect(utc.reason, local.reason);
  });

  test('DST切换前晚的明晚保持本地汇总钟点', () {
    for (final day in [DateTime(2026, 3, 7, 23), DateTime(2026, 10, 31, 23)]) {
      expect(engine.snoozeUntilTonight(day),
          DateTime(day.year, day.month, day.day + 1, 20));
      expect(engine.snoozeUntilTonight(day.toUtc()),
          DateTime(day.year, day.month, day.day + 1, 20));
    }
  });

  group('精确提醒是强约束', () {
    test('到点必发，即使在勿扰时段', () {
      final plans = engine.planFor(
        item: makeItem(),
        reminders: [makeReminder(triggerAt: quietTime.subtract(const Duration(minutes: 1)))],
        at: quietTime,
      );
      expect(plans, hasLength(1));
      expect(plans.first.isStrong, isTrue);
      expect(plans.first.mode, ReminderMode.exact);
    });

    test('未到点不发', () {
      final plans = engine.planFor(
        item: makeItem(),
        reminders: [makeReminder(triggerAt: workTime.add(const Duration(hours: 1)))],
        at: workTime,
      );
      expect(plans, isEmpty);
    });

    test('已发过的不重复发', () {
      final trigger = workTime.subtract(const Duration(minutes: 5));
      final plans = engine.planFor(
        item: makeItem(),
        reminders: [makeReminder(triggerAt: trigger, lastFiredAt: trigger)],
        at: workTime,
      );
      expect(plans, isEmpty);
    });

    test('相对提醒按截止时间折算', () {
      final due = DateTime(2026, 9, 5, 15, 0);
      final plans = engine.planFor(
        item: makeItem(dueAt: due),
        reminders: [
          makeReminder(mode: ReminderMode.relative, offsetMinutes: -60),
        ],
        at: DateTime(2026, 9, 5, 14, 30),
      );
      expect(plans, hasLength(1));
      expect(plans.first.fireAt, DateTime(2026, 9, 5, 14, 0));
    });
  });

  group('智能提醒', () {
    test('临近截止且未开始时提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      final plans = engine.planFor(
        item: makeItem(dueAt: due),
        reminders: const [],
        at: workTime,
      );
      expect(plans, hasLength(1));
      expect(plans.first.mode, ReminderMode.smart);
      expect(plans.first.reason, contains('还没开始'));
    });

    test('离截止还早不提醒', () {
      final due = workTime.add(const Duration(hours: 5));
      expect(
        engine.planFor(item: makeItem(dueAt: due), reminders: const [], at: workTime),
        isEmpty,
      );
    });

    test('逾期会提醒并标记为 overdue', () {
      final due = workTime.subtract(const Duration(hours: 2));
      final plans = engine.planFor(
        item: makeItem(dueAt: due),
        reminders: const [],
        at: workTime,
      );
      expect(plans.first.mode, ReminderMode.overdue);
    });

    test('无截止时间的普通事项不单独提醒', () {
      expect(
        engine.planFor(item: makeItem(), reminders: const [], at: workTime),
        isEmpty,
      );
    });

    test('达到每日上限后不再发', () {
      final due = workTime.add(const Duration(minutes: 10));
      expect(
        engine.planFor(
          item: makeItem(dueAt: due),
          reminders: const [],
          smartFiredToday: 2,
          at: workTime,
        ),
        isEmpty,
      );
    });

    test('勿扰时段内不发智能提醒', () {
      final due = quietTime.add(const Duration(minutes: 10));
      expect(
        engine.planFor(
          item: makeItem(dueAt: due),
          reminders: const [],
          at: quietTime,
        ),
        isEmpty,
      );
    });

    test('P0 且允许穿透时可在勿扰时段发', () {
      final permissive =
          ReminderEngine(policy: const ReminderPolicy(allowP0Breakthrough: true));
      final due = quietTime.add(const Duration(minutes: 10));
      final plans = permissive.planFor(
        item: makeItem(dueAt: due, priority: Priority.p0),
        reminders: const [],
        at: quietTime,
      );
      expect(plans, hasLength(1));
    });

    test('连续被忽略的低重要度事项转入汇总，不再单独提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      expect(
        engine.planFor(
          item: makeItem(dueAt: due),
          reminders: const [],
          ignoredStreak: 2,
          at: workTime,
        ),
        isEmpty,
      );
    });

    test('重要事项即使被忽略过也继续提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      final plans = engine.planFor(
        item: makeItem(dueAt: due, priority: Priority.p1),
        reminders: const [],
        ignoredStreak: 3,
        at: workTime,
      );
      expect(plans, hasLength(1));
    });

    test('有强提醒时不再补智能提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      final plans = engine.planFor(
        item: makeItem(dueAt: due),
        reminders: [makeReminder(triggerAt: workTime.subtract(const Duration(minutes: 1)))],
        at: workTime,
      );
      expect(plans, hasLength(1));
      expect(plans.first.isStrong, isTrue);
    });
  });

  group('边界', () {
    test('已完成的事项不提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      expect(
        engine.planFor(
          item: makeItem(dueAt: due, status: ItemStatus.done),
          reminders: [makeReminder(triggerAt: workTime)],
          at: workTime,
        ),
        isEmpty,
      );
    });

    test('想法类事项永不提醒', () {
      final due = workTime.add(const Duration(minutes: 10));
      expect(
        engine.planFor(
          item: makeItem(dueAt: due),
          reminders: [makeReminder(triggerAt: workTime)],
          isIdea: true,
          at: workTime,
        ),
        isEmpty,
      );
    });

    test('禁用的提醒不触发', () {
      expect(
        engine.planFor(
          item: makeItem(),
          reminders: [makeReminder(triggerAt: workTime, enabled: false)],
          at: workTime,
        ),
        isEmpty,
      );
    });
  });

  group('汇总与升级', () {
    test('有未完成事项时生成晚间汇总', () {
      final digest = engine.planDigest([
        makeItem(id: 'a', title: '事项一'),
        makeItem(id: 'b', title: '事项二'),
      ], at: workTime);
      expect(digest, isNotNull);
      expect(digest!.title, contains('2 件'));
      expect(digest.fireAt.hour, 20);
      expect(digest.mode, ReminderMode.digest);
    });

    test('没有未完成事项时不汇总', () {
      expect(
        engine.planDigest([makeItem(status: ItemStatus.done)], at: workTime),
        isNull,
      );
    });

    test('连续延期到阈值后升级为整理建议', () {
      expect(engine.shouldEscalate(snoozeOrOverdueCount: 2), isFalse);
      expect(engine.shouldEscalate(snoozeOrOverdueCount: 3), isTrue);
    });

    test('"今晚"稍后：当天已过 20 点则顺延到明晚', () {
      expect(engine.snoozeUntilTonight(workTime), DateTime(2026, 9, 5, 20));
      expect(engine.snoozeUntilTonight(quietTime), DateTime(2026, 9, 6, 20));
    });
  });
}
