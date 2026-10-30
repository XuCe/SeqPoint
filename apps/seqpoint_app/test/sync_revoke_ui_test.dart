import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/app_scope.dart';
import 'package:seqpoint_app/settings/sync_settings_page.dart';
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
  _Sync() : super(db: SeqDatabase.inMemory(), root: Directory('unused'), secrets: _Secrets());
  final target = MemberKeys(deviceId: 'a' * 43, signingPublicKey: List.filled(32, 1),
    exchangePublicKey: List.filled(32, 2), tlsFingerprint: 'b' * 64);
  Object? version = Object(), receivedVersion;
  MemberKeys? receivedPeer;
  int calls = 0;
  bool externalBusy = false, recovering = false, conflicted = false;
  bool fail = false;
  String? failure;
  @override
  String? get error => failure;
  @override
  bool get busy => externalBusy;
  @override
  bool get requiresNewIdentity => recovering;
  @override
  bool get hasMembershipConflict => conflicted;
  @override
  bool get prepared => true;
  @override
  bool get hasVault => true;
  @override
  bool get canSync => false;
  @override
  String get status => '等待手动同步';
  @override
  Object? get membershipVersion => version;
  @override
  List<MemberKeys> get verifiedPeers => [target];
  @override
  Future<void> revokePeer(MemberKeys expectedPeer, {required Object expectedVersion}) async {
    calls++; receivedPeer = expectedPeer; receivedVersion = expectedVersion;
    if (fail) { failure = '撤销失败，安全记录未保存'; throw StateError('private-signing-material'); }
  }
}

Future<void> _mount(WidgetTester tester, _Sync sync, {bool restoring = false}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1500));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = SyncSettingsPage(service: sync);
  await tester.pumpWidget(MaterialApp(home: restoring ? AppScope(noteService: _Capture(),
    notes: _Notes(), items: _Items(), tags: _Tags(), search: _Search(), restoring: true,
    child: page) : page));
  await _showDevices(tester);
}

Future<void> _showDevices(WidgetTester tester) async {
  if (find.text('恢复同步').evaluate().isEmpty) {
    await tester.scrollUntilVisible(find.text('高级同步设置'), 200,
      scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(milliseconds: 300));
    if (find.text('撤销').evaluate().isEmpty) {
      await tester.tap(find.text('高级同步设置'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }
  await tester.scrollUntilVisible(find.text('撤销'), 200,
    scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(find.text('撤销')), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _showMessage(WidgetTester tester, String message) async {
  await tester.scrollUntilVisible(find.text(message), -200,
    scrollable: find.byType(Scrollable).first);
  await tester.pump();
}

void main() {
  testWidgets('大字号暗色小屏及横屏确认框可滚动且取消安全', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(2), disableAnimations: true), child: child!),
      home: SyncSettingsPage(service: sync)));
    await _showDevices(tester);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(667, 375)); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(sync.calls, 0);
  });
  testWidgets('App恢复忙期间设备列表可见但撤销入口禁用', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync, restoring: true);
    expect(find.text(sync.target.deviceId), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '撤销')).onPressed, isNull);
    expect(sync.calls, 0);
  });
  testWidgets('服务拒绝撤销时展示安全错误，不报成功或泄露底层材料', (tester) async {
    final sync = _Sync()..fail = true;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    await tester.tap(find.text('确认撤销')); await tester.pumpAndSettle();
    expect(sync.calls, 1);
    await _showMessage(tester, '撤销失败，安全记录未保存');
    expect(find.text('撤销失败，安全记录未保存'), findsOneWidget);
    expect(find.textContaining('private-signing-material'), findsNothing);
    expect(find.text('设备已撤销'), findsNothing);
  });
  testWidgets('恢复身份、成员冲突、服务忙或无授权版本时不能撤销', (tester) async {
    for (final mode in ['recovery', 'conflict', 'busy', 'no-version']) {
      final sync = _Sync();
      addTearDown(() { sync.db.close(); sync.dispose(); });
      sync.recovering = mode == 'recovery'; sync.conflicted = mode == 'conflict';
      sync.externalBusy = mode == 'busy';
      if (mode == 'no-version') sync.version = null;
      await _mount(tester, sync);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '撤销')).onPressed, isNull);
      expect(sync.calls, 0);
    }
  });
  testWidgets('确认期间进入冲突即拒绝操作并显示状态变化', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    sync.conflicted = true; sync.notifyListeners(); await tester.pump();
    await tester.tap(find.text('确认撤销')); await tester.pumpAndSettle();
    expect(sync.calls, 0);
    await _showMessage(tester, '成员状态已变化，请重新核对后再撤销');
    expect(find.text('成员状态已变化，请重新核对后再撤销'), findsOneWidget);
  });
  testWidgets('明确确认后仅提交捕获的完整peer和版本', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    final captured = sync.version;
    await _mount(tester, sync);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    expect(sync.calls, 0);
    await tester.tap(find.text('确认撤销')); await tester.pumpAndSettle();
    expect(sync.calls, 1);
    expect(sync.receivedPeer, same(sync.target));
    expect(sync.receivedVersion, same(captured));
    expect(find.text('设备已撤销'), findsOneWidget);
  });
  testWidgets('确认框打开后版本变化拒绝旧确认，不刷新版本偷偷重试', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    sync.version = Object(); sync.notifyListeners(); await tester.pump();
    await tester.tap(find.text('确认撤销')); await tester.pumpAndSettle();
    expect(sync.calls, 0);
    await _showMessage(tester, '成员状态已变化，请重新核对后再撤销');
    expect(find.text('成员状态已变化，请重新核对后再撤销'), findsOneWidget);
  });
  testWidgets('设备撤销完整展示ID，点击后取消不提交', (tester) async {
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await _mount(tester, sync);
    expect(find.text(sync.target.deviceId), findsOneWidget);
    await tester.tap(find.text('撤销')); await tester.pumpAndSettle();
    expect(find.text('撤销此设备？'), findsOneWidget);
    expect(find.textContaining('不会远程删除'), findsOneWidget);
    await tester.tap(find.text('取消')); await tester.pumpAndSettle();
    expect(sync.calls, 0);
  });
}
