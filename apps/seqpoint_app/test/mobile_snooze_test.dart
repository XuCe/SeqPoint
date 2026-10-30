import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/reminder_coordinator.dart';
import 'package:seqpoint_app/mobile/today_page.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'notification_support.dart';

void main() {
  testWidgets('恢复时不接受稍后，只读失败后可重试且不遗留写入', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final clock = FakeClock(DateTime.now().toUtc());
    final notifications = TestNotifications();
    addTearDown(() { boot.dispose(); return notifications.events.close(); });
    final note = boot.noteService.capture('稍后恢复保护');
    final item = boot.noteService.lineToItem(note.id, 0);
    boot.items.update(item.copyWith(dueAt: clock.now().subtract(const Duration(minutes: 5))));
    final coordinator = ReminderCoordinator(db: boot.db,
      notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    Widget page(bool restoring) => MaterialApp(home: AppScope(
      noteService: boot.noteService, notes: boot.notes, items: boot.items,
      tags: boot.tags, search: boot.search, database: boot.db, restoring: restoring,
      reminders: coordinator, child: const Scaffold(body: TodayPage())));
    await tester.pumpWidget(page(true)); await tester.pumpAndSettle();
    await tester.tap(find.text('1 小时后'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(ReminderRepository(boot.db).forItem(item.id), isEmpty);
    await tester.pumpWidget(page(false)); await tester.pumpAndSettle();
    boot.db.raw.execute('PRAGMA query_only = ON');
    await tester.tap(find.text('1 小时后')); await tester.pumpAndSettle();
    expect(find.text('稍后提醒失败，请重试。'), findsOneWidget);
    expect(ReminderRepository(boot.db).forItem(item.id), isEmpty);
    boot.db.raw.execute('PRAGMA query_only = OFF');
    await tester.tap(find.text('1 小时后')); await tester.pumpAndSettle();
    expect(ReminderRepository(boot.db).forItem(item.id), hasLength(1));
    expect(find.text('已稍后 1 小时提醒（仅本机）'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('移动端一小时后只延后本机提醒，保留截止并撤销旧通知', (tester) async {
    final boot = await Bootstrap.run(dbPath: ':memory:');
    final clock = FakeClock(DateTime.now().toUtc());
    final notifications = TestNotifications();
    addTearDown(() { boot.dispose(); return notifications.events.close(); });
    final note = boot.noteService.capture('稍后提醒验收');
    final item = boot.noteService.lineToItem(note.id, 0);
    final due = clock.now().subtract(const Duration(minutes: 5));
    boot.items.update(item.copyWith(dueAt: due));
    final coordinator = ReminderCoordinator(db: boot.db,
      notifications: notifications, clock: clock);
    addTearDown(coordinator.dispose);
    await coordinator.reconcile();
    final oldId = notifications.scheduled.single.id;
    await tester.pumpWidget(MaterialApp(home: AppScope(
      noteService: boot.noteService, notes: boot.notes, items: boot.items,
      tags: boot.tags, search: boot.search, database: boot.db,
      reminders: coordinator, child: const Scaffold(body: TodayPage()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 小时后')); await tester.pumpAndSettle();
    final records = ReminderRepository(boot.db).forItem(item.id);
    expect(records, hasLength(1));
    expect(records.single.feedback, ReminderFeedback.snoozed);
    expect(records.single.triggerAt, clock.now().add(const Duration(hours: 1)));
    expect(boot.items.byId(item.id)!.dueAt, due);
    expect(notifications.cancelled, contains(oldId));
    expect(notifications.scheduled.last.fireAt, records.single.triggerAt);
    expect(find.textContaining('仅本机'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
