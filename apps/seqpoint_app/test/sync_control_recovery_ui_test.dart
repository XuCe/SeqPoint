import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/sync_settings_page.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_pairing_page.dart';
import 'package:seqpoint_app/sync/sync_pairing_code.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}
class _Sync extends AppSyncService {
  @override
  bool get mediaSyncEnabled => false;
  _Sync() : super(db: SeqDatabase.inMemory(), root: Directory('unused'), secrets: _Secrets());
  PairingInvitation? invitation;
  PairingHandshake? host, guest;
  int recoveryInvites = 0, normalInvites = 0, recoveryResponses = 0, normalResponses = 0;
  int hostSaves = 0, recoverySaves = 0, normalSaves = 0;
  @override
  Future<PairingInvitation> createRecoveryInvitation() async { recoveryInvites++; return invitation!; }
  @override
  Future<PairingInvitation> createInvitation() async { normalInvites++; return invitation!; }
  @override
  Future<PairingHandshake> acceptResponse(Map<String, Object?> payload) async => host!;
  @override
  Future<PairingHandshake> respondToRecoveryInvitation(Map<String, Object?> payload) async { recoveryResponses++; return guest!; }
  @override
  Future<PairingHandshake> respondToInvitation(Map<String, Object?> payload) async { normalResponses++; return guest!; }
  @override
  Future<Map<String, Object?>> finishHost(PairingHandshake session) async {
    if (session.state != PairingHandshakeState.ready) throw StateError('not-ready');
    hostSaves++; return {'checkpoint': <String, Object?>{}, 'epoch_envelope': <String, Object?>{}};
  }
  @override
  Future<void> recoverFromPairing(PairingHandshake session, Map<String, Object?> packet) async {
    if (session.state != PairingHandshakeState.ready) throw StateError('not-ready');
    recoverySaves++;
  }
  @override
  Future<void> finishGuest(PairingHandshake session, Map<String, Object?> packet) async { normalSaves++; }
  @override
  bool get prepared => true;
  @override
  bool get hasVault => true;
  @override
  bool get hasMembershipConflict => true;
  @override
  bool get canSync => false;
  @override
  String get status => '成员控制冲突，同步暂停';
  @override
  void cancelPairing() {}
}

Future<({PairingInvitation invitation, PairingHandshake host, PairingHandshake guest})> _pair() async {
  final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
  final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
  final invitation = await PairingInvitation.create(keys: a, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64);
  final received = await PairingInvitation.fromQr(invitation.toQrPayload());
  final guest = await PairingHandshake.respond(invitation: received, keys: b, tlsFingerprint: 'b' * 64);
  final host = await PairingHandshake.acceptResponse(invitation: invitation, keys: a, response: guest.response.toJson());
  return (invitation: invitation, host: host, guest: guest);
}

void main() {
  testWidgets('恢复忙时大字号暗色小屏及横屏均禁用恢复配对且无溢出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 667));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(theme: ThemeData.dark(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
        textScaler: const TextScaler.linear(2), disableAnimations: true), child: child!),
      home: SyncPairingPage(service: sync, controlRecovery: true, restoring: true)));
    for (final button in tester.widgetList<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton))) {
      expect(button.onPressed, isNull);
    }
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('pairing-input'))).enabled, isFalse);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(667, 375)); await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('冲突guest核对真实双方SAS后只调用显式控制恢复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (:invitation, :host, :guest) = await _pair();
    final sync = _Sync()..guest = guest;
    addTearDown(() { host.cancel(); guest.cancel(); sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('恢复成员控制')); await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.invitation, invitation.toQrPayload()));
    await tester.tap(find.text('加入恢复邀请')); await tester.pumpAndSettle();
    expect(sync.recoveryResponses, 1); expect(sync.normalResponses, 0);
    expect(find.text('安全保存恢复'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-short-code')), host.shortCode);
    await tester.tap(find.text('确认短码')); await tester.pumpAndSettle();
    expect(find.text('安全保存恢复'), findsNothing);
    final own = tester.widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data).whereType<String>().firstWhere((text) => text.startsWith('seqpoint-pair-v1:confirmation:'));
    await host.acceptConfirmation(decodePairingCode(own, PairingCodeKind.confirmation));
    final peer = await host.confirmShortCode(guest.shortCode);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.confirmation, peer));
    await tester.tap(find.text('验证对端确认')); await tester.pumpAndSettle();
    expect(sync.recoverySaves, 0);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.grant, {'checkpoint': {}, 'epoch_envelope': {}}));
    await tester.tap(find.text('安全保存恢复')); await tester.pumpAndSettle();
    expect(sync.recoverySaves, 1); expect(sync.normalSaves, 0);
    expect(find.text('成员控制已安全恢复'), findsOneWidget);
  });
  testWidgets('冲突host仅显式生成恢复邀请并在双方SAS后提交授权', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (:invitation, :host, :guest) = await _pair();
    final sync = _Sync()..invitation = invitation..host = host;
    addTearDown(() { host.cancel(); guest.cancel(); sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    expect(sync.recoveryInvites, 0);
    await tester.tap(find.text('恢复成员控制')); await tester.pumpAndSettle();
    await tester.tap(find.text('生成恢复邀请')); await tester.pumpAndSettle();
    expect(sync.recoveryInvites, 1); expect(sync.normalInvites, 0);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.response, guest.response.toJson()));
    await tester.tap(find.text('读取应答')); await tester.pumpAndSettle();
    expect(find.text('安全保存并生成授权码'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-short-code')), guest.shortCode);
    await tester.tap(find.text('确认短码')); await tester.pumpAndSettle();
    expect(sync.hostSaves, 0);
    final peer = await guest.confirmShortCode(host.shortCode);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.confirmation, peer));
    await tester.tap(find.text('验证对端确认')); await tester.pumpAndSettle();
    await tester.tap(find.text('安全保存并生成授权码')); await tester.pumpAndSettle();
    expect(sync.hostSaves, 1);
    expect(find.text('本机授权已安全保存'), findsOneWidget);
  });
  testWidgets('成员冲突需显式恢复，页面说明影响且不显示普通配对入口', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _Sync();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    expect(find.text('成员控制发生冲突'), findsOneWidget);
    expect(find.text('手动配对设备'), findsNothing);
    await tester.tap(find.text('恢复成员控制')); await tester.pumpAndSettle();
    expect(find.text('生成恢复邀请'), findsOneWidget);
    expect(find.text('加入恢复邀请'), findsOneWidget);
    expect(find.textContaining('其他设备需要重新配对'), findsOneWidget);
    expect(find.text('生成邀请'), findsNothing);
  });
}
