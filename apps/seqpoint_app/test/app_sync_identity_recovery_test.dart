import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_identity_store.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_app/sync/sync_tls_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  bool failMember = false, corruptMember = false, badRead = false;
  bool failDefaultMember = false, corruptDefaultMember = false;
  SeqDatabase? db;
  String? failIdentityAfterWriter;
  int memberWrites = 0;
  @override
  Future<String?> read(String key) async {
    if (key == SyncIdentityStore.storageKey && failIdentityAfterWriter != null &&
        db!.raw.select('SELECT device_id FROM sync_local').single['device_id'] == failIdentityAfterWriter) {
      failIdentityAfterWriter = null; throw StateError('fake post-commit identity read');
    }
    if (badRead && (key == SyncMembershipStore.storageKey || key.startsWith('${SyncMembershipStore.storageKey}.'))) {
      badRead = false; return '{}';
    }
    return values[key];
  }
  @override
  Future<void> write(String key, String record) async {
    if (key == SyncMembershipStore.storageKey) {
      memberWrites++;
      if (failDefaultMember) throw StateError('fake default member failure');
      badRead = corruptDefaultMember;
    }
    if (key.startsWith('${SyncMembershipStore.storageKey}.')) {
      if (failMember) throw StateError('fake write failure');
      badRead = corruptMember;
    }
    values[key] = record;
  }
}

typedef _Node = ({AppSyncService service, SeqDatabase db, _Secrets secrets, Directory root});

Future<({PairingHandshake host, PairingHandshake guest})> _pair(
    AppSyncService host, AppSyncService guest, {bool recovery = false, bool control = false}) async {
  final invitation = control ? await host.createRecoveryInvitation() : await host.createInvitation();
  final g = recovery || control ? await guest.respondToRecoveryInvitation(invitation.toQrPayload())
      : await guest.respondToInvitation(invitation.toQrPayload());
  final h = await host.acceptResponse(g.response.toJson());
  final hp = await h.confirmShortCode(h.shortCode), gp = await g.confirmShortCode(g.shortCode);
  await h.acceptConfirmation(gp); await g.acceptConfirmation(hp);
  return (host: h, guest: g);
}

