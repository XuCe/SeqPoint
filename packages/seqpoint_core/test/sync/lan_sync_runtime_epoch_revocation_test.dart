import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';
import 'transport/lan_revocation_test.dart' show RevokingCryptography;

void main() {
  for (final change in ['revocation', 'stop']) {
    test(
      'historical seal hashing rechecks $change before metadata commit',
      () async {
        final f = RuntimeFixture();
        await f.init();
        addTearDown(f.dispose);
        f.a.addOperations(2);
        await f.start();
        expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
        expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
        await rotateRuntimePair(f);
        expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
        final bytes = f.a.runtime
            .publishedFiles()
            .entries
            .singleWhere((e) => e.key.startsWith('ops/'))
            .value;
        final revoked = await MembershipReducer.restoreTrustedLocal(
          f.b.membership.toTrustedLocalJson(),
        );
        final event = await MembershipEvent.create(
          parent: revoked.state,
          issuer: f.b.keys,
          type: MembershipEventType.revoke,
          targetDeviceId: f.a.keys.deviceId,
        );
        await revoked.ingest(event, issuerFileDeviceId: f.b.keys.deviceId);
        final original = Cryptography.instance, crypto = RevokingCryptography();
        Cryptography.instance = crypto;
        addTearDown(() {
          Cryptography.instance = original;
        });
        var fired = false;
        Future<void>? stopping;
        crypto.duringHash = (input) {
          if (!fired && input.toString() == bytes.toString()) {
            fired = true;
            if (change == 'revocation') {
              f.b.membership = revoked;
              f.b.version = Object();
            } else {
              stopping = f.b.runtime.stop();
            }
          }
        };
        expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
        await stopping;
        expect(fired, isTrue);
        expect(
          f.b.db.raw
              .select('SELECT sealed FROM sync_received_segments')
              .single['sealed'],
          0,
        );
        expect(
          f.b.db.raw
              .select('SELECT applied_seq FROM sync_state')
              .single['applied_seq'],
          0,
        );
        expect(
          f.b.db.raw.select('SELECT * FROM sync_operations'),
          hasLength(2),
        );
      },
    );
  }
}
