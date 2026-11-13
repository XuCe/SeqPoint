import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/app/seq_app.dart';
import 'package:seqpoint_app/desktop/panel/main_panel.dart';
import 'package:seqpoint_app/mobile/note_detail_page.dart';
import 'package:seqpoint_app/platform/desktop_notifications.dart';
import 'package:seqpoint_app/settings/sync_settings_page.dart';
import 'package:seqpoint_app/shared/item_tile.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import '../test/note_editor_test_support.dart';

/// Linux 桌面真实引擎验收：真实 SQLite、通知、同步引擎与插件。
///
/// 只允许在隔离数据目录中运行：
///   XDG_DATA_HOME=$(mktemp -d) flutter test \
///     integration_test/linux_desktop_acceptance_test.dart -d linux
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 系统钥匙串不随 XDG_DATA_HOME 隔离：只在本应用没有任何安全存储数据时运行，
  // 结束后清除本次写入的身份、同步空间与 AI 配置。
  const keyring = FlutterSecureStorage();
  var keyringIsolated = false;
  setUpAll(() async {
    if (!Platform.isLinux) return;
    expect((await keyring.readAll()).keys, isEmpty, reason: '钥匙串中已有序点数据，拒绝在非隔离环境运行');
    keyringIsolated = true;
  });
  tearDownAll(() async {
    // setUpAll 失败时 tearDownAll 仍会执行，只清理本次确认过为空的钥匙串。
    if (keyringIsolated) await keyring.deleteAll();
  });

  Future<AppScope> launch(WidgetTester tester) async {
    final support = await getApplicationSupportDirectory();
    expect(File('${support.path}/seqpoint.db').existsSync(), isFalse,
        reason: '只允许在隔离的 XDG_DATA_HOME 中运行');
    final notifications = DesktopNotificationService();
    await notifications.init();
    await tester.pumpWidget(SeqApp(title: '序点 验收', notifications: notifications));
    await _settle(tester);
    expect(find.byType(MainPanel), findsOneWidget);
    return AppScope.of(tester.element(find.byType(MainPanel)));
  }

  testWidgets('Linux 主面板：记一笔、打开、转事项、完成、搜索、揭走、回收站与设置', (tester) async {
    final scope = await launch(tester);
    expect(find.text('今天没有待办了'), findsOneWidget);

    // 记一笔并保存，落到便签墙。
    await tester.tap(find.text('记一笔'));
    await _settle(tester);
    await typeNote(tester, 'Linux 验收 牛奶\nLinux 验收 周报');
    await _settle(tester);
    await tester.tap(find.text('保存'));
    await _settle(tester);
    expect(scope.notes.active(), hasLength(1));
    final noteId = scope.notes.active().single.id;
    expect(find.textContaining('Linux 验收 牛奶'), findsWidgets);

    // 便签墙点击卡片必须能打开便签（Linux 没有独立便签窗，在右侧面板打开）。
    await tester.tap(find.textContaining('Linux 验收 牛奶').first);
    await _settle(tester);
    expect(find.byType(NoteDetailPage), findsOneWidget, reason: '便签墙卡片点击后没有任何反应');
    final inPanel = find.descendant(of: find.byType(NoteDetailPage),
        matching: find.text('Linux 验收 周报'));

    // 在详情里把第二行转为事项，再勾选完成。
    await tester.tap(inPanel);
    await _settle(tester);
    final items = scope.items.byNote(noteId);
    expect(items, hasLength(1));
    expect(items.single.title, 'Linux 验收 周报');
    await tester.tap(inPanel);
    await _settle(tester);
    expect(scope.items.byId(items.single.id)!.isDone, isTrue);
    await tester.tap(find.byTooltip('关闭'));
    await _settle(tester);
    expect(find.byType(NoteDetailPage), findsNothing);

    // 事项：默认待办为空，切到已完成可见。
    await tester.tap(find.text('事项'));
    await _settle(tester);
    expect(find.text('没有待办事项。'), findsOneWidget);
    await tester.tap(find.text('已完成'));
    await _settle(tester);
    expect(find.byType(ItemTile), findsOneWidget);

    // ⌘K 面板全文搜索命中便签并打开。
    await tester.tap(find.text('搜索'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('palette-input')), '牛奶');
    await _settle(tester);
    final hits = find.descendant(of: find.byKey(const ValueKey('command-palette')),
        matching: find.textContaining('牛奶'));
    expect(hits, findsWidgets);
    await tester.tap(hits.first);
    await _settle(tester);
    expect(find.byType(NoteDetailPage), findsOneWidget);

    // 揭走 → 已关闭可见 → 重新打开。
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settle(tester);
    await tester.tap(find.text('揭走（办完收起）'));
    await _settle(tester);
    expect(scope.notes.active(), isEmpty);
    await tester.tap(find.text('已关闭'));
    await _settle(tester);
    expect(find.textContaining('Linux 验收 牛奶'), findsOneWidget);
    await tester.tap(find.text('重新打开'));
    await _settle(tester);
    expect(scope.notes.active(), hasLength(1));

    // 删除 → 回收站 → 恢复。
    scope.noteService.trash(noteId);
    await tester.tap(find.text('回收站'));
    await _settle(tester);
    expect(find.textContaining('Linux 验收 牛奶'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    await _settle(tester);
    expect(scope.notes.active(), hasLength(1));

    // 设置左栏逐个切换分类，右侧直接显示内容，不抛异常。
    await tester.tap(find.text('设置'));
    await _settle(tester);
    for (final title in ['AI 整理', '提醒', '快捷键', '设备与同步', '备份与恢复', '关于与更新']) {
      await tester.tap(find.text(title).first);
      await _settle(tester, seconds: 3);
      expect(tester.takeException(), isNull, reason: '$title 页面抛出异常');
      expect(find.text(title), findsNWidgets(2), reason: '$title 未在右侧显示');
    }

    // 卸载应用，释放数据库与同步引擎，供下一个用例模拟重启。
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, seconds: 2);
  }, skip: !Platform.isLinux);

  testWidgets('Linux 重启后数据仍在，备份快照、安全存储与系统通知可用', (tester) async {
    final support = await getApplicationSupportDirectory();
    expect(File('${support.path}/seqpoint.db').existsSync(), isTrue,
        reason: '依赖上一个用例写入的数据');
    final notifications = DesktopNotificationService();
    await notifications.init();
    await tester.pumpWidget(SeqApp(title: '序点 验收', notifications: notifications));
    await _settle(tester);
    final scope = AppScope.of(tester.element(find.byType(MainPanel)));
    expect(scope.notes.active().single.rawContent, contains('Linux 验收 牛奶'));
    expect(scope.items.listItems(status: null), hasLength(1));

    // 备份：真实 SQLite 的 VACUUM INTO 生成快照，并能通过只读校验。
    await tester.tap(find.text('设置'));
    await _settle(tester);
    await tester.tap(find.text('备份与恢复').first);
    await _settle(tester);
    await tester.tap(find.text('立即备份'));
    await _settle(tester, seconds: 2);
    expect(find.textContaining('已生成未加密本机快照'), findsOneWidget);
    final snapshots = Directory('${support.path}/snapshots').listSync().whereType<File>().toList();
    expect(snapshots, hasLength(1));
    expect(() => SnapshotServiceProbe.validate(snapshots.single), returnsNormally);

    // AI 设置：密钥写入系统安全存储（libsecret），再清除。
    await tester.tap(find.text('AI 整理').first);
    await _settle(tester, seconds: 2);
    expect(find.text('无法读取AI设置'), findsNothing);
    await tester.tap(find.text('云端模型'));
    await _settle(tester);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://linux-acceptance.invalid/v1');
    await tester.enterText(fields.at(1), 'acceptance-model');
    await tester.enterText(fields.at(2), 'acceptance-only-placeholder');
    await _settle(tester);
    await tester.tap(find.text('保存配置'));
    await _settle(tester, seconds: 2);
    if (find.text('启用并保存').evaluate().isNotEmpty) {
      await tester.tap(find.text('启用并保存'));
      await _settle(tester, seconds: 2);
    }
    expect(find.text('无法保存AI配置，请检查地址、模型和安全存储'), findsNothing);
    expect(find.text('已保存服务的密钥：已配置'), findsOneWidget);
    await tester.tap(find.text('清除已保存密钥'));
    await _settle(tester, seconds: 2);
    expect(find.text('已保存服务的密钥：未配置'), findsOneWidget);

    // 系统通知：到期提醒立即投递，未来提醒由 Linux 定时器补齐。
    await notifications.schedule(NotificationRequest(id: 990001, title: '序点验收',
        body: '到期提醒', fireAt: DateTime.now().toUtc(), itemId: 'acceptance', actions: const []));
    await notifications.schedule(NotificationRequest(id: 990002, title: '序点验收',
        body: '一秒后提醒', fireAt: DateTime.now().toUtc().add(const Duration(seconds: 1)),
        itemId: 'acceptance', actions: const [NotificationAction.done, NotificationAction.snooze]));
    final linux = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<LinuxFlutterLocalNotificationsPlugin>()!;
    expect((await linux.getSystemIdMap()).keys, contains(990001));
    expect((await linux.getSystemIdMap()).keys, isNot(contains(990002)));
    await _settle(tester, seconds: 2);
    expect((await linux.getSystemIdMap()).keys, contains(990002));
    await notifications.cancel(990001);
    await notifications.cancel(990002);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, seconds: 2);
    await notifications.dispose();
  }, skip: !Platform.isLinux);

  testWidgets('Linux 同步：准备本机身份、创建同步空间并打开局域网配对', (tester) async {
    await tester.pumpWidget(const SeqApp(title: '序点 验收'));
    await _settle(tester);
    final scope = AppScope.of(tester.element(find.byType(MainPanel)));
    final sync = scope.sync!;
    await tester.tap(find.text('设置'));
    await _settle(tester);
    await tester.tap(find.text('设备与同步').first);
    await _settle(tester, seconds: 2);
    await tester.tap(find.text('高级同步设置'));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('sync-device-name')), 'Linux 验收机');
    await tester.tap(find.text('准备本机'));
    await _waitFor(tester, () => sync.prepared && !sync.busy);
    expect(sync.error, isNull);
    await _reveal(tester, find.text('创建同步空间'));
    await tester.tap(find.text('创建同步空间'));
    await _waitFor(tester, () => sync.hasVault && !sync.busy);
    expect(sync.error, isNull);

    expect(sync.hasMembershipConflict, isFalse);
    expect(sync.requiresNewIdentity, isFalse);

    // 设置页是惰性列表，切到别的分类再回来，添加设备在首屏的设备卡里。
    await tester.tap(find.text('AI 整理').first);
    await _settle(tester, seconds: 2);
    await tester.tap(find.text('设备与同步').first);
    await _settle(tester, seconds: 2);
    await tester.tap(find.text('添加设备'));
    await _settle(tester, seconds: 3);
    expect(tester.takeException(), isNull);
    await _back(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, seconds: 3);
  }, skip: !Platform.isLinux);
}

