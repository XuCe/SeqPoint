import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/mobile/mobile_shell.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/platform/secure_secret_store.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import '../test/notification_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS 原生容器：标签仅显示关联事项并可勾选完成', (tester) async {
    expect(Platform.isIOS, isTrue);
    final notifications = TestNotifications()..granted = false;
    await tester.pumpWidget(SeqApp(notifications: notifications));
    await tester.pumpAndSettle();
    final scope = AppScope.of(tester.element(find.byType(MobileShell)));
    expect(scope.notes.active(), isEmpty, reason: '只允许隔离验收设备');
    final note = scope.noteService.capture('Native tagged item\nNative untagged item');
    addTearDown(() async {
      scope.noteService.trash(note.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle(); await notifications.events.close();
    });
    final item = scope.noteService.lineToItem(note.id, 0);
    scope.noteService.lineToItem(note.id, 1);
    final tag = scope.tags.all().firstWhere((tag) => tag.name == '开发');
    scope.items.setTags(item.id, [tag.id]);
    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    await tester.tap(find.text('标签')); await tester.pumpAndSettle();
    await tester.tap(find.text('开发')); await tester.pumpAndSettle();
    expect(find.text('Native tagged item'), findsOneWidget);
    expect(find.text('Native untagged item'), findsNothing);
    final tile = tester.widget<ItemTile>(find.byType(ItemTile));
    final toggle = find.descendant(of: find.byType(ItemTile),
      matching: find.byWidgetPredicate((w) => w is GestureDetector && w.onTap == tile.onToggle));
    await tester.tap(toggle); await tester.pumpAndSettle();
    expect(scope.items.byId(item.id)!.isDone, isTrue);
  });

  testWidgets('iOS 原生容器：归档和回收站入口恢复自有便签', (tester) async {
    expect(Platform.isIOS, isTrue);
    final notifications = TestNotifications()..granted = false;
    await tester.pumpWidget(SeqApp(notifications: notifications));
    await tester.pumpAndSettle();
    final scope = AppScope.of(tester.element(find.byType(MobileShell)));
    expect(scope.notes.active(), isEmpty, reason: '只允许隔离验收设备');
    const text = 'Native archive trash fixture';
    final note = scope.noteService.capture(text);
    addTearDown(() async {
      scope.noteService.trash(note.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle(); await notifications.events.close();
    });
    scope.noteService.close(note.id);
    await tester.tap(find.text('我的')); await tester.pumpAndSettle();
    await tester.tap(find.text('已归档')); await tester.pumpAndSettle();
    final archive = find.ancestor(of: find.text(text), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: archive, matching: find.text('重新打开')));
    await tester.pumpAndSettle();
    expect(scope.notes.byId(note.id)!.status, NoteStatus.active);
    expect(find.text(text), findsNothing);
    await tester.pageBack(); await tester.pumpAndSettle();
    scope.noteService.trash(note.id);
    await tester.ensureVisible(find.text('回收站')); await tester.pumpAndSettle();
    await tester.tap(find.text('回收站')); await tester.pumpAndSettle();
    final trash = find.ancestor(of: find.text(text), matching: find.byType(ListTile));
    await tester.tap(find.descendant(of: trash, matching: find.text('恢复')));
    await tester.pumpAndSettle();
    expect(scope.notes.byId(note.id)!.deletedAt, isNull);
    expect(find.text(text), findsNothing);
    await tester.pageBack(); await tester.pumpAndSettle();
    await tester.tap(find.text('便签').last); await tester.pumpAndSettle();
    expect(find.textContaining(text), findsWidgets);
  });

  testWidgets('iOS 原生 Keychain：新UUID写读覆盖与精确清理', (tester) async {
    expect(Platform.isIOS, isTrue);
    const store = SecureSecretStore();
    final key = 'seqpoint.acceptance.${newId()}';
    expect(await store.containsKey(key), isFalse);
    expect(await store.read(key), isNull);
    try {
      await store.write(key, 'fixed-test-value');
      expect(await const SecureSecretStore().read(key), 'fixed-test-value');
      expect(await store.containsKey(key), isTrue);
      await store.write(key, 'fixed-overwrite');
      expect(await store.read(key), 'fixed-overwrite');
      await store.delete(key);
      expect(await store.read(key), isNull);
    } finally {
      await store.delete(key);
      expect(await store.read(key), isNull);
      expect(await store.containsKey(key), isFalse);
    }
  });

  testWidgets('iOS 原生容器：全文搜索命中后打开测试便签', (tester) async {
    expect(Platform.isIOS, isTrue);
    final notifications = TestNotifications()..granted = false;
    await tester.pumpWidget(SeqApp(notifications: notifications));
    await tester.pumpAndSettle();
    final scope = AppScope.of(tester.element(find.byType(MobileShell)));
    expect(scope.notes.active(), isEmpty, reason: '只允许隔离验收设备');
    const text = 'Native indexed search fixture';
    final note = scope.noteService.capture(text);
    addTearDown(() async {
      scope.noteService.trash(note.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle(); await notifications.events.close();
    });
    expect((await scope.search.query('indexed')).map((hit) => hit.objectId),
      contains(note.id), reason: '先确认实际SQLite索引，再验证搜索界面');
    await tester.tap(find.text('便签')); await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'indexed');
    await tester.pumpAndSettle();
    final result = find.descendant(of: find.byType(ListTile),
      matching: find.textContaining(text, findRichText: true));
    expect(result, findsWidgets);
    await tester.tap(result.first); await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsOneWidget);
    expect(scope.notes.byId(note.id)!.rawContent, text);
  });

  testWidgets('iOS 原生容器：稍后按钮保留截止、持久化本机提醒', (tester) async {
    expect(Platform.isIOS, isTrue);
    final notifications = TestNotifications()..granted = false;
    await tester.pumpWidget(SeqApp(notifications: notifications));
    await tester.pumpAndSettle();
    final scope = AppScope.of(tester.element(find.byType(MobileShell)));
    expect(scope.notes.active(), isEmpty, reason: '只允许隔离验收设备');
    final note = scope.noteService.capture('Native snooze fixture');
    addTearDown(() async {
      scope.noteService.trash(note.id);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle(); await notifications.events.close();
    });
    final item = scope.noteService.lineToItem(note.id, 0);
    final due = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    scope.items.update(item.copyWith(dueAt: due));
    await tester.tap(find.text('便签')); await tester.pumpAndSettle();
    await tester.tap(find.text('今日')); await tester.pumpAndSettle();
    final before = DateTime.now().toUtc();
    await tester.tap(find.text('1 小时后')); await tester.pumpAndSettle();
    final after = DateTime.now().toUtc();
    final reminder = ReminderRepository(scope.database!).forItem(item.id).single;
    expect(reminder.feedback, ReminderFeedback.snoozed);
    expect(reminder.triggerAt!.isBefore(before.add(const Duration(hours: 1))), isFalse);
    expect(reminder.triggerAt!.isAfter(after.add(const Duration(hours: 1))), isFalse);
    expect(scope.items.byId(item.id)!.dueAt, due);
    expect(find.textContaining('仅本机'), findsOneWidget);
    final directory = await getApplicationSupportDirectory();
    final reopened = SeqDatabase.open('${directory.path}/seqpoint.db')..migrate();
    try { expect(ReminderRepository(reopened).forItem(item.id).single.triggerAt, reminder.triggerAt); }
    finally { reopened.close(); }
  });

  testWidgets('iOS 原生容器：界面新建便签及 SQLite 跨连接持久化', (tester) async {
    expect(Platform.isIOS, isTrue);
    final notifications = TestNotifications()..granted = false;
    await tester.pumpWidget(SeqApp(notifications: notifications));
    await tester.pumpAndSettle();
    final scope = AppScope.of(tester.element(find.byType(MobileShell)));
    expect(scope.notes.active(), isEmpty, reason: '只允许新建的隔离验收设备');
    String? ownId;
    addTearDown(() async {
      if (ownId != null) scope.noteService.trash(ownId);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await notifications.events.close();
    });
    await tester.tap(find.byTooltip('记一笔')); await tester.pumpAndSettle();
    await tester.tap(find.text('快速记录')); await tester.pumpAndSettle();
    const text = 'SeqPoint integration fixture';
    await tester.enterText(find.byType(TextField), text); await tester.pump();
    await tester.tap(find.text('保存')); await tester.pumpAndSettle();
    final note = scope.notes.active().single; ownId = note.id;
    expect(note.rawContent, text);
    expect(find.textContaining(text), findsWidgets);
    final directory = await getApplicationSupportDirectory();
    final reopened = SeqDatabase.open('${directory.path}/seqpoint.db')..migrate();
    try { expect(NoteRepository(reopened).byId(note.id)!.rawContent, text); }
    finally { reopened.close(); }
  });
}
