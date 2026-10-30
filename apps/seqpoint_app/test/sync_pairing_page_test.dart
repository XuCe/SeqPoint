import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_pairing_page.dart';
import 'package:seqpoint_app/sync/sync_pairing_code.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {}
class _Sync extends AppSyncService {
  _Sync() : super(db: SeqDatabase.inMemory(), root: Directory('unused'), secrets: _Secrets());
  int cancellations = 0;
  PairingHandshake? guest;
  PairingHandshake? host;
  PairingInvitation? invitation;
  Completer<void>? invitationGate;
  @override
  Future<PairingInvitation> createInvitation() async {
    await invitationGate?.future;
    return invitation!;
  }
  @override
  Future<PairingHandshake> acceptResponse(Map<String, Object?> payload) async => host!;
  @override
  Future<Map<String, Object?>> finishHost(PairingHandshake session) async {
    if (session.state != PairingHandshakeState.ready) throw StateError('not-ready');
    saves++;
    return {'checkpoint': <String, Object?>{}, 'epoch_envelope': <String, Object?>{}};
  }
  int saves = 0;
  bool failSave = false;
  @override
  Future<void> finishGuest(PairingHandshake session, Map<String, Object?> packet) async {
    if (session.state != PairingHandshakeState.ready) throw StateError('not-ready');
    if (failSave) throw StateError('private-store-details');
    saves++;
  }
  @override
  Future<PairingHandshake> respondToInvitation(Map<String, Object?> payload) async => guest!;
  @override
  bool get prepared => true;
  @override
  bool get canCreateInvitation => invitation != null;
  @override
  void cancelPairing() { cancellations++; }
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
  testWidgets('旧页只取消自己持有的邀请，不全局取消后来创建的邀请', (tester) async {
    final first = await _pair(), second = await _pair();
    final service = _Sync()..invitation = first.invitation;
    addTearDown(() {
      first.host.cancel(); first.guest.cancel(); second.host.cancel(); second.guest.cancel();
      second.invitation.cancel(); service.db.close(); service.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service)));
    await tester.tap(find.text('生成邀请')); await tester.pumpAndSettle();
    service.invitation = second.invitation;
    await service.createInvitation();
    await tester.pumpWidget(const SizedBox());
    expect(first.invitation.isCancelled, isTrue);
    expect(second.invitation.isCancelled, isFalse);
    expect(service.cancellations, 0);
  });
  testWidgets('恢复期间所有配对操作禁用且小屏可滚动', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = _Sync();
    addTearDown(() { service.db.close(); service.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service, restoring: true)));
    expect(find.text('正在恢复备份，配对操作暂不可用'), findsOneWidget);
    for (final button in tester.widgetList<ButtonStyleButton>(
      find.byWidgetPredicate((widget) => widget is ButtonStyleButton))) {
      expect(button.onPressed, isNull);
    }
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('pairing-input'))).enabled, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets('关闭后才返回的邀请会取消，旧页面不影响新配对', (tester) async {
    final (:invitation, :host, :guest) = await _pair();
    final service = _Sync()..invitation = invitation..invitationGate = Completer<void>();
    addTearDown(() { host.cancel(); guest.cancel(); service.db.close(); service.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service)));
    await tester.tap(find.text('生成邀请')); await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(service.cancellations, 0);
    service.invitationGate!.complete(); await tester.pump();
    expect(invitation.isCancelled, isTrue);
    expect(service.cancellations, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('邀请与授权只在点击时复制，邀请端不能替对方宣称保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (:invitation, :host, :guest) = await _pair();
    final service = _Sync()..host = host..invitation = invitation;
    addTearDown(() { host.cancel(); guest.cancel(); service.db.close(); service.dispose(); });
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service)));
    await tester.tap(find.text('生成邀请')); await tester.pumpAndSettle();
    expect(copied, isEmpty);
    await tester.tap(find.text('复制邀请码')); await tester.pumpAndSettle();
    expect(copied.single, startsWith('seqpoint-pair-v1:invitation:'));
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.response, guest.response.toJson()));
    await tester.tap(find.text('读取应答')); await tester.pumpAndSettle();
    expect(find.text('安全保存并生成授权码'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-short-code')), guest.shortCode);
    await tester.tap(find.text('确认短码')); await tester.pumpAndSettle();
    final peer = await guest.confirmShortCode(host.shortCode);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.confirmation, peer));
    await tester.tap(find.text('验证对端确认')); await tester.pumpAndSettle();
    expect(host.state, PairingHandshakeState.ready);
    await tester.tap(find.text('安全保存并生成授权码')); await tester.pumpAndSettle();
    expect(service.saves, 1); expect(copied, hasLength(1));
    expect(find.text('本机授权已安全保存'), findsOneWidget);
    expect(find.text('配对已安全保存'), findsNothing);
    await tester.tap(find.text('复制确认码')); await tester.pumpAndSettle();
    await guest.acceptConfirmation(decodePairingCode(copied.last, PairingCodeKind.confirmation));
    expect(guest.state, PairingHandshakeState.ready);
    await tester.tap(find.text('复制授权码')); await tester.pumpAndSettle();
    expect(copied.last, startsWith('seqpoint-pair-v1:grant:'));
  });
  testWidgets('本机确认不能代替对端确认，双方确认后才允许保存', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (:invitation, :host, :guest) = await _pair();
    final service = _Sync()..guest = guest;
    addTearDown(() { guest.cancel(); host.cancel(); service.db.close(); service.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service)));
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.invitation, invitation.toQrPayload()));
    await tester.tap(find.text('加入邀请')); await tester.pumpAndSettle();
    expect(find.text(guest.shortCode), findsOneWidget);
    expect(find.text('安全保存配对'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('pairing-short-code')), host.shortCode);
    await tester.tap(find.text('确认短码')); await tester.pumpAndSettle();
    expect(guest.state, PairingHandshakeState.awaitingConfirmation);
    expect(find.text('安全保存配对'), findsNothing);
    final own = tester.widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data).whereType<String>().firstWhere((text) => text.startsWith('seqpoint-pair-v1:confirmation:'));
    await host.acceptConfirmation(decodePairingCode(own, PairingCodeKind.confirmation));
    final peer = await host.confirmShortCode(guest.shortCode);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.confirmation, peer));
    await tester.tap(find.text('验证对端确认')); await tester.pumpAndSettle();
    expect(guest.state, PairingHandshakeState.ready);
    expect(find.text('安全保存配对'), findsOneWidget);
    expect(service.saves, 0);
    await tester.enterText(find.byKey(const ValueKey('pairing-input')),
      encodePairingCode(PairingCodeKind.grant, {'checkpoint': {}, 'epoch_envelope': {}}));
    service.failSave = true;
    await tester.tap(find.text('安全保存配对')); await tester.pumpAndSettle();
    expect(service.saves, 0);
    expect(find.text('配对已安全保存'), findsNothing);
    expect(find.text('private-store-details'), findsNothing);
    expect(find.text('配对未完成，请核对配对码并重新开始'), findsOneWidget);
    service.failSave = false;
    await tester.tap(find.text('安全保存配对')); await tester.pumpAndSettle();
    expect(service.saves, 1);
    expect(find.text('配对已安全保存'), findsOneWidget);
  });
  testWidgets('未创建空间不能生成邀请，无会话退出不触发全局取消', (tester) async {
    final service = _Sync();
    addTearDown(() { service.db.close(); service.dispose(); });
    await tester.pumpWidget(MaterialApp(home: SyncPairingPage(service: service)));
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '生成邀请')).onPressed, isNull);
    expect(find.text('加入邀请'), findsOneWidget);
    expect(find.text('配对已安全保存'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(service.cancellations, 0);
  });
}
