import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_membership_controller.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  String? value;
  bool failWrite = false, corruptReadback = false, _badRead = false;
  Completer<void>? writeGate;
  @override
  Future<String?> read(String key) async {
    if (_badRead) { _badRead = false; return '{}'; }
    return value;
  }
  @override
  Future<void> write(String key, String text) async {
    await writeGate?.future;
    if (failWrite) throw StateError('test-write-failure');
    value = text;
    _badRead = corruptReadback;
  }
}

Future<({DeviceKeys host, DeviceKeys guest, VaultKey key,
    MembershipReducer membership, MembershipEvent add})> _fixture([int epoch = 1]) async {
  final host = await DeviceKeys.fromSeeds(List.filled(32, 7), List.filled(32, 8));
  final guest = await DeviceKeys.fromSeeds(List.filled(32, 9), List.filled(32, 10));
  final key = VaultKey(epoch: epoch, keyBytes: List.filled(32, epoch + 41));
  final anchor = await MembershipState.createVault(founder: host,
      vaultPublicId: 'vault', epochKey: key, tlsFingerprint: 'a' * 64);
  final membership = MembershipReducer(trustedAnchor: anchor);
  final add = await MembershipEvent.create(parent: anchor, issuer: host,
      type: MembershipEventType.add, epochKey: key,
      subject: MemberKeys(deviceId: guest.deviceId,
          signingPublicKey: guest.signer.publicKey,
          exchangePublicKey: guest.exchangePublicKey, tlsFingerprint: 'b' * 64));
  await membership.ingest(add, issuerFileDeviceId: host.deviceId);
  return (host: host, guest: guest, key: key, membership: membership, add: add);
}

MembershipFile _file(MembershipState state, String issuer,
    List<MembershipEvent> events) => MembershipFile(vaultPublicId: state.vaultPublicId,
        authorityId: state.authorityId, issuerDeviceId: issuer, events: events);

Future<PairingHandshake> _pair(DeviceKeys hostKeys, DeviceKeys guestKeys,
    MembershipState state, VaultKey key) async {
  final clock = FakeClock(DateTime.utc(2026, 10, 26));
  final invitation = await PairingInvitation.create(keys: hostKeys,
      vaultPublicId: 'vault', tlsFingerprint: 'a' * 64, clock: clock);
  final guest = await PairingHandshake.respond(keys: guestKeys, clock: clock,
      invitation: await PairingInvitation.fromQr(invitation.toQrPayload(), clock: clock),
      tlsFingerprint: 'b' * 64);
  final host = await PairingHandshake.acceptResponse(invitation: invitation,
      keys: hostKeys, response: guest.response.toJson(), clock: clock);
  final hp = await host.confirmShortCode(host.shortCode);
  final gp = await guest.confirmShortCode(guest.shortCode);
  await host.acceptConfirmation(gp);
  await guest.acceptConfirmation(hp);
  await guest.openEpoch(await host.sealEpoch(key, checkpointHash: state.headHash));
  return guest;
}

