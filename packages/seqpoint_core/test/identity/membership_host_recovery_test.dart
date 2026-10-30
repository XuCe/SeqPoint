import 'dart:convert';
import 'package:cryptography/cryptography.dart' show Sha256;
import 'package:seqpoint_core/seqpoint_core.dart' show DeviceKeys, PairingHandshake, VaultKey;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';
import 'membership_fixture.dart';
import 'membership_pairing_test.dart' show confirmedMembership;
import 'pairing_handshake_test.dart' show pairedFixture;
import 'pairing_epoch_test.dart' show confirmPair;

Future<MembershipReducer> _conflicted() async {
  final f = await membershipFixture(), parent = f.reducer.state;
  final a = await MembershipEvent.create(parent: parent, issuer: f.founder,
      type: MembershipEventType.rotate);
  final b = await MembershipEvent.create(parent: parent, issuer: f.guest,
      type: MembershipEventType.rotate);
  await f.reducer.ingest(a, issuerFileDeviceId: f.founder.deviceId);
  await f.reducer.ingest(b, issuerFileDeviceId: f.guest.deviceId);
  final pending = await MembershipEvent.create(parent: f.reducer.state,
      issuer: f.founder, type: MembershipEventType.rotate);
  await f.reducer.ingest(pending, issuerFileDeviceId: f.founder.deviceId);
  return f.reducer;
}

Future<({PairingHandshake host, PairingHandshake guest})> _pairedCheckpoint(
    Map<String, Object?> checkpoint, VaultKey key) async {
  final f = await pairedFixture();
  await confirmPair(f.host, f.guest);
  final digest = await Sha256().hash(utf8.encode(jsonEncode(checkpoint)));
  final hash = base64UrlEncode(digest.bytes).replaceAll('=', '');
  final envelope = await f.host.sealEpoch(key, checkpointHash: hash);
  await f.guest.openEpoch(envelope);
  return (host: f.host, guest: f.guest);
}

Future<({MembershipReducer ancestor, MembershipReducer previous})> _nestedConflict() async {
  final ancestor = await _conflicted(), next = await confirmedMembership(epoch: 3);
  final previous = await MembershipReducer.recoverFromHostedPairing(previous: ancestor,
      session: next.host, checkpoint: next.reducer.state.toJson());
  final parent = previous.state;
  for (final seeds in [(1, 2), (3, 4)]) {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, seeds.$1), List.filled(32, seeds.$2));
    final event = await MembershipEvent.create(parent: parent, issuer: keys,
        type: MembershipEventType.rotate);
    await previous.ingest(event, issuerFileDeviceId: keys.deviceId);
  }
  return (ancestor: ancestor, previous: previous);
}

