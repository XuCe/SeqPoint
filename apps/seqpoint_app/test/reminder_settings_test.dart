import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/reminder_coordinator.dart';
import 'package:seqpoint_app/settings/reminder_settings_page.dart';

import 'notification_support.dart';

void main() {
  testWidgets('65条计划只安排最早64条并明确剩余待安排', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final notifications = TestNotifications();
    final reminders = ReminderCoordinator(db: boot.db,
      notifications: notifications, capacity: 64);
    addTearDown(() {
      reminders.dispose(); boot.dispose(); return notifications.events.close();
    });
    final now = DateTime.now();
    final note = boot.noteService.capture(
      List.generate(65, (i) => '事项$i').join('\n'));
    for (var i = 0; i < 65; i++) {
      final item = boot.noteService.lineToItem(note.id, i);
      boot.items.update(item.copyWith(dueAt: now.add(Duration(hours: i + 1))));
    }
    await reminders.reconcile();
    expect(notifications.scheduled.length, 64);
    expect(notifications.scheduled.first.title, '事项0');
    expect(notifications.scheduled.last.title, '事项63');
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppScope(noteService: boot.noteService,
        notes: boot.notes, items: boot.items, tags: boot.tags, search: boot.search,
        reminders: reminders, child: child!),
      home: const ReminderSettingsPage(),
    ));
    expect(find.text('部分提醒等待安排'), findsOneWidget);
    expect(find.textContaining('另有1条等待安排'), findsOneWidget);
  });

  testWidgets('未检查时不宣称启用，初始化失败显示原因', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final notifications = TestNotifications();
    final reminders = ReminderCoordinator(db: boot.db,
      notifications: notifications);
    addTearDown(() {
      reminders.dispose(); boot.dispose(); return notifications.events.close();
    });
    Widget app({bool failed = false}) => MaterialApp(
      builder: (_, child) => AppScope(noteService: boot.noteService,
        notes: boot.notes, items: boot.items, tags: boot.tags, search: boot.search,
        reminders: failed ? null : reminders,
        notificationError: failed ? '通知初始化失败：插件不可用' : null,
        child: child!), home: const ReminderSettingsPage());
    await tester.pumpWidget(app());
    expect(find.text('正在检查系统通知'), findsOneWidget);
    expect(find.text('期限提醒已启用'), findsNothing);
    await tester.pumpWidget(app(failed: true));
    expect(find.text('通知初始化失败：插件不可用'), findsOneWidget);
  });

  testWidgets('设置显示权限拒绝，重试成功后刷新真实状态', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final notifications = TestNotifications()..granted = false;
    final reminders = ReminderCoordinator(db: boot.db,
      notifications: notifications);
    addTearDown(() {
      reminders.dispose(); boot.dispose(); return notifications.events.close();
    });
    await reminders.reconcile();
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppScope(noteService: boot.noteService,
        notes: boot.notes, items: boot.items, tags: boot.tags, search: boot.search,
        reminders: reminders, child: child!),
      home: const ReminderSettingsPage(),
    ));
    expect(find.text('通知权限未启用'), findsOneWidget);
    notifications.granted = true;
    await tester.tap(find.text('重试'));
    await tester.runAsync(() async {});
    await tester.pump();
    expect(find.text('期限提醒已启用'), findsOneWidget);
    expect(find.text('通知权限未启用'), findsNothing);
  });
}
