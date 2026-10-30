import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/shared/item_editor_page.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import 'notification_support.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  testWidgets('主引擎装配提醒，便签构造器禁用通知且卸载后停止', (tester) async {
    final root = (await tester.runAsync(() =>
      Directory.systemTemp.createTemp('seqpoint-reminder-app-')))!;
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPathProvider(root.path);
    final notifications = TestNotifications()..launchItemId = 'missing-at-startup';
    Bootstrap? boot;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      boot?.dispose();
      PathProviderPlatform.instance = previous;
      await notifications.events.close();
      await tester.runAsync(() => root.delete(recursive: true));
    });
    await tester.runAsync(() async {
      await tester.pumpWidget(SeqApp(notifications: notifications));
      boot = await tester.widget<FutureBuilder<Bootstrap>>(
        find.byType(FutureBuilder<Bootstrap>)).future!;
    });
    await tester.pumpAndSettle();
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(find.text('事项已完成或删除'), findsOneWidget);
    final coordinator = tester.widget<AppScope>(find.byType(AppScope)).reminders;
    expect(coordinator, isNotNull);
    final note = boot!.noteService.capture('明天下午三点开会');
    final item = boot!.noteService.lineToItem(note.id, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() async {});
    await tester.pump();
    expect(notifications.scheduled.single.title, contains('开会'));
    notifications.events.add((itemId: item.id, action: NotificationAction.open));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(find.byType(ItemEditorPage), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '当前未保存草稿');
    notifications.events.add((itemId: item.id, action: NotificationAction.open));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(find.byType(ItemEditorPage), findsOneWidget);
    expect(find.text('当前未保存草稿'), findsOneWidget);
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    boot!.noteService.toggleItem(item.id);
    notifications.events.add((itemId: item.id, action: NotificationAction.open));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(find.byType(ItemEditorPage), findsNothing);
    expect(find.text('事项已完成或删除'), findsOneWidget);
    expect(const SeqApp.sticky(noteId: 'test').notifications, isNull);
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(coordinator!.reconcile);
    expect(notifications.scheduled.length, 1);
  });
}