Future<void> _waitFor(WidgetTester tester, bool Function() done, {int seconds = 30}) async {
  for (var i = 0; i < seconds * 10 && !done(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(done(), isTrue, reason: '$seconds 秒内未完成');
}

/// 只读校验快照，避免测试依赖应用内部的恢复流程。
abstract final class SnapshotServiceProbe {
  static int validate(File file) => SnapshotService.validate(file);
}

/// 应用为中文本地化，返回按钮的提示是“返回”而不是 pageBack() 查找的“Back”。
Future<void> _back(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

/// 真实应用里可能有持续动画（同步状态、加载圈），不能无限等待 settle。
Future<void> _settle(WidgetTester tester, {int seconds = 1}) async {
  for (var i = 0; i < seconds * 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 设置页是惰性列表，高级设置折叠后子项不会构建：必要时展开并向下滚动。
Future<void> _reveal(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 20 && target.evaluate().isEmpty; i++) {
    final advanced = find.text('高级同步设置');
    if (advanced.evaluate().isNotEmpty && find.text('准备本机').evaluate().isEmpty &&
        find.textContaining('安全身份已准备').evaluate().isEmpty) {
      await tester.tap(advanced);
    } else {
      await tester.drag(find.descendant(of: find.byType(SyncSettingsPage),
          matching: find.byType(Scrollable)).first, const Offset(0, -200));
    }
    await _settle(tester);
  }
  await tester.ensureVisible(target);
  await _settle(tester);
}
