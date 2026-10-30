import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/settings/sync_settings_page.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_pairing_code.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}
class _RecoverySync extends AppSyncService {
  @override
  bool get mediaSyncEnabled => false;
  _RecoverySync() : super(db: SeqDatabase.inMemory(), root: Directory('unused'), secrets: _Secrets());
  DeviceIdentity? candidate;
  Completer<void>? beginGate;
  PairingHandshake? guest;
  int beginnings = 0, normalResponses = 0, recoveryResponses = 0;
  int prepares = 0;
  bool ready = true;
  int normalSaves = 0, recoverySaves = 0;
  @override
  bool get requiresNewIdentity => true;
  @override
  bool get hasPendingIdentityRecovery => candidate != null;
  @override
  DeviceIdentity? get pendingIdentity => candidate;
  @override
  bool get prepared => ready;
  @override
  Future<void> prepare(String name) async { prepares++; ready = true; notifyListeners(); }
  @override
  bool get hasVault => true;
  @override
  bool get canSync => false;
  @override
  String get status => '恢复后同步已断开';
  @override
  Future<DeviceIdentity> beginIdentityRecovery(String name) async {
    beginnings++; await beginGate?.future;
    candidate = DeviceIdentity(deviceId: 'new-candidate-id', name: name,
      signingPublicKey: 'public-signing', exchangePublicKey: 'public-exchange', addedAt: DateTime.utc(2026));
    notifyListeners(); return candidate!;
  }
  @override
  Future<PairingHandshake> respondToRecoveryInvitation(Map<String, Object?> invitation) async {
    recoveryResponses++; return guest!;
  }
  @override
  Future<PairingHandshake> respondToInvitation(Map<String, Object?> invitation) async {
    normalResponses++; return guest!;
  }
  @override
  Future<void> finishGuest(PairingHandshake session, Map<String, Object?> packet) async { normalSaves++; }
  @override
  Future<void> finishIdentityRecovery(PairingHandshake session, Map<String, Object?> packet) async {
    if (session.state != PairingHandshakeState.ready) throw StateError('not-ready');
    recoverySaves++;
  }
  @override
  void cancelPairing() {}
}

void main() {
  testWidgets('恢复标志已知但安全材料未准备时可重试准备，不直接创建候选', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _RecoverySync()..ready = false;
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    expect(find.text('恢复后需要新设备身份'), findsOneWidget);
    expect(find.text('准备本机'), findsOneWidget);
    expect(find.text('生成新身份'), findsNothing);
    await tester.tap(find.text('准备本机')); await tester.pumpAndSettle();
    expect(sync.prepares, 1); expect(sync.beginnings, 0);
    expect(find.text('生成新身份'), findsOneWidget);
    expect(sync.candidate, isNull);
  });
  testWidgets('恢复配对仅走新身份guest入口，真实双方确认后才调用恢复提交', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    final invitation = await PairingInvitation.create(keys: a, vaultPublicId: 'v1', tlsFingerprint: 'a' * 64);
    final received = await PairingInvitation.fromQr(invitation.toQrPayload());
    final guest = await PairingHandshake.respond(invitation: received, keys: b, tlsFingerprint: 'b' * 64);
    final host = await PairingHandshake.acceptResponse(invitation: invitation, keys: a, response: guest.response.toJson());
    final sync = _RecoverySync()..guest = guest;
    await sync.beginIdentityRecovery('恢复设备');
    addTearDown(() { guest.cancel(); host.cancel(); sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    await tester.tap(find.text('用新身份重新配对')); await tester.pumpAndSettle();
    expect(find.text('生成邀请'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.invitation, invitation.toQrPayload()));
    await tester.tap(find.text('加入邀请')); await tester.pumpAndSettle();
    expect(sync.recoveryResponses, 1); expect(sync.normalResponses, 0);
    expect(find.text('安全保存配对'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-short-code')), host.shortCode);
    await tester.tap(find.text('确认短码')); await tester.pumpAndSettle();
    expect(find.text('安全保存配对'), findsNothing);
    final own = tester.widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data).whereType<String>().firstWhere((text) => text.startsWith('seqpoint-pair-v1:confirmation:'));
    await host.acceptConfirmation(decodePairingCode(own, PairingCodeKind.confirmation));
    final peer = await host.confirmShortCode(guest.shortCode);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.confirmation, peer));
    await tester.tap(find.text('验证对端确认')); await tester.pumpAndSettle();
    expect(guest.state, PairingHandshakeState.ready);
    expect(sync.recoverySaves, 0);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.grant, {'checkpoint': {}, 'epoch_envelope': {}}));
    await tester.tap(find.text('安全保存配对')); await tester.pumpAndSettle();
    expect(sync.recoverySaves, 1); expect(sync.normalSaves, 0);
    expect(find.text('配对已安全保存'), findsOneWidget);
  });
  testWidgets('恢复只在显式操作后创建新身份，等待期间不重入且旧入口隐藏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sync = _RecoverySync()..beginGate = Completer<void>();
    addTearDown(() { sync.db.close(); sync.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(service: sync)));
    expect(sync.beginnings, 0);
    expect(find.text('恢复后需要新设备身份'), findsOneWidget);
    expect(find.text('创建同步空间'), findsNothing);
    expect(find.text('手动配对设备'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('sync-device-name')), '恢复设备');
    await tester.tap(find.text('生成新身份')); await tester.pump();
    expect(sync.beginnings, 1);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '生成新身份')).onPressed, isNull);
    sync.beginGate!.complete(); await tester.pumpAndSettle();
    expect(find.text('new-candidate-id'), findsOneWidget);
    expect(find.text('用新身份重新配对'), findsOneWidget);
    expect(find.text('已同步'), findsNothing);
  });
}
