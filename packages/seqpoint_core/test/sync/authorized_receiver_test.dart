import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import '../identity/membership_fixture.dart';
import 'sync_projector_test.dart' show facts;

Matcher blocked(String reason, MembershipSyncDecision decision) =>
    isA<SyncAuthorizationBlocked>()
        .having((e) => e.check.reason, 'reason', reason)
        .having((e) => e.check.decision, 'decision', decision);

void main() {
  late Directory directory;
  late SeqDatabase source, db;
  late SyncSegmentReceiver receiver;
  late MembershipSyncPolicy policy;
  late MembershipReducer membership;
  late DeviceKeys local, peer;
  late EncryptedSegmentCodec codec;
  late VerifiedSegment packet;
  var hasKey = true;
  Future<VerifiedSegment> frame({int epoch = 1, int seq = 1}) async {
    final segment = await codec.encode(Segment(deviceId: peer.deviceId,
        keyEpoch: epoch, seq: seq, opCount: facts(source).length,
        createdAt: DateTime.utc(2026), payload: const [], sealed: true), facts(source));
    return (segment: segment, operations: await codec.decode(segment), bytes: segment.encode());
  }
  String snapshot() => jsonEncode({for (final table in [
    'notes', 'sync_operations', 'sync_received_segments', 'sync_state', 'sync_local',
  ]) table: db.raw.select('SELECT * FROM $table')});
  setUp(() async {
    final f = await membershipFixture();
    membership = f.reducer; local = f.founder; peer = f.guest;
    directory = Directory.systemTemp.createTempSync('authorized-receiver-');
    source = SeqDatabase.inMemory()..migrate();
    db = SeqDatabase.open('${directory.path}/receiver.db')..migrate();
    source.raw.execute('UPDATE sync_local SET enabled=1,device_id=?', [f.guest.deviceId]);
    db.raw.execute('UPDATE sync_local SET enabled=1,device_id=?', [f.founder.deviceId]);
    NoteRepository(source).insert(Note(id: 'n', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '已认证业务',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    codec = EncryptedSegmentCodec(vaultPublicId: 'v1', deviceKeys: peer,
        epochKeys: {1: f.key.keyBytes, 2: List.filled(32, 20), 3: List.filled(32, 21)},
        trustedSigners: {peer.deviceId: peer.signer.publicKey});
    packet = await frame();
    hasKey = true;
    policy = MembershipSyncPolicy(membership: membership, localDeviceId: local.deviceId,
        hasEpochKey: (_) => hasKey);
    receiver = SyncSegmentReceiver.authorized(db, policy: policy);
  });
  tearDown(() { source.close(); db.close(); directory.deleteSync(recursive: true); });
  test('current key unavailable waits without importing or invoking ACK', () async {
    hasKey = false;
    var acknowledgments = 0;
    final before = snapshot();
    expect(policy.checkInbound(peerDeviceId: packet.segment.deviceId, keyEpoch: 1).isAllowed, isFalse);
    await expectLater(receiver.receive(packet, writeAck: (_) async { acknowledgments++; }), throwsStateError);
    expect(snapshot(), before);
    expect(db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    expect(db.raw.select('SELECT * FROM sync_state'), isEmpty);
    expect(acknowledgments, 0);
  });
  test('allowed encrypted segment commits durable proof before ACK', () async {
    await receiver.receive(packet, writeAck: (watermarks) async {
      expect(watermarks, {peer.deviceId: 1});
      expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
      expect(NoteRepository(db).byId('n')!.rawContent, '已认证业务');
    });
    expect(receiver.committedWatermarks, {peer.deviceId: 1});
  });
  test('policy local ID mismatch cannot import or invoke ACK', () async {
    receiver = SyncSegmentReceiver.authorized(db, policy: MembershipSyncPolicy(
        membership: membership, localDeviceId: peer.deviceId, hasEpochKey: (_) => true));
    final before = snapshot();
    var acknowledgments = 0;
    await expectLater(receiver.receive(packet, writeAck: (_) async { acknowledgments++; }),
        throwsA(isA<StateError>().having((e) => e.message, 'reason', 'policy-local-id-mismatch')));
    await expectLater(receiver.retryAck((_) async { acknowledgments++; }), throwsStateError);
    expect(snapshot(), before);
    expect(acknowledgments, 0);
  });
  test('rotation waits for old history, future epoch and missing current key', () async {
    final rotate = await MembershipEvent.create(parent: membership.state, issuer: local,
        type: MembershipEventType.rotate, epochKey: VaultKey(epoch: 2, keyBytes: List.filled(32, 20)));
    await membership.ingest(rotate, issuerFileDeviceId: local.deviceId);
    final before = snapshot();
    var acknowledgments = 0;
    for (final (epoch, reason) in [(1, 'history-cutoff-unproven'), (3, 'future-epoch')]) {
      await expectLater(receiver.receive(await frame(epoch: epoch),
          writeAck: (_) async { acknowledgments++; }),
          throwsA(blocked(reason, MembershipSyncDecision.waiting)));
    }
    hasKey = false;
    await expectLater(receiver.receive(await frame(epoch: 2),
        writeAck: (_) async { acknowledgments++; }),
        throwsA(blocked('epoch-key-unavailable', MembershipSyncDecision.waiting)));
    expect(snapshot(), before);
    expect(acknowledgments, 0);
    hasKey = true;
    expect((await receiver.apply(await frame(epoch: 2))).appliedSeq, 1);
  });
  test('revoked local identity cannot import or retry ACK and keeps durable history', () async {
    await receiver.apply(packet);
    final revoke = await MembershipEvent.create(parent: membership.state, issuer: peer,
        type: MembershipEventType.revoke, targetDeviceId: local.deviceId);
    await membership.ingest(revoke, issuerFileDeviceId: peer.deviceId);
    final before = snapshot();
    var acknowledgments = 0;
    await expectLater(receiver.receive(packet, writeAck: (_) async { acknowledgments++; }),
        throwsA(blocked('local-not-member', MembershipSyncDecision.rejected)));
    await expectLater(receiver.retryAck((_) async { acknowledgments++; }),
        throwsA(blocked('local-not-member', MembershipSyncDecision.rejected)));
    expect(snapshot(), before);
    expect(receiver.committedWatermarks, {peer.deviceId: 1});
    expect(acknowledgments, 0);
  });
  test('membership conflict stops imports and new ACK attempts while retaining proof', () async {
    await receiver.apply(packet);
    final parent = membership.state;
    final a = await MembershipEvent.create(parent: parent, issuer: local, type: MembershipEventType.rotate);
    final b = await MembershipEvent.create(parent: parent, issuer: peer, type: MembershipEventType.rotate);
    await membership.ingest(a, issuerFileDeviceId: local.deviceId);
    await membership.ingest(b, issuerFileDeviceId: peer.deviceId);
    final before = snapshot();
    var acknowledgments = 0;
    await expectLater(receiver.receive(packet, writeAck: (_) async { acknowledgments++; }),
        throwsA(blocked('conflict', MembershipSyncDecision.rejected)));
    await expectLater(receiver.retryAck((_) async { acknowledgments++; }),
        throwsA(blocked('conflict', MembershipSyncDecision.rejected)));
    expect(snapshot(), before);
    expect(receiver.committedWatermarks, {peer.deviceId: 1});
    expect(acknowledgments, 0);
  });
  test('queued ACK rechecks current key after an earlier async callback finishes', () async {
    await receiver.apply(packet);
    final started = Completer<void>(), resume = Completer<void>();
    final first = receiver.retryAck((watermarks) async {
      expect(watermarks, {peer.deviceId: 1});
      started.complete(); await resume.future;
    });
    await started.future;
    var acknowledgments = 0;
    final second = receiver.retryAck((_) async { acknowledgments++; });
    hasKey = false;
    final rejected = expectLater(second,
        throwsA(blocked('epoch-key-unavailable', MembershipSyncDecision.waiting)));
    resume.complete(); await first; await rejected;
    expect(acknowledgments, 0);
    expect(receiver.committedWatermarks, {peer.deviceId: 1});
    hasKey = true;
    await receiver.retryAck((watermarks) async { expect(watermarks, {peer.deviceId: 1}); });
  });
  test('revocation holds old history and rejects current or future imports without deleting history', () async {
    await receiver.receive(packet, writeAck: (_) async {});
    final revoke = await MembershipEvent.create(parent: membership.state, issuer: local,
        type: MembershipEventType.revoke, targetDeviceId: peer.deviceId);
    await membership.ingest(revoke, issuerFileDeviceId: local.deviceId);
    final before = snapshot();
    var acknowledgments = 0;
    await expectLater(receiver.receive(packet, writeAck: (_) async { acknowledgments++; }),
        throwsA(blocked('history-cutoff-unproven', MembershipSyncDecision.waiting)));
    for (final epoch in [2, 3]) {
      await expectLater(receiver.receive(await frame(epoch: epoch, seq: 2),
          writeAck: (_) async { acknowledgments++; }),
          throwsA(blocked('peer-not-member', MembershipSyncDecision.rejected)));
    }
    expect(snapshot(), before);
    expect(receiver.committedWatermarks, {peer.deviceId: 1});
    expect(NoteRepository(db).byId('n')!.rawContent, '已认证业务');
    expect(acknowledgments, 0);
  });
  for (final change in ['peer-revoke', 'local-revoke', 'rotate']) {
    test('$change during hash blocks without importing or acknowledging', () async {
      final type = change == 'rotate' ? MembershipEventType.rotate : MembershipEventType.revoke;
      final event = await MembershipEvent.create(parent: membership.state, issuer: local,
          type: type, targetDeviceId: type == MembershipEventType.revoke ? peer.deviceId : null);
      final localRevoke = change == 'local-revoke'
          ? await MembershipEvent.create(parent: membership.state, issuer: peer,
              type: MembershipEventType.revoke, targetDeviceId: local.deviceId) : null;
      final started = Completer<void>(), resume = Completer<void>();
      final original = Cryptography.instance, before = snapshot();
      var acknowledgments = 0;
      Cryptography.instance = _PausedCryptography(started, resume);
      try {
        final pending = receiver.receive(packet, writeAck: (_) async { acknowledgments++; });
        await started.future;
        Cryptography.instance = original;
        await membership.ingest(localRevoke ?? event,
            issuerFileDeviceId: localRevoke == null ? local.deviceId : peer.deviceId);
        final rejected = expectLater(pending,
            throwsA(localRevoke == null
                ? blocked('history-cutoff-unproven', MembershipSyncDecision.waiting)
                : blocked('local-not-member', MembershipSyncDecision.rejected)));
        resume.complete();
        await rejected;
      } finally { Cryptography.instance = original; if (!resume.isCompleted) resume.complete(); }
      expect(snapshot(), before);
      expect(acknowledgments, 0);
    });
  }
}

class _PausedCryptography extends DartCryptography {
  _PausedCryptography(this.started, this.resume);
  final Completer<void> started, resume;
  @override
  Sha256 sha256() => _PausedSha256(started, resume);
}

class _PausedSha256 extends DartSha256 {
  const _PausedSha256(this.started, this.resume);
  final Completer<void> started, resume;
  @override
  Future<Hash> hash(List<int> input) async {
    started.complete();
    await resume.future;
    return super.hash(input);
  }
}
