import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'transport/lan_revocation_test.dart' show RevokingCryptography;

void main() {
  test('verified local revocation during receiver hashing prevents transaction and ACK', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    f.a.addOperations(1);
    await f.start();
    expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
    final frame = f.a.runtime
        .publishedFiles()
        .entries
        .singleWhere((entry) => entry.key.startsWith('ops/'))
        .value;
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
    addTearDown(() {
      Cryptography.instance = original;
    });
    var fired = false;
    crypto.duringHash = (input) {
      if (!fired && input.toString() == frame.toString()) {
        fired = true;
        f.b.membership = revoked;
        f.b.version = Object();
      }
    };
    expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
    expect(fired, isTrue);
    expect(f.b.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    expect(f.b.db.raw.select('SELECT * FROM sync_received_segments'), isEmpty);
    expect(f.b.runtime.publishedFiles(), isEmpty);
    expect(f.b.reconciled, 0);
  });
}