void main() {
  test('stop reentered from the stopping listener shares one drain and one future', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final nested = <Future<void>>[];
    final states = <SyncMembershipControllerState>[];
    final subscription = controller.changes.listen((_) {
      states.add(controller.state);
      if (controller.state == SyncMembershipControllerState.stopping) {
        nested.add(controller.stop());
      }
    });
    final stopping = controller.stop();
    await Future.wait([stopping, ...nested]);
    expect(nested, hasLength(1));
    expect(nested.single, same(stopping));
    expect(controller.stop(), same(stopping));
    expect(states, [SyncMembershipControllerState.stopping,
        SyncMembershipControllerState.stopped]);
    await subscription.cancel();
  });

  test('public control authorization includes self and active peers without an epoch key', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    expect(controller.current!.isUsable, isFalse);
    expect(controller.authorize('vault', f.host.deviceId), isNotNull);
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    expect(controller.authorize('other', f.guest.deviceId), isNull);
    expect(controller.authorize('vault', 'unknown'), isNull);
    expect(controller.policy!.checkSession(f.guest.deviceId).isAllowed, isTrue);
    expect(controller.policy!.checkLocalPublication(keyEpoch: 1).isAllowed, isFalse);
    expect(controller.policy!.checkInbound(peerDeviceId: f.guest.deviceId,
        keyEpoch: 1).isAllowed, isFalse);
    final loading = controller.load();
    expect(controller.authorize('vault', f.host.deviceId), isNull);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    await loading;
    expect(controller.authorize('vault', f.host.deviceId), isNotNull);
    await controller.stop();
  });

  test('unconfirmed pairing cannot write or enable a network checkpoint', () async {
    final f = await _fixture(), secrets = _Secrets();
    final invitation = await PairingInvitation.create(keys: f.host,
        vaultPublicId: 'vault', tlsFingerprint: 'a' * 64);
    final session = await PairingHandshake.respond(keys: f.guest,
        invitation: await PairingInvitation.fromQr(invitation.toQrPayload()), tlsFingerprint: 'b' * 64);
    final controller = SyncMembershipController(store: SyncMembershipStore(secrets), localDevice: f.guest);
    await expectLater(controller.initializeFromPairing(session: session,
        checkpoint: f.membership.state.toJson(), epochKey: f.key), throwsStateError);
    expect(secrets.value, isNull);
    expect(controller.current, isNull);
    expect(controller.authorize('vault', f.host.deviceId), isNull);
    await controller.stop();
  });

  test('signed public revocation persists even when the retained local envelope cannot open', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final revoke = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    final wire = revoke.toJson();
    final envelopes = wire['envelopes'] as List;
    final envelope = Map<String, Object?>.from(envelopes.single as Map);
    final frame = base64Url.decode(base64Url.normalize(envelope['frame'] as String));
    frame[frame.length - 1] ^= 1;
    envelope['frame'] = base64UrlEncode(frame).replaceAll('=', '');
    wire['envelopes'] = [envelope];
    final altered = MembershipEvent.fromJson(wire);
    wire['signature'] = base64UrlEncode(await f.host.signer.sign(altered.signingBytes)).replaceAll('=', '');
    final signed = MembershipEvent.fromJson(wire);
    final saved = await controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, signed]).encode());
    expect(saved.state.revokedIds, contains(f.guest.deviceId));
    expect(saved.epochKey, isNull);
    expect(saved.isUsable, isFalse);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    expect((await store.load(f.host))!.state.revokedIds, contains(f.guest.deviceId));
    await controller.stop();
  });

  test('conflict can recover only through explicit confirmed pairing and retains old evidence', () async {
    final old = await _fixture(), secrets = _Secrets();
    final parent = old.membership.state;
    final a = await MembershipEvent.create(parent: parent, issuer: old.host,
        type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: parent, issuer: old.guest,
        type: MembershipEventType.rotate);
    await old.membership.ingest(a, issuerFileDeviceId: old.host.deviceId);
    await old.membership.ingest(b, issuerFileDeviceId: old.guest.deviceId);
    final store = SyncMembershipStore(secrets);
    await store.save(membership: old.membership, localDevice: old.guest);
    final controller = SyncMembershipController(store: store, localDevice: old.guest);
    await controller.load();
    expect(controller.authorize('vault', old.host.deviceId), isNull);
    final fresh = await _fixture(3);
    final session = await _pair(fresh.host, fresh.guest, fresh.membership.state, fresh.key);
    secrets.failWrite = true;
    await expectLater(controller.recoverFromPairing(session: session,
        checkpoint: fresh.membership.state.toJson(), epochKey: fresh.key), throwsStateError);
    expect(controller.authorize('vault', old.host.deviceId), isNull);
    secrets.failWrite = false;
    await controller.load();
    final saved = await controller.recoverFromPairing(session: session,
        checkpoint: fresh.membership.state.toJson(), epochKey: fresh.key);
    expect(saved.isUsable, isTrue);
    expect(saved.membership.isolatedControlRecords, hasLength(1));
    expect(controller.authorize('vault', fresh.host.deviceId), isNotNull);
    expect((await store.load(fresh.guest))!.state.authorityId, fresh.membership.state.authorityId);
    await controller.stop();
  });

  test('confirmed pairing initializes only after atomic save and cannot replace an existing anchor', () async {
    final f = await _fixture(), secrets = _Secrets();
    final session = await _pair(f.host, f.guest, f.membership.state, f.key);
    final store = SyncMembershipStore(secrets);
    final controller = SyncMembershipController(store: store, localDevice: f.guest);
    secrets.writeGate = Completer<void>();
    final saving = controller.initializeFromPairing(session: session,
        checkpoint: f.membership.state.toJson(), epochKey: f.key);
    expect(controller.authorize('vault', f.host.deviceId), isNull);
    expect(controller.current, isNull);
    secrets.writeGate!.complete();
    final saved = await saving;
    expect(saved.isUsable, isTrue);
    expect(controller.authorize('vault', f.host.deviceId), isNotNull);
    expect((await store.load(f.guest))!.state.headHash, saved.state.headHash);
    final before = secrets.value;
    await expectLater(controller.initializeFromPairing(session: session,
        checkpoint: f.membership.state.toJson(), epochKey: f.key), throwsStateError);
    expect(secrets.value, before);
    expect(controller.authorize('vault', f.host.deviceId), isNull);
    await controller.stop();
  });

  test('structurally invalid suffix rejects whole file and preserves earlier durable prefix', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    final file = _file(f.membership.state, f.host.deviceId, [f.add, rotate]);
    final json = Map<String, Object?>.from(jsonDecode(utf8.decode(file.encode())) as Map);
    (json['events'] as List).add({'signature': 'broken'});
    final before = secrets.value;
    await expectLater(controller.ingest(path: file.path,
        bytes: utf8.encode(jsonEncode(json))), throwsStateError);
    expect(secrets.value, before);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    await controller.load();
    expect(controller.current!.state.epoch, 1);
    await controller.stop();
  });

  test('own issuer history is idempotent and rejects truncation or reordered files after reopen', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    final file = _file(f.membership.state, f.host.deviceId, [f.add, rotate]);
    await controller.ingest(path: file.path, bytes: file.encode());
    await controller.ingest(path: file.path, bytes: file.encode());
    expect(controller.current!.membership.evidence, hasLength(2));
    await controller.stop();
    final reopened = SyncMembershipController(store: store, localDevice: f.host);
    await reopened.load();
    final reordered = Map<String, Object?>.from(jsonDecode(utf8.decode(file.encode())) as Map);
    reordered['events'] = (reordered['events'] as List).reversed.toList();
    final cases = [
      (path: file.path, bytes: _file(f.membership.state, f.host.deviceId, [f.add]).encode()),
      (path: file.path, bytes: utf8.encode(jsonEncode(reordered))),
      (path: 'members/${f.guest.deviceId}.json', bytes: file.encode()),
      (path: '${file.path}\n', bytes: file.encode()),
    ];
    for (final invalid in cases) {
      final before = secrets.value;
      await expectLater(reopened.ingest(path: invalid.path, bytes: invalid.bytes), throwsStateError);
      expect(secrets.value, before);
      expect(reopened.authorize('vault', f.guest.deviceId), isNull);
      await reopened.load();
      expect(reopened.current!.state.epoch, 2);
    }
    await reopened.stop();
  });

  test('consumer mutations cannot change private authority or published saved facts', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final before = controller.publishedControlFiles();
    final revoke = await MembershipEvent.create(parent: controller.current!.state,
        issuer: f.host, type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    await controller.current!.membership.ingest(revoke, issuerFileDeviceId: f.host.deviceId);
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    expect(controller.policy!.checkSession(f.guest.deviceId).isAllowed, isTrue);
    expect(controller.publishedControlFiles(), same(before));
    expect(() => before.clear(), throwsUnsupportedError);
    expect(() => before.values.single.clear(), throwsUnsupportedError);
    await controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add]).encode());
    expect(controller.current!.state.revokedIds, isEmpty);
    expect(controller.authorize('other', f.guest.deviceId), isNull);
    expect(controller.authorize('vault', f.host.deviceId), isNotNull);
    await controller.stop();
  });

  test('public JSON cannot bootstrap and only explicit vault creation saves an anchor', () async {
    final f = await _fixture(), secrets = _Secrets();
    final controller = SyncMembershipController(store: SyncMembershipStore(secrets), localDevice: f.host);
    expect(await controller.load(), isNull);
    await expectLater(controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add]).encode()), throwsStateError);
    expect(secrets.value, isNull);
    expect(controller.current, isNull);
    await controller.load();
    secrets.writeGate = Completer<void>();
    final creating = controller.createVault(vaultPublicId: 'vault', epochKey: f.key,
        tlsFingerprint: 'a' * 64);
    expect(controller.current, isNull);
    expect(controller.state, SyncMembershipControllerState.updating);
    secrets.writeGate!.complete();
    final saved = await creating;
    expect(saved.isUsable, isTrue);
    expect(saved.state.members.keys, [f.host.deviceId]);
    final version = controller.version;
    expect(controller.version, same(version));
    await expectLater(controller.createVault(vaultPublicId: 'other', epochKey: f.key,
        tlsFingerprint: 'a' * 64), throwsStateError);
    await controller.load();
    expect(controller.current!.state.vaultPublicId, 'vault');
    await controller.stop();
  });

  test('stop from synchronous change listener drains the just accepted mutation', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    secrets.writeGate = Completer<void>();
    Future<void>? stopping;
    var stopped = false;
    final subscription = controller.changes.listen((_) {
      if (controller.state == SyncMembershipControllerState.updating) {
        stopping ??= controller.stop().then((_) { stopped = true; });
      }
    });
    final saving = controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, rotate]).encode());
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(stopped, isFalse);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    secrets.writeGate!.complete();
    await saving;
    await stopping;
    expect(stopped, isTrue);
    expect(controller.state, SyncMembershipControllerState.stopped);
    await expectLater(controller.load(), throwsStateError);
    expect((await store.load(f.host))!.state.epoch, 2);
    await subscription.cancel();
  });

  test('unknown parents persist pending and later drain without publishing remote files', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final parent = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.guest, type: MembershipEventType.rotate);
    await f.membership.ingest(parent, issuerFileDeviceId: f.guest.deviceId);
    final child = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    await controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, child]).encode());
    expect(controller.current!.state.epoch, 1);
    expect((await store.load(f.host))!.membership.pendingEvents.single.eventId, child.eventId);
    expect(controller.publishedControlFiles().keys, ['members/${f.host.deviceId}.json']);
    final beforeParent = jsonDecode(utf8.decode(controller.publishedControlFiles().values.single)) as Map;
    expect(beforeParent['events'], hasLength(1));
    await controller.ingest(path: 'members/${f.guest.deviceId}.json',
        bytes: _file(f.membership.state, f.guest.deviceId, [parent]).encode());
    expect(controller.current!.state.epoch, 3);
    expect(controller.current!.membership.pendingEvents, isEmpty);
    final own = MembershipFile.decode(controller.publishedControlFiles().values.single,
        issuerFileDeviceId: f.host.deviceId, expectedVaultPublicId: 'vault',
        expectedAuthorityId: f.membership.state.authorityId);
    expect(own.events.map((e) => e.eventId), [f.add.eventId, child.eventId]);
    await controller.stop();
  });

  test('invalid signed suffix preserves valid prefix durably but remains blocked', () async {
    final f = await _fixture(), secrets = _Secrets();
    final actual = SyncMembershipStore(secrets);
    await actual.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: actual, localDevice: f.host);
    await controller.load();
    final valid = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    await f.membership.ingest(valid, issuerFileDeviceId: f.host.deviceId);
    final suffix = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    final bad = MembershipEvent.fromJson({...suffix.toJson(), 'signature': base64UrlEncode(List.filled(64, 0)).replaceAll('=', '')});
    await expectLater(controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, valid, bad]).encode()), throwsStateError);
    expect((await actual.load(f.host))!.state.epoch, 2);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    await controller.load();
    expect(controller.current!.state.epoch, 2);
    await controller.stop();
  });

  test('failed read-back reloads the newly written record, never cached old authority', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    secrets.corruptReadback = true;
    await expectLater(controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, rotate]).encode()), throwsStateError);
    expect(controller.current!.state.epoch, 1);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    secrets.corruptReadback = false;
    await controller.load();
    expect(controller.current!.state.epoch, 2);
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    await controller.stop();
  });

  test('public local revocation is saved without an available new epoch key', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.guest, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.guest);
    await controller.load();
    final revoke = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.revoke, targetDeviceId: f.guest.deviceId);
    final saved = await controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, revoke]).encode());
    expect(saved.epochKey, isNull);
    expect(saved.isUsable, isFalse);
    expect(controller.authorize('vault', f.host.deviceId), isNull);
    final reopened = (await store.load(f.guest))!;
    expect(reopened.state.revokedIds, contains(f.guest.deviceId));
    expect(reopened.epochKey, isNull);
    await controller.stop();
  });

  test('mutation blocks old authority synchronously and only activates read-back', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final before = controller.current;
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    secrets.writeGate = Completer<void>();
    final saving = controller.ingest(path: 'members/${f.host.deviceId}.json',
        bytes: _file(f.membership.state, f.host.deviceId, [f.add, rotate]).encode());
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    expect(controller.current, same(before));
    expect(controller.policy, isNull);
    await Future<void>.delayed(Duration.zero);
    secrets.writeGate!.complete();
    final saved = await saving;
    expect(saved.state.epoch, 2);
    expect(controller.current, same(saved));
    expect(saved.isUsable, isTrue);
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    expect(before!.state.epoch, 1);
    await controller.stop();
  });

  test('write failure latches authority off until explicit reload of actual record', () async {
    final f = await _fixture(), secrets = _Secrets();
    final store = SyncMembershipStore(secrets);
    await store.save(membership: f.membership, localDevice: f.host, epochKey: f.key);
    final controller = SyncMembershipController(store: store, localDevice: f.host);
    await controller.load();
    final oldVersion = controller.version;
    final rotate = await MembershipEvent.create(parent: f.membership.state,
        issuer: f.host, type: MembershipEventType.rotate);
    final bytes = _file(f.membership.state, f.host.deviceId, [f.add, rotate]).encode();
    secrets.failWrite = true;
    await expectLater(controller.ingest(path: 'members/${f.host.deviceId}.json', bytes: bytes), throwsStateError);
    expect(controller.version, isNot(same(oldVersion)));
    expect(controller.state, SyncMembershipControllerState.blocked);
    expect(controller.authorize('vault', f.guest.deviceId), isNull);
    expect(controller.publishedControlFiles(), isEmpty);
    secrets.failWrite = false;
    await expectLater(controller.ingest(path: 'members/${f.host.deviceId}.json', bytes: bytes), throwsStateError);
    await controller.load();
    expect(controller.current!.state.epoch, 1);
    expect(controller.authorize('vault', f.guest.deviceId), isNotNull);
    await controller.stop();
  });
}