void main() {
  test('再次合法恢复保留递归隔离和pending审计，祖先key仍不可复用', () async {
    final old = await _nestedConflict(), next = await confirmedMembership(epoch: 5, keyByte: 43);
    final reused = await confirmedMembership(epoch: 5, keyByte: 7);
    await expectLater(MembershipReducer.recoverFromHostedPairing(previous: old.previous,
        session: reused.host, checkpoint: reused.reducer.state.toJson()), throwsStateError);
    final before = old.previous.toTrustedLocalJson();
    final recovered = await MembershipReducer.recoverFromHostedPairing(previous: old.previous,
        session: next.host, checkpoint: next.reducer.state.toJson());
    expect(recovered.isolatedControlRecords, [before]);
    final reopened = await MembershipReducer.restoreTrustedLocal(recovered.toTrustedLocalJson());
    expect(reopened.isolatedControlRecords, [before]);
    final previousRecord = reopened.isolatedControlRecords.single;
    expect(previousRecord['isolated'], [old.ancestor.toTrustedLocalJson()]);
    expect((old.ancestor.toTrustedLocalJson()['pending'] as List), isNotEmpty);
    expect(old.previous.toTrustedLocalJson(), before);
  });
  test('本机恢复记录同样拒绝嵌套isolated祖先域重用', () async {
    final old = await _nestedConflict(), next = await confirmedMembership(epoch: 5, keyByte: 43);
    final checkpoint = next.reducer.state.toJson()..['authority_id'] = old.ancestor.state.authorityId;
    final pair = await _pairedCheckpoint(checkpoint, next.key);
    final anchor = await MembershipState.fromHostedPairing(session: pair.host, checkpoint: checkpoint);
    final record = MembershipReducer(trustedAnchor: anchor).toTrustedLocalJson()
      ..['isolated'] = [old.previous.toTrustedLocalJson()];
    await expectLater(MembershipReducer.restoreTrustedLocal(record), throwsFormatException);
  });
  for (final hosted in [false, true]) {
    test('${hosted ? 'host' : 'guest'}重锚不能复用递归隔离祖先授权域', () async {
      final old = await _nestedConflict(), next = await confirmedMembership(epoch: 5, keyByte: 43);
      final checkpoint = next.reducer.state.toJson()..['authority_id'] = old.ancestor.state.authorityId;
      final pair = await _pairedCheckpoint(checkpoint, next.key);
      final before = old.previous.toTrustedLocalJson();
      await expectLater(hosted
          ? MembershipReducer.recoverFromHostedPairing(previous: old.previous,
              session: pair.host, checkpoint: checkpoint)
          : MembershipReducer.recoverFromConfirmedPairing(previous: old.previous,
              session: pair.guest, checkpoint: checkpoint), throwsStateError);
      expect(old.previous.toTrustedLocalJson(), before);
    });
  }
  test('两端完成的重新确认会话绑定同一检查点', () async {
    final next = await confirmedMembership(epoch: 3);
    final pair = await _pairedCheckpoint(next.reducer.state.toJson(), next.key);
    expect((await MembershipState.fromHostedPairing(session: pair.host,
        checkpoint: next.reducer.state.toJson())).headHash, next.reducer.state.headHash);
    expect((await MembershipState.fromConfirmedPairing(session: pair.guest,
        checkpoint: next.reducer.state.toJson())).headHash, next.reducer.state.headHash);
  });
  test('完成seal的host能恢复新域，保留全部冲突审计并可重开', () async {
    final previous = await _conflicted(), next = await confirmedMembership(epoch: 3);
    final before = previous.toTrustedLocalJson();
    final state = await MembershipState.fromHostedPairing(session: next.host,
        checkpoint: next.reducer.state.toJson());
    expect(state.headHash, next.reducer.state.headHash);
    final recovered = await MembershipReducer.recoverFromHostedPairing(
        previous: previous, session: next.host, checkpoint: next.reducer.state.toJson());
    expect(recovered.isConflicted, isFalse);
    expect(recovered.state.authorityId, isNot(previous.state.authorityId));
    expect(recovered.isolatedControlRecords, [before]);
    expect(previous.toTrustedLocalJson(), before);
    final reopened = await MembershipReducer.restoreTrustedLocal(recovered.toTrustedLocalJson());
    expect(reopened.state.headHash, state.headHash);
    expect(reopened.isolatedControlRecords, [before]);
  });

  test('host入口拒绝guest与未完成会话，guest原入口仍拒host', () async {
    final previous = await _conflicted(), next = await confirmedMembership(epoch: 3);
    final before = previous.toTrustedLocalJson(), checkpoint = next.reducer.state.toJson();
    await expectLater(MembershipState.fromHostedPairing(session: next.guest,
        checkpoint: checkpoint), throwsStateError);
    await expectLater(MembershipState.fromConfirmedPairing(session: next.host,
        checkpoint: checkpoint), throwsStateError);
    await expectLater(MembershipReducer.recoverFromHostedPairing(previous: previous,
        session: next.guest, checkpoint: checkpoint), throwsStateError);
    final pending = await pairedFixture();
    await expectLater(MembershipState.fromHostedPairing(session: pending.host,
        checkpoint: checkpoint), throwsStateError);
    await confirmPair(pending.host, pending.guest);
    await expectLater(MembershipState.fromHostedPairing(session: pending.host,
        checkpoint: checkpoint), throwsStateError);
    expect(previous.toTrustedLocalJson(), before);
  });

  test('host确认hash不能被替换，密文绑定检查点仍须双方完整身份', () async {
    final previous = await _conflicted(), next = await confirmedMembership(epoch: 3);
    final changed = next.reducer.state.toJson()..['epoch'] = 4;
    await expectLater(MembershipState.fromHostedPairing(session: next.host,
        checkpoint: changed), throwsStateError);
    final missingGuest = await confirmedMembership(epoch: 3, addGuest: false);
    await expectLater(MembershipState.fromHostedPairing(session: missingGuest.host,
        checkpoint: missingGuest.reducer.state.toJson()), throwsStateError);
    await expectLater(MembershipReducer.recoverFromHostedPairing(previous: previous,
        session: missingGuest.host, checkpoint: missingGuest.reducer.state.toJson()), throwsStateError);
  });

  test('host恢复仍要求旧冲突、全新域、更高Epoch和未用过的key', () async {
    final previous = await _conflicted(), next = await confirmedMembership(epoch: 3);
    final normal = await membershipFixture();
    await expectLater(MembershipReducer.recoverFromHostedPairing(previous: normal.reducer,
        session: next.host, checkpoint: next.reducer.state.toJson()), throwsStateError);
    for (final bad in [await confirmedMembership(epoch: 2),
        await confirmedMembership(epoch: 3, keyByte: 7)]) {
      await expectLater(MembershipReducer.recoverFromHostedPairing(previous: previous,
          session: bad.host, checkpoint: bad.reducer.state.toJson()), throwsStateError);
    }
    final checkpoint = next.reducer.state.toJson()..['authority_id'] = previous.state.authorityId;
    final pair = await _pairedCheckpoint(checkpoint, next.key);
    await expectLater(MembershipReducer.recoverFromHostedPairing(previous: previous,
        session: pair.host, checkpoint: checkpoint), throwsStateError);
    expect(previous.isConflicted, isTrue);
  });

  for (final mismatch in ['vault', 'tls', 'epoch', 'commitment']) {
    test('新SAS绑定的检查点仍拒绝$mismatch不匹配', () async {
      final next = await confirmedMembership(epoch: 3), checkpoint = next.reducer.state.toJson();
      if (mismatch == 'vault') checkpoint['vault_id'] = 'other';
      if (mismatch == 'tls') ((checkpoint['members'] as List).first as Map)['tls_sha256'] = 'c' * 64;
      if (mismatch == 'epoch') checkpoint['epoch'] = 4;
      if (mismatch == 'commitment') {
        checkpoint['key_commitment'] = 'A' * 43;
        checkpoint['key_commitments'] = ['A' * 43];
      }
      final pair = await _pairedCheckpoint(checkpoint, next.key);
      await expectLater(MembershipState.fromHostedPairing(session: pair.host,
          checkpoint: checkpoint), throwsStateError);
    });
  }
}
