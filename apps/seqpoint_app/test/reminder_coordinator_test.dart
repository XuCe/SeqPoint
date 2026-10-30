import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/reminder_coordinator.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'notification_support.dart';

void main() {
  test('整签删除撤销提醒，恢复只重建仍有效的未来计划', () async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final notifications = TestNotifications();
    addTearDown(() { boot.dispose(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final note = boot.noteService.capture('可恢复的事项');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.items.update(item.copyWith(
      dueAt: clock.now().add(const Duration(hours: 2))));
    final coordinator = ReminderCoordinator(db: boot.db,
      notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    final id = notifications.scheduled.single.id;
    boot.noteService.trash(note.id);
    await coordinator.reconcile();
    expect(notifications.cancelled, [id]);
    boot.noteService.restore(note.id);
    await coordinator.reconcile();
    expect(notifications.scheduled.last.id, id);
    boot.noteService.trash(note.id);
    await coordinator.reconcile();
    clock.advance(const Duration(hours: 3));
    boot.noteService.restore(note.id);
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 2);
    expect(NotificationPlanRepository(boot.db).active(), isEmpty);
  });

  test('容量不足优先最近期限，改期替换，槽位释放后补齐待发', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final repo = ItemRepository(db);
    Item add(String title, int minutes) => repo.insert(Item(id: '', title: title,
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(Duration(minutes: minutes))));
    final late = add('远期', 120);
    add('近期', 30);
    final middle = add('中期', 60);
    final coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock, capacity: 2);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    expect(notifications.scheduled.map((n) => n.title), ['近期', '中期']);
    expect(coordinator.deferredCount, 1);
    final middleId = notifications.scheduled.last.id;
    repo.update(late.copyWith(dueAt: clock.now().add(const Duration(minutes: 5))));
    await coordinator.reconcile();
    expect(notifications.cancelled, contains(middleId));
    expect(notifications.scheduled.last.title, '远期');
    expect(NotificationPlanRepository(db).active()
      .where((p) => p.state == 'scheduled').length, 2);
    clock.advance(const Duration(minutes: 6));
    await coordinator.reconcile();
    expect(notifications.scheduled.last.id, middleId);
    expect(notifications.scheduled.last.itemId, middle.id);
    expect(coordinator.deferredCount, 0);
  });

  test('重新启动以原ID重建系统已清空的未来计划', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    ItemRepository(db).insert(Item(id: '', title: '系统清空',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(hours: 2))));
    var coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    await coordinator.reconcile();
    final originalId = notifications.scheduled.single.id;
    coordinator.dispose();
    notifications.scheduled.clear();
    coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.start();
    expect(notifications.scheduled.length, 1);
    expect(notifications.scheduled.single.id, originalId);
  });

  testWidgets('周期对账读取外部变更，暂停及销毁后停止，恢复可继续', (tester) async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    await coordinator.start();
    final repo = ItemRepository(db);
    final item = repo.insert(Item(id: '', title: '外部写入',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(hours: 2))));
    await tester.pump(const Duration(seconds: 6));
    expect(notifications.scheduled.length, 1);
    await coordinator.pause();
    repo.update(item.copyWith(status: ItemStatus.done));
    await tester.pump(const Duration(seconds: 6));
    expect(notifications.cancelled, isEmpty);
    await coordinator.start();
    expect(notifications.cancelled.length, 1);
    coordinator.dispose();
    repo.update(item.copyWith(dueAt: item.dueAt!.add(const Duration(hours: 1))));
    await tester.pump(const Duration(seconds: 6));
    expect(notifications.scheduled.length, 1);
  });

  test('重启漏期合并补提醒，安排失败重试且再次重建不重复', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications()..failSchedule = true;
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    for (var i = 0; i < 3; i++) {
      ItemRepository(db).insert(Item(id: '', title: '漏期$i',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: clock.now(), updatedAt: clock.now(),
        dueAt: clock.now().subtract(const Duration(minutes: 1))));
    }
    var coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    await coordinator.reconcile();
    expect(NotificationPlanRepository(db).active().length, 1);
    coordinator.dispose();
    coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    notifications.failSchedule = false;
    await coordinator.reconcile();
    expect(notifications.scheduled.single.title, contains('3'));
    coordinator.dispose();
    coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    clock.advance(const Duration(minutes: 1));
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 1);
    expect(notifications.cancelled, isEmpty);
  });

  test('正常到期的已安排通知不会被下一次对账立即移除', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    ItemRepository(db).insert(Item(id: '', title: '已到期',
      status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(minutes: 1))));
    final coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    clock.advance(const Duration(minutes: 2));
    await coordinator.reconcile();
    expect(notifications.cancelled, isEmpty);
    expect(notifications.scheduled.length, 1);
    expect(NotificationPlanRepository(db).active(), isEmpty);
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 1);
  });

  test('权限被撤销后仍取消旧计划，新计划待授权再安排', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final repo = ItemRepository(db);
    final item = repo.insert(Item(id: '', title: '权限', status: ItemStatus.todo,
      priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(hours: 2))));
    final coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    final oldId = notifications.scheduled.single.id;
    notifications.granted = false;
    repo.update(item.copyWith(dueAt: item.dueAt!.add(const Duration(hours: 1))));
    await coordinator.reconcile();
    expect(notifications.cancelled, [oldId]);
    expect(NotificationPlanRepository(db).active().single.state, 'pending');
    expect(coordinator.error, contains('权限'));
    notifications.granted = true;
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 2);
    expect(coordinator.error, isNull);
  });

  test('安排和取消失败可跨协调器重试，始终使用同一ID', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications()..failSchedule = true;
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final repo = ItemRepository(db);
    final item = repo.insert(Item(id: '', title: '重试', status: ItemStatus.todo,
      priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(hours: 2))));
    var coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    await coordinator.reconcile();
    final pending = NotificationPlanRepository(db).active().single;
    expect(pending.state, 'pending');
    expect(coordinator.error, contains('调度'));
    coordinator.dispose();
    coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    notifications.failSchedule = false;
    await coordinator.reconcile();
    expect(notifications.scheduled.single.id, pending.id);
    notifications.failCancel = true;
    repo.update(item.copyWith(status: ItemStatus.done));
    await coordinator.reconcile();
    expect(NotificationPlanRepository(db).active().single.state,
      'cancel_pending');
    notifications.failCancel = false;
    await coordinator.reconcile();
    expect(NotificationPlanRepository(db).active(), isEmpty);
    expect(notifications.cancelled.single, pending.id);
  });

  test('未来计划稳定去重，改期撤旧，完成后取消全部提醒', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 25, 10));
    final repo = ItemRepository(db);
    var item = repo.insert(Item(id: '', title: '会议', status: ItemStatus.todo,
      priority: Priority.p4, source: ItemSource.manual,
      createdAt: clock.now(), updatedAt: clock.now(),
      dueAt: clock.now().add(const Duration(hours: 2))));
    ReminderRepository(db).insert(Reminder(id: '', itemId: item.id,
      mode: ReminderMode.relative, offsetMinutes: -15));
    final coordinator = ReminderCoordinator(
      db: db, notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 2);
    expect(notifications.scheduled.map((n) => n.fireAt),
      contains(item.dueAt!.subtract(const Duration(minutes: 15))));
    await coordinator.reconcile();
    expect(notifications.scheduled.length, 2);
    final oldIds = notifications.scheduled.map((n) => n.id).toSet();
    item = item.copyWith(dueAt: item.dueAt!.add(const Duration(hours: 1)));
    repo.update(item);
    await coordinator.reconcile();
    expect(notifications.cancelled.toSet(), oldIds);
    expect(notifications.scheduled.length, 4);
    repo.update(item.copyWith(status: ItemStatus.done));
    await coordinator.reconcile();
    expect(NotificationPlanRepository(db).active(), isEmpty);
    expect(notifications.cancelled.length, 4);
  });
}
