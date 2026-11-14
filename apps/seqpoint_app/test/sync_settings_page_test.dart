import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/sync_settings_page.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}
class _Notes extends Fake implements NoteRepository {}
class _Items extends Fake implements ItemRepository {}
class _Tags extends Fake implements TagRepository {}
class _Search extends Fake implements SearchService {}
class _Capture extends Fake implements NoteService {}

class _Sync extends AppSyncService {
  _Sync(SeqDatabase db) : super(db: db, root: Directory('unused'), secrets: _Secrets());
  @override
  bool get mediaSyncEnabled => false;
  bool ready = false, paired = false, failPrepare = false, pending = false;
  String? origin, failure;
  int prepares = 0, syncs = 0, retries = 0, leaves = 0;
  bool otherVault = false;
  final links = <String>[];
  final leaveFlags = <bool>[];
  @override
  Future<void> leaveVault() async { leaves++; paired = false; otherVault = false; notifyListeners(); }
  Completer<void>? gate;
  Object? linkError;
  @override
  String? get error => failure;
  @override
  bool get prepared => ready;
  @override
  bool get hasVault => paired;
  @override
  bool get canSync => paired;
  @override
  String get status => prepared ? '等待手动同步' : '尚未准备同步';
  @override
  Object? get membershipVersion => Object();
  @override
  List<MemberKeys> get verifiedPeers => paired ? [MemberKeys(deviceId: 'a' * 43,
    signingPublicKey: List.filled(32, 1), exchangePublicKey: List.filled(32, 2),
    tlsFingerprint: 'b' * 64)] : [];
  @override
  Future<String?> gatewayOrigin() async => origin;
  @override
  Future<bool> hasPendingEnrollment() async => pending;
  @override
  Future<void> retryEnrollment() async { retries++; pending = false; origin = 'http://nas.local:8385'; notifyListeners(); }
  @override
  Future<void> connectWithLink(String link, {void Function(String step)? onProgress,
      bool Function()? cancelled, bool leaveCurrentVault = false}) async {
    links.add(link);
    leaveFlags.add(leaveCurrentVault);
    if (otherVault && !leaveCurrentVault) {
      throw const VaultSwitchRequired(['原空间保存了旧版的节点地址 relay.example.com']);
    }
    onProgress?.call('正在连接同步服务器');
    await gate?.future;
    if (linkError case final error?) throw error;
    paired = true; origin = 'http://nas.local:8385'; notifyListeners();
  }
  @override
  Future<SyncOutcome> syncRelay({bool automatic = false}) async {
    syncs++;
    return const SyncOutcome(pulled: 2, pushed: 3, reclaimed: 0, peers: []);
  }
  @override
  Future<void> prepare(String name) async {
    prepares++;
    ready = true;
    if (failPrepare) { failure = '安全记录读取失败'; throw StateError('private-key-material'); }
    failure = null;
    notifyListeners();
  }
}

Future<void> _mount(WidgetTester tester, _Sync sync, {Size size = const Size(900, 1500)}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
  await tester.pumpAndSettle();
}

const _retired = ['局域网直连', '局域网自动双向同步', '云中转', '节点地址（HTTP / HTTPS）',
  '复制节点配置', '自建 Syncthing 节点', '手动配对设备', '手动连接', '开始局域网监听', '高级同步设置'];

