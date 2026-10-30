import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/seqpoint_core.dart'
    hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';
import 'transport/lan_revocation_test.dart' show RevokingCryptography;

void main() {
  test('sealed history remains readable across an epoch rotation', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    final shared = Directory('${f.root.path}/shared');
    final a = FolderTransport(shared, writerDeviceId: f.a.keys.deviceId);
    final b = FolderTransport(shared, writerDeviceId: f.b.keys.deviceId);
    f.a.addOperations(1);
    expect((await f.a.runtime.syncFolder(a)).isOk, isTrue);
    await rotateRuntimePair(f);
    f.a.addOperations(1, start: 1);
    expect((await f.a.runtime.syncFolder(a)).isOk, isTrue);
    final result = await f.b.runtime.syncFolder(b);
    expect(
      result.isOk,
      isTrue,
      reason: result is Err ? '${(result as Err).cause}' : null,
    );
    expect(result.valueOrNull!.pulled, 1);
    expect(
      f.b.db.raw
          .select("SELECT value_json FROM sync_operations WHERE object_id='n1'")
          .single['value_json'],
      '"value:1"',
    );
    expect(
      SyncSegmentReceiver(f.b.db).committedWatermarks[f.a.keys.deviceId],
      2,
    );
  });
  test('revocation during hashing prevents directory import and ACK', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    final shared = Directory('${f.root.path}/shared');
    final a = FolderTransport(shared, writerDeviceId: f.a.keys.deviceId);
    final b = FolderTransport(shared, writerDeviceId: f.b.keys.deviceId);
    f.a.addOperations(1);
    expect((await f.a.runtime.syncFolder(a)).isOk, isTrue);
    final view = f.a.runtime.publishedFiles();
    final frame = view[view.keys.singleWhere((p) => p.startsWith('ops/'))]!;
    final revoked = await MembershipReducer.restoreTrustedLocal(
      f.b.membership.toTrustedLocalJson(),
    );
    final event = await MembershipEvent.create(
      parent: revoked.state,
      issuer: f.a.keys,
      type: MembershipEventType.revoke,
      targetDeviceId: f.b.keys.deviceId,
    );
    await revoked.ingest(event, issuerFileDeviceId: f.a.keys.deviceId);
    final original = Cryptography.instance, crypto = RevokingCryptography();
    Cryptography.instance = crypto;
    addTearDown(() => Cryptography.instance = original);
    var fired = false;
    crypto.duringHash = (input) {
      if (!fired && input.toString() == frame.toString()) {
        fired = true;
        f.b.membership = revoked;
        f.b.version = Object();
      }
    };
    expect((await f.b.runtime.syncFolder(b)).isOk, isFalse);
    expect(fired, isTrue);
    expect(f.b.db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    expect(f.b.runtime.publishedFiles(), isEmpty);
    expect(
      await File('${shared.path}/acks/${f.b.keys.deviceId}.json').exists(),
      isFalse,
    );
  });
}
