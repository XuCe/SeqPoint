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
  @override
  bool get mediaSyncEnabled => false;
  _Sync(SeqDatabase db) : super(db: db, root: Directory('unused'), secrets: _Secrets());
  int prepares = 0;
  bool ready = false;
  bool failPrepare = false;
  String? failure;
  @override
  String? get error => failure;
  bool paired = false;
  int syncs = 0;
  int starts = 0;
  bool get observing => hasListeners;
  int? listening;
  @override
  int? get listeningPort => listening;
  @override
  Future<int> startServer({InternetAddress? address, int port = 0, bool automatic = false}) async {
    starts++; listening = 31415; notifyListeners(); return listening!;
  }
  @override
  Future<void> pause() async { listening = null; notifyListeners(); }
  SyncOutcome? round;
  @override
  bool get canSync => paired;
  @override
  List<MemberKeys> get verifiedPeers => paired ? [MemberKeys(deviceId: 'a' * 43,
    signingPublicKey: List.filled(32, 1), exchangePublicKey: List.filled(32, 2),
    tlsFingerprint: 'b' * 64)] : [];
  @override
  SyncOutcome? get lastRound => round;
  @override
  Future<SyncOutcome> syncOnce({required String peerDeviceId,
      required String host, required int port, bool automatic = false}) async {
    syncs++;
    round = const SyncOutcome(pulled: 2, pushed: 3, reclaimed: 0, peers: [],
      pendingObjects: 1, waitingPeers: ['waiting']);
    notifyListeners(); return round!;
  }
  Completer<void>? gate;
  @override
  bool get prepared => ready;
  @override
  bool get hasVault => false;
  @override
  String get status => prepared ? '未配对' : '尚未准备同步';
  @override
  Future<void> prepare(String name) async {
    prepares++;
    await gate?.future;
    ready = true;
    if (failPrepare) { failure = '安全记录读取失败'; throw StateError('private-key-material'); }
    failure = null;
    notifyListeners();
  }
}

void main() {
  testWidgets('最近一轮逐项显示真实等待设备，完成后移除且不猜测原因', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..ready = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    sync.round = const SyncOutcome(pulled: 0, pushed: 0, reclaimed: 0,
      peers: [], waitingPeers: ['known-peer-id', 'unseen-peer-id']);
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('高级同步设置')); await tester.pumpAndSettle();
    expect(find.text('known-peer-id'), findsOneWidget);
    expect(find.text('unseen-peer-id'), findsOneWidget);
    expect(find.textContaining('缺少密钥'), findsNothing);
    expect(find.textContaining('序号缺口'), findsNothing);
    sync.round = const SyncOutcome(pulled: 0, pushed: 0, reclaimed: 0, peers: []);
    sync.notifyListeners(); await tester.pumpAndSettle();
    expect(find.text('known-peer-id'), findsNothing);
    expect(find.text('unseen-peer-id'), findsNothing);
  });
  testWidgets('只手动监听且显示实际端口，离开页解除服务订阅', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('高级同步设置')); await tester.pumpAndSettle();
    expect(sync.starts, 0);
    await tester.tap(find.text('开始局域网监听')); await tester.pumpAndSettle();
    expect(sync.starts, 1); expect(find.text('正在监听端口 31415'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '开始局域网监听')).onPressed, isNull);
    await tester.tap(find.text('暂停同步')); await tester.pumpAndSettle();
    expect(sync.listeningPort, isNull);
    await tester.pumpWidget(const SizedBox()); expect(sync.observing, isFalse);
  });
  testWidgets('从Scope注入服务且恢复期间小屏表单与操作均禁用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: AppScope(noteService: _Capture(),
      notes: _Notes(), items: _Items(), tags: _Tags(), search: _Search(),
      restoring: true, sync: sync, child: const SyncSettingsPage())));
    await tester.tap(find.text('高级同步设置')); await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('正在恢复备份，同步操作暂不可用'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('sync-host')), 200,
      scrollable: find.byType(Scrollable).first);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('sync-host'))).enabled, isFalse);
    for (final button in tester.widgetList<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton))) {
      expect(button.onPressed, isNull);
    }
    expect(sync.prepares, 0); expect(sync.syncs, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('部分准备失败可显式重新读取安全记录，不显示底层异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..failPrepare = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('高级同步设置')); await tester.pumpAndSettle();
    await tester.tap(find.text('准备本机')); await tester.pumpAndSettle();
    expect(sync.prepared, isTrue);
    expect(find.text('private-key-material'), findsNothing);
    expect(find.text('安全记录读取失败'), findsOneWidget);
    sync.failPrepare = false;
    await tester.tap(find.text('重新读取安全记录')); await tester.pumpAndSettle();
    expect(sync.prepares, 2); expect(sync.error, isNull);
  });
  testWidgets('地址验证保留输入，发布不声称对端收到', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync(SeqDatabase.inMemory())..ready = true..paired = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('高级同步设置')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('sync-host')), 'bad address');
    await tester.enterText(find.byKey(const ValueKey('sync-port')), '4000');
    await tester.tap(find.text('连接并同步一次')); await tester.pump();
    expect(sync.syncs, 0); expect(find.text('请输入有效的 IP 地址'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('sync-host')), '192.0.2.1');
    await tester.tap(find.text('连接并同步一次')); await tester.pumpAndSettle();
    expect(sync.syncs, 1);
    expect(find.text('本机已发布 3 条 · 已合入 2 条'), findsOneWidget);
    expect(find.textContaining('待合并记录 1'), findsOneWidget);
    expect(find.text('已同步'), findsNothing);
  });
  testWidgets('用户点击才准备本机，等待期间禁止重复提交', (tester) async {
    final sync = _Sync(SeqDatabase.inMemory());
    addTearDown(() { sync.db.close(); sync.dispose(); });
    sync.gate = Completer<void>();
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('高级同步设置')); await tester.pumpAndSettle();
    expect(sync.prepares, 0);
    await tester.tap(find.text('准备本机')); await tester.pump();
    expect(sync.prepares, 1);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '准备本机')).onPressed, isNull);
    sync.gate!.complete(); await tester.pumpAndSettle();
    expect(find.text('未配对'), findsOneWidget);
    expect(find.text('已同步'), findsNothing);
  });
  testWidgets('没有服务时诚实显示仅本机且通道不可启用', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SyncSettingsPage()));
    expect(find.text('仅本机'), findsOneWidget);
    expect(find.text('此版本尚未接入设备同步服务'), findsOneWidget);
    for (final tile in tester.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
    }
    expect(find.text('已同步'), findsNothing);
  });
}