void main() {
  testWidgets('未连接时只有一个粘贴框，旧的同步方式全部不再出现', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory());
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    expect(find.text('连接同步服务器'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-link')), findsOneWidget);
    for (final text in _retired) {
      expect(find.text(text), findsNothing, reason: text);
    }
    expect(find.text('添加设备'), findsNothing);
    expect(find.text('已同步'), findsNothing);
  });

  testWidgets('粘贴的链接交给统一入口，连接后显示设备和添加入口', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory());
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.enterText(find.byKey(const ValueKey('sync-link')),
        '  http://nas.local:8385/join#${'k' * 43}  ');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    expect(sync.links, ['http://nas.local:8385/join#${'k' * 43}']);
    expect(find.text('已连接同步服务器'), findsOneWidget);
    expect(find.textContaining('nas.local:8385'), findsOneWidget);
    expect(find.text('添加设备'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-link')), findsNothing);
    expect(sync.syncs, 1);
  });

  testWidgets('链接错误显示可读原因并保留输入，等待期间不能重复提交', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())
      ..gate = Completer<void>()
      ..linkError = const FormatException('加入链接已过期或已被使用，请在已连接的设备上重新生成');
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.enterText(find.byKey(const ValueKey('sync-link')), 'http://nas.local:8385/join#x');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pump();
    expect(find.text('正在连接同步服务器'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '连接中…')).onPressed, isNull);
    sync.gate!.complete();
    await tester.pumpAndSettle();
    expect(sync.links, hasLength(1));
    expect(find.text('加入链接已过期或已被使用，请在已连接的设备上重新生成'), findsOneWidget);
    expect(find.text('http://nas.local:8385/join#x'), findsOneWidget);
    expect(find.text('已连接同步服务器'), findsNothing);
  });

  testWidgets('已在另一个空间时说明原因，确认后退出原空间再加入', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true..otherVault = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.enterText(find.byKey(const ValueKey('sync-link')), 'http://nas.local:8385/join#${'k' * 43}');
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    expect(find.text('换到新的同步空间？'), findsOneWidget);
    expect(find.textContaining('relay.example.com'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sync.leaveFlags, [false]);
    expect(find.text('已连接同步服务器'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, '连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出原空间并加入'));
    await tester.pumpAndSettle();
    expect(sync.leaveFlags, [false, false, true]);
    expect(find.text('已连接同步服务器'), findsOneWidget);
  });

  testWidgets('任何时候都能退出同步空间，确认后才执行', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('sync-leave')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const ValueKey('sync-leave')));
    await tester.pumpAndSettle();
    expect(find.text('退出同步空间？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sync.leaves, 0);
    await tester.tap(find.byKey(const ValueKey('sync-leave')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '退出'));
    await tester.pumpAndSettle();
    expect(sync.leaves, 1);
    expect(find.byKey(const ValueKey('sync-leave')), findsNothing);
    expect(find.byKey(const ValueKey('sync-link')), findsOneWidget);
  });

  testWidgets('登记中断后显示重试，而不是重新要链接', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true..pending = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    expect(find.text('还差一步：连接同步服务器'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-link')), findsNothing);
    await tester.tap(find.text('重试连接'));
    await tester.pumpAndSettle();
    expect(sync.retries, 1);
    expect(find.text('已连接同步服务器'), findsOneWidget);
  });

  testWidgets('立即同步只走服务器，结果不声称对端已收到', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true
      ..origin = 'http://nas.local:8385';
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.scrollUntilVisible(find.text('立即同步'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(sync.syncs, 1);
    expect(find.text('已同步'), findsNothing);
    for (final text in _retired) {
      expect(find.text(text), findsNothing, reason: text);
    }
  });

  testWidgets('从Scope注入服务且恢复期间小屏所有操作均禁用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true
      ..origin = 'http://nas.local:8385';
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: AppScope(noteService: _Capture(),
      notes: _Notes(), items: _Items(), tags: _Tags(), search: _Search(),
      restoring: true, sync: sync, child: const SyncSettingsPage())));
    await tester.pumpAndSettle();
    expect(find.text('正在恢复备份，同步操作暂不可用'), findsOneWidget);
    for (final button in tester.widgetList<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton))) {
      expect(button.onPressed, isNull);
    }
    for (final tile in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(tile.onChanged, isNull);
    }
    expect(sync.prepares, 0); expect(sync.syncs, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('安全记录读取失败可显式重新读取，不显示底层异常', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..failure = '安全记录读取失败';
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    expect(find.text('安全记录读取失败'), findsOneWidget);
    await tester.tap(find.text('重新读取安全记录'));
    await tester.pumpAndSettle();
    expect(sync.prepares, 1); expect(sync.error, isNull);
    expect(find.text('private-key-material'), findsNothing);
  });

  testWidgets('没有服务时诚实显示仅本机', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SyncSettingsPage()));
    expect(find.text('仅本机'), findsOneWidget);
    expect(find.text('此版本尚未接入设备同步服务'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('已同步'), findsNothing);
  });
}