void main() {
  late LanTlsIdentity tls;
  setUpAll(() async { tls = await LanTlsIdentity.generate(); });
  Future<_Node> node(int seed) async {
    final secrets = _Secrets();
    secrets.values[SyncIdentityStore.storageKey] = jsonEncode({'v': 1, 'name': 'fake-$seed',
      'added_at': '2026-10-26T00:00:00.000Z', 'signing_seed': base64Encode(List.filled(32, seed)),
      'exchange_seed': base64Encode(List.filled(32, seed + 20))});
    secrets.values[SyncTlsStore.storageKey] = jsonEncode({'v': 1,
      'certificate_pem': tls.certificatePem, 'private_key_pem': tls.privateKeyPem,
      'fingerprint': tls.fingerprint});
    final db = SeqDatabase.inMemory()..migrate();
    final root = await Directory.systemTemp.createTemp('identity-recovery-fake-');
    final service = AppSyncService(db: db, root: root, secrets: secrets);
    addTearDown(() async {
      await service.stop(); service.dispose(); db.close(); await root.delete(recursive: true);
    });
    return (service: service, db: db, secrets: secrets, root: root);
  }
  Future<AppSyncService> reopen(_Node node) async {
    final service = AppSyncService(db: node.db, root: node.root, secrets: node.secrets);
    addTearDown(() async { await service.stop(); service.dispose(); });
    await service.prepare('fake');
    return service;
  }
  Future<({_Node host, _Node guest})> paired() async {
    final h = await node(1), g = await node(2);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    await g.service.finishGuest(p.guest, await h.service.finishHost(p.host));
    return (host: h, guest: g);
  }

  Future<void> conflict(_Node host, _Node guest) async {
    final h = await SyncIdentityStore(host.secrets).loadForDevice(host.service.identity!.deviceId);
    final g = await SyncIdentityStore(guest.secrets).loadForDevice(guest.service.identity!.deviceId);
    final hm = (await SyncMembershipStore(host.secrets).load(h.keys))!;
    final gm = (await SyncMembershipStore(guest.secrets).load(g.keys))!;
    final a = await MembershipEvent.create(parent: hm.state, issuer: h.keys, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: hm.state, issuer: g.keys, type: MembershipEventType.rotate);
    for (final entry in [(host, h, hm), (guest, g, gm)]) {
      await entry.$3.membership.ingest(a, issuerFileDeviceId: h.keys.deviceId);
      await entry.$3.membership.ingest(b, issuerFileDeviceId: g.keys.deviceId);
      await SyncMembershipStore(entry.$1.secrets).save(membership: entry.$3.membership, localDevice: entry.$2.keys);
      await entry.$1.service.prepare('fake');
    }
  }

  test('fresh paired writer commits once, reopens by device and is never reused after another restore', () async {
    final f = await paired(), oldId = f.guest.service.identity!.deviceId;
    final oldControl = f.guest.secrets.values[SyncMembershipStore.storageKey];
    await f.guest.service.stop(); f.guest.db.disconnectSyncForRestore();
    final restored = await reopen(f.guest);
    expect(restored.requiresNewIdentity, isTrue); expect(restored.canSync, isFalse);
    final fresh = await restored.beginIdentityRecovery('new device');
    expect(fresh.deviceId, isNot(oldId)); expect(restored.pendingIdentity!.deviceId, fresh.deviceId);
    final p = await _pair(f.host.service, restored, recovery: true);
    await restored.finishIdentityRecovery(p.guest, await f.host.service.finishHost(p.host));
    final writer = f.guest.db.raw.select('SELECT * FROM sync_local').single;
    expect(writer['device_id'], fresh.deviceId); expect(writer['requires_new_identity'], 0);
    expect(restored.canSync, isTrue); expect(restored.hasPendingIdentityRecovery, isFalse);
    expect(f.guest.secrets.values[SyncMembershipStore.storageKey], oldControl);
    expect(f.guest.secrets.values[SyncMembershipStore.storageKeyForDevice(fresh.deviceId)], isNotNull);
    await restored.stop();
    final committed = await reopen(f.guest);
    expect(committed.identity!.deviceId, fresh.deviceId); expect(committed.canSync, isTrue);
    await committed.stop(); f.guest.db.disconnectSyncForRestore();
    final again = await reopen(f.guest);
    expect(again.hasPendingIdentityRecovery, isFalse);
    final third = await again.beginIdentityRecovery('third');
    expect({oldId, fresh.deviceId, third.deviceId}, hasLength(3));
    expect(again.canSync, isFalse);
  });

  for (final readback in [false, true]) {
    test('member ${readback ? 'readback' : 'write'} failure leaves restore closed and old audit intact', () async {
      final f = await paired();
      final old = f.guest.secrets.values[SyncMembershipStore.storageKey];
      await f.guest.service.stop(); f.guest.db.disconnectSyncForRestore();
      final restored = await reopen(f.guest);
      await expectLater(restored.newVault(), throwsStateError);
      final first = await restored.beginIdentityRecovery('first');
      final p = await _pair(f.host.service, restored, recovery: true);
      f.guest.secrets.failMember = !readback; f.guest.secrets.corruptMember = readback;
      await expectLater(restored.finishIdentityRecovery(p.guest,
          await f.host.service.finishHost(p.host)), throwsStateError);
      expect(restored.canSync, isFalse);
      final row = f.guest.db.raw.select('SELECT * FROM sync_local').single;
      expect(row['requires_new_identity'], 1); expect(row['enabled'], 0);
      expect(row['device_id'], isNull); expect(row['baseline_ready'], 0);
      expect(f.guest.secrets.values[SyncMembershipStore.storageKey], old);
      f.guest.secrets.failMember = false; f.guest.secrets.corruptMember = false;
      await restored.stop();
      final reopened = await reopen(f.guest);
      expect(reopened.hasPendingIdentityRecovery, isFalse);
      final fresh = await reopened.beginIdentityRecovery('fresh');
      expect(fresh.deviceId, isNot(first.deviceId));
    });
  }

  test('post-commit identity read failure retires the old actor and reopens the committed writer', () async {
    final f = await paired();
    await f.guest.service.stop(); f.guest.db.disconnectSyncForRestore();
    final restored = await reopen(f.guest), fresh = await restored.beginIdentityRecovery('new');
    final p = await _pair(f.host.service, restored, recovery: true);
    f.guest.secrets.db = f.guest.db; f.guest.secrets.failIdentityAfterWriter = fresh.deviceId;
    await expectLater(restored.finishIdentityRecovery(p.guest,
        await f.host.service.finishHost(p.host)), throwsStateError);
    final writer = f.guest.db.raw.select('SELECT * FROM sync_local').single;
    expect(writer['device_id'], fresh.deviceId); expect(writer['requires_new_identity'], 0);
    expect(restored.canCreateInvitation, isFalse); expect(restored.canSync, isFalse);
    await expectLater(restored.createInvitation(), throwsStateError);
    await restored.stop();
    final reopened = await reopen(f.guest);
    expect(reopened.identity!.deviceId, fresh.deviceId); expect(reopened.canSync, isTrue);
  });

  test('bound writer with missing scoped membership stays closed and cannot create replacement trust', () async {
    final f = await paired();
    await f.guest.service.stop(); f.guest.db.disconnectSyncForRestore();
    final restored = await reopen(f.guest), fresh = await restored.beginIdentityRecovery('new');
    final p = await _pair(f.host.service, restored, recovery: true);
    await restored.finishIdentityRecovery(p.guest, await f.host.service.finishHost(p.host));
    await restored.stop();
    f.guest.secrets.values.remove(SyncMembershipStore.storageKeyForDevice(fresh.deviceId));
    final before = Map<String, String>.from(f.guest.secrets.values);
    final writer = Map<String, Object?>.from(f.guest.db.raw.select('SELECT * FROM sync_local').single);
    final missing = AppSyncService(db: f.guest.db, root: f.guest.root, secrets: f.guest.secrets);
    addTearDown(() async { await missing.stop(); missing.dispose(); });
    await expectLater(missing.prepare('fake'), throwsStateError);
    expect(missing.prepared, isFalse); expect(missing.canSync, isFalse);
    await expectLater(missing.newVault(), throwsStateError);
    final invitation = await f.host.service.createInvitation();
    await expectLater(missing.respondToInvitation(invitation.toQrPayload()), throwsStateError);
    expect(f.guest.secrets.values, before);
    expect(f.guest.db.raw.select('SELECT * FROM sync_local').single, writer);
  });

  test('two conflicted devices confirm a fresh authority and retain both control audits', () async {
    final f = await paired();
    await conflict(f.host, f.guest);
    expect(f.host.service.hasMembershipConflict, isTrue);
    expect(f.guest.service.hasMembershipConflict, isTrue);
    final before = jsonDecode(f.host.secrets.values[SyncMembershipStore.storageKey]!) as Map;
    final p = await _pair(f.host.service, f.guest.service, control: true);
    await f.guest.service.recoverFromPairing(p.guest, await f.host.service.finishHost(p.host));
    for (final n in [f.host, f.guest]) {
      expect(n.service.hasMembershipConflict, isFalse); expect(n.service.canSync, isTrue);
      final local = await SyncIdentityStore(n.secrets).loadForDevice(n.service.identity!.deviceId);
      final saved = (await SyncMembershipStore(n.secrets).load(local.keys))!;
      expect(saved.state.epoch, 3);
      expect(saved.state.authorityId, isNot((before['control'] as Map)['anchor']['authority_id']));
      expect(saved.membership.isolatedControlRecords, hasLength(1));
      expect(saved.epochKeys.keys, [1, 3]);
      await n.service.stop();
      expect((await reopen(n)).canSync, isTrue);
    }
  });

  test('a failed identity reload never continues advertising the previously loaded writer', () async {
    final f = await paired();
    f.guest.secrets.db = f.guest.db;
    f.guest.secrets.failIdentityAfterWriter = f.guest.service.identity!.deviceId;
    await expectLater(f.guest.service.prepare('reload'), throwsStateError);
    expect(f.guest.service.canSync, isFalse);
    expect(f.guest.service.canCreateInvitation, isFalse);
    await expectLater(f.guest.service.createInvitation(), throwsStateError);
    await f.guest.service.prepare('retry');
    expect(f.guest.service.canSync, isTrue);
  });

  test('a ready host recovery cannot resume after identity revalidation failed', () async {
    final f = await paired(); await conflict(f.host, f.guest);
    final p = await _pair(f.host.service, f.guest.service, control: true);
    final before = f.host.secrets.values[SyncMembershipStore.storageKey];
    final writes = f.host.secrets.memberWrites;
    f.host.secrets.db = f.host.db;
    f.host.secrets.failIdentityAfterWriter = f.host.service.identity!.deviceId;
    await expectLater(f.host.service.prepare('reload'), throwsStateError);
    expect(p.host.state, PairingHandshakeState.ready);
    var packetReleased = false;
    await expectLater(f.host.service.finishHost(p.host).then((_) { packetReleased = true; }), throwsStateError);
    expect(packetReleased, isFalse);
    expect(f.host.secrets.memberWrites, writes);
    expect(f.host.secrets.values[SyncMembershipStore.storageKey], before);
    expect(f.host.service.canSync, isFalse);
    expect(f.host.service.hasMembershipConflict, isTrue);
  });

  for (final readback in [false, true]) {
    test('host recovery ${readback ? 'readback' : 'write'} failure emits no packet and can explicitly re-pair', () async {
      final f = await paired(); await conflict(f.host, f.guest);
      final before = f.host.secrets.values[SyncMembershipStore.storageKey];
      final p = await _pair(f.host.service, f.guest.service, control: true);
      f.host.secrets.failDefaultMember = !readback; f.host.secrets.corruptDefaultMember = readback;
      await expectLater(f.host.service.finishHost(p.host), throwsStateError);
      expect(f.host.service.canSync, isFalse); expect(f.guest.service.canSync, isFalse);
      expect(p.guest.state, PairingHandshakeState.ready);
      if (!readback) expect(f.host.secrets.values[SyncMembershipStore.storageKey], before);
      f.host.secrets.failDefaultMember = false; f.host.secrets.corruptDefaultMember = false;
      await f.host.service.prepare('reload');
      final retry = await _pair(f.host.service, f.guest.service, control: !readback, recovery: true);
      await f.guest.service.recoverFromPairing(retry.guest,
          await f.host.service.finishHost(retry.host));
      expect(f.host.service.canSync, isTrue); expect(f.guest.service.canSync, isTrue);
    });
  }
}
