import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_identity_store.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_app/sync/sync_tls_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  int membershipWrites = 0;
  bool failWrite = false, corruptReadback = false, _badRead = false;
  Completer<void>? gate, entered;
  @override
  Future<String?> read(String key) async {
    if (_badRead && key == SyncMembershipStore.storageKey) {
      _badRead = false; return '{}';
    }
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    if (key == SyncMembershipStore.storageKey) {
      membershipWrites++; entered?.complete(); await gate?.future;
      if (failWrite) throw StateError('fake membership write failed');
      _badRead = corruptReadback;
    }
    values[key] = value;
  }
}

typedef _Node = ({AppSyncService service, SeqDatabase db, _Secrets secrets, Directory root});

Future<void> _pair(AppSyncService host, AppSyncService guest) async {
  final invitation = await host.createInvitation();
  final response = await guest.respondToInvitation(invitation.toQrPayload());
  final session = await host.acceptResponse(response.response.toJson());
  final hp = await session.confirmShortCode(session.shortCode);
  final gp = await response.confirmShortCode(response.shortCode);
  await session.acceptConfirmation(gp); await response.acceptConfirmation(hp);
  await guest.finishGuest(response, await host.finishHost(session));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late LanTlsIdentity tls;
  setUpAll(() async { tls = await LanTlsIdentity.generate(); });
  Future<_Node> node(int seed) async {
    final secrets = _Secrets();
    secrets.values[SyncIdentityStore.storageKey] = jsonEncode({'v': 1,
      'name': 'fake-$seed', 'added_at': '2026-10-26T00:00:00.000Z',
      'signing_seed': base64Encode(List.filled(32, seed)),
      'exchange_seed': base64Encode(List.filled(32, seed + 20))});
    secrets.values[SyncTlsStore.storageKey] = jsonEncode({'v': 1,
      'certificate_pem': tls.certificatePem, 'private_key_pem': tls.privateKeyPem,
      'fingerprint': tls.fingerprint});
    final db = SeqDatabase.inMemory()..migrate();
    final root = await Directory.systemTemp.createTemp('revocation-fake-');
    final service = AppSyncService(db: db, root: root, secrets: secrets);
    addTearDown(() async {
      await service.stop(); service.dispose(); db.close(); await root.delete(recursive: true);
    });
    await service.prepare('fake-$seed');
    return (service: service, db: db, secrets: secrets, root: root);
  }
  Future<SavedMembership> saved(_Node node) async {
    final local = await SyncIdentityStore(node.secrets).loadOrCreate('fake');
    return (await SyncMembershipStore(node.secrets).load(local.keys))!;
  }

  test('已确认成员撤销另一设备时先安全保存新Epoch和精确剩余接收者', () async {
    final a = await node(1), b = await node(2);
    expect(a.service.membershipVersion, isNull);
    await a.service.newVault(); await _pair(a.service, b.service);
    final oldInvitation = await a.service.createInvitation();
    final old = await saved(a), now = DateTime.utc(2026, 10, 26);
    NoteRepository(a.db).insert(Note(id: 'kept', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '保留业务', createdAt: now, updatedAt: now));
    final operations = a.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id').toList();
    final media = File('${a.root.path}/recording.wav')..writeAsBytesSync([1, 2, 3]);
    final token = a.service.membershipVersion;
    expect(token, isNotNull);
    await expectLater(a.service.revokePeer(a.service.verifiedPeers.single,
        expectedVersion: token!), completes);
    final current = await saved(a);
    expect(current.state.epoch, 2);
    expect(current.state.members.keys, [a.service.identity!.deviceId]);
    expect(current.state.revokedIds, contains(b.service.identity!.deviceId));
    final event = current.membership.evidence.last;
    expect(event.type.name, 'revoke');
    expect(event.envelopes.keys, [a.service.identity!.deviceId]);
    expect(current.epochKey!.epoch, 2);
    expect(current.epochKey!.keyBytes, isNot(old.epochKey!.keyBytes));
    expect(current.epochKeys.keys.toSet(), {1, 2});
    expect(oldInvitation.isCancelled, isTrue);
    expect(a.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id'), operations);
    expect(NoteRepository(a.db).byId('kept')!.rawContent, '保留业务');
    expect(media.readAsBytesSync(), [1, 2, 3]);
  });

  test('真实TLS非创始成员可撤创始设备，旧会话拒绝且剩余设备取得新key', () async {
    final a = await node(1), b = await node(2), c = await node(3);
    await a.service.newVault();
    await _pair(a.service, b.service); await _pair(a.service, c.service);
    await a.service.startServer(address: InternetAddress.loopbackIPv4);
    await b.service.syncOnce(peerDeviceId: a.service.identity!.deviceId,
        host: '127.0.0.1', port: a.service.listeningPort!);
    expect(b.service.verifiedPeers, hasLength(2));
    final now = DateTime.utc(2026, 10, 26);
    NoteRepository(b.db).insert(Note(id: 'pending', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '待发事实保留', createdAt: now, updatedAt: now));
    final operations = b.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id').toList();
    final target = b.service.verifiedPeers.singleWhere((peer) => peer.deviceId == a.service.identity!.deviceId);
    await b.service.revokePeer(target, expectedVersion: b.service.membershipVersion!);
    final revoked = await saved(b), event = revoked.membership.evidence.last;
    expect(event.issuerDeviceId, b.service.identity!.deviceId);
    expect(event.envelopes.keys.toSet(), {b.service.identity!.deviceId, c.service.identity!.deviceId});
    expect(b.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id'), operations);
    expect(NoteRepository(b.db).byId('pending')!.rawContent, '待发事实保留');
    await b.service.startServer(address: InternetAddress.loopbackIPv4);
    await expectLater(a.service.syncOnce(peerDeviceId: b.service.identity!.deviceId,
        host: '127.0.0.1', port: b.service.listeningPort!), throwsStateError);
    await c.service.syncOnce(peerDeviceId: b.service.identity!.deviceId,
        host: '127.0.0.1', port: b.service.listeningPort!);
    final remaining = await saved(c);
    expect(remaining.state.epoch, 2);
    expect(remaining.state.keyCommitment, revoked.state.keyCommitment);
    expect(remaining.epochKey!.keyBytes, revoked.epochKey!.keyBytes);
    expect(c.service.verifiedPeers.single.deviceId, b.service.identity!.deviceId);
    expect(c.service.canSync, isTrue);
  });

  test('旧确认token、完整目标变化及自撤销都不写成员状态', () async {
    final a = await node(1), b = await node(2);
    await a.service.newVault(); await _pair(a.service, b.service);
    final peer = a.service.verifiedPeers.single, token = a.service.membershipVersion!;
    final before = a.secrets.values[SyncMembershipStore.storageKey];
    final current = await saved(a);
    final changed = MemberKeys(deviceId: peer.deviceId, signingPublicKey: peer.signingPublicKey,
        exchangePublicKey: peer.exchangePublicKey, tlsFingerprint: 'd' * 64);
    final self = current.state.members[a.service.identity!.deviceId]!;
    final wrongSigning = MemberKeys(deviceId: peer.deviceId, signingPublicKey: self.signingPublicKey,
        exchangePublicKey: peer.exchangePublicKey, tlsFingerprint: peer.tlsFingerprint);
    final wrongExchange = MemberKeys(deviceId: peer.deviceId, signingPublicKey: peer.signingPublicKey,
        exchangePublicKey: self.exchangePublicKey, tlsFingerprint: peer.tlsFingerprint);
    final unknown = MemberKeys(deviceId: 'A' * 43, signingPublicKey: peer.signingPublicKey,
        exchangePublicKey: peer.exchangePublicKey, tlsFingerprint: peer.tlsFingerprint);
    for (final target in [changed, wrongSigning, wrongExchange, unknown, self]) {
      await expectLater(a.service.revokePeer(target, expectedVersion: token), throwsStateError);
      expect(a.secrets.values[SyncMembershipStore.storageKey], before);
    }
    await a.service.prepare('fake');
    await expectLater(a.service.revokePeer(peer, expectedVersion: token), throwsStateError);
    expect(a.secrets.values[SyncMembershipStore.storageKey], before);
    expect(a.service.verifiedPeers.single.deviceId, peer.deviceId);
  });

  for (final corruptReadback in [false, true]) {
    test('${corruptReadback ? '回读' : '写入'}失败不激活新成员状态，显式重载才恢复', () async {
      final a = await node(1), b = await node(2);
      await a.service.newVault(); await _pair(a.service, b.service);
      final peer = a.service.verifiedPeers.single, token = a.service.membershipVersion!;
      final before = a.secrets.values[SyncMembershipStore.storageKey];
      a.secrets.failWrite = !corruptReadback;
      a.secrets.corruptReadback = corruptReadback;
      await expectLater(a.service.revokePeer(peer, expectedVersion: token), throwsStateError);
      expect(a.service.membershipVersion, isNull);
      expect(a.service.canSync, isFalse);
      if (!corruptReadback) expect(a.secrets.values[SyncMembershipStore.storageKey], before);
      a.secrets.failWrite = false; a.secrets.corruptReadback = false;
      await a.service.prepare('fake');
      expect(a.service.membershipVersion, isNotNull);
      expect(a.service.verifiedPeers.isEmpty, corruptReadback);
      expect((await saved(a)).state.epoch, corruptReadback ? 2 : 1);
    });
  }

  test('安全保存等待期间立即关闭授权，成功回读后才更新可用状态', () async {
    final a = await node(1), b = await node(2);
    await a.service.newVault(); await _pair(a.service, b.service);
    final before = a.secrets.values[SyncMembershipStore.storageKey];
    a.secrets.gate = Completer<void>(); a.secrets.entered = Completer<void>();
    final pending = a.service.revokePeer(a.service.verifiedPeers.single,
        expectedVersion: a.service.membershipVersion!);
    try {
      await a.secrets.entered!.future;
      expect(a.service.membershipVersion, isNull); expect(a.service.canSync, isFalse);
      expect(a.secrets.values[SyncMembershipStore.storageKey], before);
    } finally { a.secrets.gate!.complete(); }
    await pending;
    expect(a.service.membershipVersion, isNotNull);
    expect(a.service.verifiedPeers, isEmpty);
  });

  for (final change in ['stop', 'writer', 'restore']) {
    test('签名await期间$change变更拒绝迟到提交且不写安全记录', () async {
      final a = await node(1), b = await node(2);
      await a.service.newVault(); await _pair(a.service, b.service);
      final peer = a.service.verifiedPeers.single, token = a.service.membershipVersion!;
      final before = a.secrets.values[SyncMembershipStore.storageKey];
      var armed = true;
      Future<void>? stopping;
      a.service.addListener(() {
        if (!armed || !a.service.busy) return;
        armed = false;
        scheduleMicrotask(() {
          if (change == 'stop') {
            stopping = a.service.stop();
          } else if (change == 'writer') {
            a.db.raw.execute("UPDATE sync_local SET device_id='other'");
          } else {
            a.db.raw.execute('UPDATE sync_local SET enabled=0,requires_new_identity=1');
          }
        });
      });
      await expectLater(a.service.revokePeer(peer, expectedVersion: token), throwsStateError);
      await stopping;
      expect(armed, isFalse);
      expect(a.secrets.values[SyncMembershipStore.storageKey], before);
      expect(a.service.membershipVersion, isNull);
    });
  }
}
