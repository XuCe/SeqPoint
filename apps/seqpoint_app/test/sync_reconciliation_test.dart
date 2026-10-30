import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/reminder_coordinator.dart';
import 'package:seqpoint_app/sync/sync_reconciliation.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'notification_support.dart';

void main() {
  test('回调失败仅报告本次，后续重试和暂停排空不被失败Future毒化', () async {
    var attempts = 0;
    final reconciliation = SyncReconciliation(onChanged: () {
      attempts++;
      if (attempts == 1) throw StateError('refresh failed');
    });
    await expectLater(reconciliation.afterRemoteChange(), throwsStateError);
    await reconciliation.afterRemoteChange();
    expect(attempts, 2);
    await reconciliation.pause();
    await reconciliation.afterRemoteChange();
    expect(attempts, 2);
  });
  test('同步投影的想法关联与角色改名立即影响今日和系统提醒', () async {
    final source = SeqDatabase.inMemory()..migrate();
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications();
    addTearDown(() {
      source.close(); db.close(); return notifications.events.close();
    });
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
    final tags = TagRepository(source)..ensureBuiltins();
    final clock = FakeClock(DateTime(2026, 10, 26, 10));
    final items = ItemRepository(source);
    items.insert(Item(id: 'remote', title: '同步角色', status: ItemStatus.todo,
        priority: Priority.p4, source: ItemSource.manual, createdAt: clock.now(),
        updatedAt: clock.now(), dueAt: clock.now().add(const Duration(hours: 1))));
    final reminders = ReminderCoordinator(db: db,
        notifications: notifications, clock: clock);
    addTearDown(reminders.dispose);
    final sync = SyncReconciliation(reminders: reminders, onChanged: () {});
    _project(source, db);
    await sync.afterRemoteChange();
    final originalId = notifications.scheduled.single.id;
    items.addTag('remote', 'builtin-type:8');
    _project(source, db);
    await sync.afterRemoteChange();
    expect(notifications.cancelled, [originalId]);
    expect(ItemRepository(db).dueOn(clock.now()), isEmpty);
    tags.rename('builtin-type:8', '灵感');
    _project(source, db);
    await sync.afterRemoteChange();
    expect(notifications.scheduled, hasLength(1));
    expect(ItemRepository(db).dueOn(clock.now()), isEmpty);
    tags.rename('builtin-type:0', '想法');
    items.setTags('remote', ['builtin-type:0']);
    _project(source, db);
    await sync.afterRemoteChange();
    expect(notifications.scheduled, hasLength(2));
    expect(notifications.scheduled.last.id, originalId);
    expect(ItemRepository(db).dueOn(clock.now()).single.id, 'remote');
    expect(db.raw.select("SELECT * FROM sync_operations WHERE source='local'"),
        isEmpty);
  });
  test('对账失败保留已提交业务与可见错误，下一次提交可重试', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = TestNotifications()..failSchedule = true;
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 26));
    final reminders = ReminderCoordinator(db: db,
        notifications: notifications, clock: clock);
    addTearDown(reminders.dispose);
    var refreshes = 0;
    final sync = SyncReconciliation(reminders: reminders,
        onChanged: () => refreshes++);
    ItemRepository(db).insert(Item(id: 'committed', title: '提交成功',
        status: ItemStatus.todo, priority: Priority.p4,
        source: ItemSource.manual, createdAt: clock.now(),
        updatedAt: clock.now(), dueAt: clock.now().add(const Duration(hours: 1))));
    await sync.afterRemoteChange();
    expect(refreshes, 1);
    expect(ItemRepository(db).byId('committed'), isNotNull);
    expect(reminders.error, contains('提醒调度失败'));
    notifications.failSchedule = false;
    await sync.afterRemoteChange();
    expect(refreshes, 2);
    expect(reminders.error, isNull);
    expect(notifications.scheduled.single.itemId, 'committed');
  });

  test('无系统提醒通道仍刷新远端数据，暂停后不再刷新', () async {
    var refreshes = 0;
    final sync = SyncReconciliation(onChanged: () => refreshes++);
    await sync.afterRemoteChange();
    expect(refreshes, 1);
    await sync.pause();
    await sync.afterRemoteChange();
    expect(refreshes, 1);
  });
  test('暂停排空受理队列，旧库关闭后迟到回调不再读库或刷新', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final notifications = _PermissionGate();
    addTearDown(() => notifications.events.close());
    final reminders = ReminderCoordinator(db: db, notifications: notifications);
    var refreshes = 0;
    final sync = SyncReconciliation(reminders: reminders,
        onChanged: () => refreshes++);
    final first = sync.afterRemoteChange();
    await Future<void>.delayed(Duration.zero);
    final queued = sync.afterRemoteChange();
    var drained = false;
    final paused = sync.pause().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    notifications.permission.complete(true);
    await Future.wait([first, queued, paused]);
    expect(refreshes, 0);
    expect(notifications.requests, 1);
    reminders.dispose();
    db.close();
    await sync.afterRemoteChange();
    expect(refreshes, 0);
  });
  test('远端提交后立即对账当前DB并在提醒完成后刷新UI', () async {
    final db = SeqDatabase.inMemory()..migrate();
    final source = SeqDatabase.inMemory()..migrate();
    addTearDown(source.close);
    source.raw.execute("UPDATE sync_local SET enabled=1,device_id='peer'");
    db.raw.execute("UPDATE sync_local SET enabled=1,device_id='local'");
    final notifications = TestNotifications();
    addTearDown(() { db.close(); return notifications.events.close(); });
    final clock = FakeClock(DateTime.utc(2026, 10, 26, 10));
    final reminders = ReminderCoordinator(db: db,
        notifications: notifications, clock: clock);
    addTearDown(reminders.dispose);
    var refreshes = 0;
    final sync = SyncReconciliation(reminders: reminders, onChanged: () {
      refreshes++;
      expect(notifications.scheduled, hasLength(1));
    });
    final item = ItemRepository(source).insert(Item(id: 'remote', title: '远端事项',
        status: ItemStatus.todo, priority: Priority.p4,
        source: ItemSource.manual, createdAt: clock.now(),
        updatedAt: clock.now(), dueAt: clock.now().add(const Duration(hours: 1))));
    _project(source, db);
    await sync.afterRemoteChange();
    expect(refreshes, 1);
    ItemRepository(source).update(item.copyWith(status: ItemStatus.done));
    _project(source, db);
    await sync.afterRemoteChange();
    expect(refreshes, 2);
    expect(notifications.cancelled, [notifications.scheduled.single.id]);
    expect(reminders.plans.active(), isEmpty);
  });
}

void _project(SeqDatabase source, SeqDatabase target) => target.transaction(() {
  final operations = source.raw.select('SELECT * FROM sync_operations')
      .map((r) => Operation(opId: r['op_id'] as String,
          deviceId: r['device_id'] as String,
          hlc: Hlc(millis: r['hlc_millis'] as int,
              counter: r['hlc_counter'] as int, deviceId: r['device_id'] as String),
          objectType: r['object_type'] as String,
          objectId: r['object_id'] as String, field: r['field'] as String,
          value: jsonDecode(r['value_json'] as String))).toList();
  SyncInbox(target).storeVerifiedBatch(peerId: 'peer', operations: operations);
  SyncProjector(target).project();
});

class _PermissionGate extends TestNotifications {
  final permission = Completer<bool>();
  int requests = 0;
  @override
  Future<bool> requestPermission() {
    requests++;
    return permission.future;
  }
}
