import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/reminder_coordinator.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'notification_support.dart';

void main() {
  for (final cancelFailed in [true, false]) {
    test('汇总失败跨过触发时刻重试不会复活旧成员：cancelFailed=$cancelFailed', () async {
      final db = SeqDatabase.inMemory()..migrate();
      final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
      final notifications = TestNotifications();
      addTearDown(() { db.close(); return notifications.events.close(); });
      Item add(String title) => ItemRepository(db).insert(Item(id: '', title: title,
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: clock.now(), updatedAt: clock.now(),
        dueAt: clock.now().subtract(const Duration(minutes: 5))));
      final a = add('稍后A'); add('仍逾期B');
      final coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
      addTearDown(coordinator.dispose);
      await coordinator.reconcile();
      final oldId = notifications.scheduled.single.id;
      notifications.failCancel = cancelFailed;
      notifications.failSchedule = !cancelFailed;
      await coordinator.snooze(a.id);
      expect(coordinator.error, isNotNull);
      clock.advance(const Duration(seconds: 2));
      notifications.failCancel = false; notifications.failSchedule = false;
      await coordinator.reconcile();
      final groups = NotificationPlanRepository(db).active()
        .where((p) => p.key.startsWith('catchup|')).toList();
      expect(groups, hasLength(1));
      expect(groups.single.key.split('|').last, '1');
      expect(notifications.scheduled.where((n) => n.id == oldId), hasLength(1));
      expect(notifications.scheduled.lastWhere((n) => n.id == groups.single.id).title,
        '启动时发现1项漏期提醒');
    });
  }

  test('旧格式待发汇总可升级，取消失败后仍只恢复有效事项的汇总', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final due = clock.now().subtract(const Duration(minutes: 5));
    Item add(String title) => ItemRepository(db).insert(Item(id: '', title: title,
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(), dueAt: due));
    final a = add('旧A'); final b = add('旧B');
    final plans = NotificationPlanRepository(db);
    final first = plans.ensure(key: '${a.id}|${due.toIso8601String()}', itemId: a.id, fireAt: due);
    final second = plans.ensure(key: '${b.id}|${due.toIso8601String()}', itemId: b.id, fireAt: due);
    plans.setState(first.id, 'retired'); plans.setState(second.id, 'retired');
    final legacy = plans.ensure(key: 'catchup|${first.id}|2', itemId: '@today',
      fireAt: clock.now().add(const Duration(seconds: 1)));
    plans.setState(legacy.id, 'scheduled');
    final coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
    addTearDown(coordinator.dispose);
    notifications.failCancel = true;
    await coordinator.snooze(a.id);
    expect(coordinator.error, isNotNull);
    expect(notifications.scheduled, isEmpty);
    notifications.failCancel = false;
    await coordinator.reconcile();
    final active = plans.active().where((p) => p.key.startsWith('catchup|')).toList();
    expect(active, hasLength(1));
    expect(active.single.key, 'catchup|v2:${second.id}|1');
    expect(notifications.cancelled, contains(legacy.id));
    expect(notifications.scheduled, hasLength(2));
    await coordinator.reconcile();
    expect(notifications.scheduled, hasLength(2));
  });

  for (final addedLater in [false, true]) {
    test('稍后移出合并补提醒，其他事项仍只补一次：addedLater=$addedLater', () async {
      final db = SeqDatabase.inMemory()..migrate();
      final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
      final notifications = TestNotifications();
      addTearDown(() { db.close(); return notifications.events.close(); });
      Item add(String title) => ItemRepository(db).insert(Item(id: '', title: title,
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: clock.now(), updatedAt: clock.now(),
        dueAt: clock.now().subtract(const Duration(minutes: 5))));
      final a = add('稍后A'); late Item b;
      if (!addedLater) b = add('仍逾期B');
      final coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
      addTearDown(coordinator.dispose);
      await coordinator.reconcile();
      final oldId = notifications.scheduled.single.id;
      if (addedLater) b = add('新逾期B');
      await coordinator.snooze(a.id);
      expect(notifications.cancelled, contains(oldId));
      final catchups = NotificationPlanRepository(db).active()
        .where((p) => p.key.startsWith('catchup|')).toList();
      expect(catchups, hasLength(1));
      expect(catchups.single.key.split('|').last, '1');
      expect(notifications.scheduled.lastWhere((n) => n.id == catchups.single.id).title,
        '启动时发现1项漏期提醒');
      final scheduled = notifications.scheduled.length;
      await coordinator.reconcile();
      expect(notifications.scheduled, hasLength(scheduled));
      ItemRepository(db).update(b.copyWith(status: ItemStatus.done));
      await coordinator.reconcile();
      expect(NotificationPlanRepository(db).active()
        .any((p) => p.key.startsWith('catchup|')), isFalse);
    });
  }

  for (final state in ['done', 'deletedNote', 'paused', 'stopped', 'zeroDelay', 'readonly']) {
    test('稍后拒绝不可提醒或不可写状态：$state', () async {
      final boot = await Bootstrap.run(dbPath: ':memory:');
      final notifications = TestNotifications();
      final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
      addTearDown(() { boot.dispose(); return notifications.events.close(); });
      final note = boot.noteService.capture('不可稍后测试');
      final item = boot.noteService.lineToItem(note.id, 0);
      boot.items.update(item.copyWith(dueAt: clock.now()));
      final coordinator = ReminderCoordinator(db: boot.db,
        notifications: notifications, clock: clock);
      if (state != 'stopped') addTearDown(coordinator.dispose);
      if (state == 'done') boot.noteService.toggleItem(item.id);
      if (state == 'deletedNote') boot.noteService.trash(note.id);
      if (state == 'paused') await coordinator.pause();
      if (state == 'stopped') coordinator.dispose();
      if (state == 'readonly') boot.db.raw.execute('PRAGMA query_only = ON');
      await expectLater(coordinator.snooze(item.id,
        delay: state == 'zeroDelay' ? Duration.zero : const Duration(hours: 1)),
        state == 'readonly' ? throwsA(predicate<Object>((e) => e.toString().contains('readonly')))
          : throwsStateError);
      expect(ReminderRepository(boot.db).forItem(item.id), isEmpty);
      expect(notifications.scheduled, isEmpty);
    });
  }

  test('重复稍后替换旧时刻，取消失败后重开仍可重试且截止不变', () async {
    final directory = await Directory.systemTemp.createTemp('seqpoint-snooze-');
    final path = '${directory.path}/snooze.db';
    var db = SeqDatabase.open(path)..migrate();
    final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
    final notifications = TestNotifications();
    var coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
    addTearDown(() async {
      coordinator.dispose(); db.close(); await notifications.events.close();
      await directory.delete(recursive: true);
    });
    final item = ItemRepository(db).insert(Item(id: '', title: '持久稍后',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(minutes: 15))));
    await coordinator.reconcile();
    final oldId = notifications.scheduled.single.id;
    await coordinator.snooze(item.id);
    final first = ReminderRepository(db).forItem(item.id).single;
    clock.advance(const Duration(minutes: 1));
    notifications.failCancel = true;
    await coordinator.snooze(item.id);
    final records = ReminderRepository(db).forItem(item.id);
    expect(records, hasLength(1));
    expect(records.single.id, first.id);
    expect(records.single.snoozeCount, 2);
    expect(coordinator.error, isNotNull);
    coordinator.dispose(); db.close();
    db = SeqDatabase.open(path)..migrate();
    notifications.failCancel = false;
    coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
    await coordinator.start();
    expect(coordinator.error, isNull);
    expect(ItemRepository(db).byId(item.id)!.dueAt, item.dueAt);
    expect(notifications.cancelled, contains(oldId));
    expect(notifications.scheduled.last.fireAt, clock.now().add(const Duration(hours: 1)));
    expect(ReminderRepository(db).forItem(item.id).single.snoozeCount, 2);
  });

  test('稍后覆盖旧提醒但保留之后的提醒，不改截止日期或重复补旧提醒', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final clock = FakeClock(DateTime.utc(2026, 10, 28, 10));
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final item = ItemRepository(db).insert(Item(id: '', title: '稍后测试',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(minutes: 15))));
    final repo = ReminderRepository(db);
    for (final minutes in [30, 120]) {
      repo.insert(Reminder(id: '', itemId: item.id, mode: ReminderMode.exact,
        triggerAt: clock.now().add(Duration(minutes: minutes))));
    }
    final until = clock.now().add(const Duration(hours: 1));
    repo.insert(Reminder(id: '', itemId: item.id, mode: ReminderMode.exact,
      triggerAt: until, feedback: ReminderFeedback.snoozed, snoozeCount: 1));
    expect(reminderPlans(db, clock.now(), includePast: true).values
      .map((p) => p.fireAt).toSet(), {until, clock.now().add(const Duration(hours: 2))});
    expect(ItemRepository(db).byId(item.id)!.dueAt, item.dueAt);
    final coordinator = ReminderCoordinator(db: db, clock: clock, notifications: notifications);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    expect(notifications.scheduled, hasLength(2));
    clock.advance(const Duration(minutes: 61));
    await coordinator.reconcile();
    expect(notifications.scheduled, hasLength(2));
    expect(NotificationPlanRepository(db).active()
      .any((p) => p.key.startsWith('catchup|')), isFalse);
  });
}
