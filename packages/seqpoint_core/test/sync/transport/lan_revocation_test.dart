import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'package:seqpoint_core/src/identity/member_keys.dart';
import 'package:seqpoint_core/src/util/result.dart';
import 'package:test/test.dart';

import 'lan_fixture.dart';

class RevokingCryptography extends DartCryptography {
  void Function(List<int>)? duringHash;
  @override
  Sha256 sha256() => RevokingSha256((input) => duringHash?.call(input));
}

class RevokingSha256 extends DartSha256 {
  RevokingSha256(this.hook);
  final void Function(List<int>) hook;
  @override
  Future<Hash> hash(List<int> input) async {
    final hash = await super.hash(input);
    hook(input);
    return hash;
  }
}

void main() {
  for (final changeTls in [true, false]) {
    test(
      'async verification rejects changed ${changeTls ? 'TLS' : 'exchange'} material',
      () async {
        final fixture = LanFixture();
        await fixture.init();
        addTearDown(fixture.dispose);
        await fixture.write(fixture.b, [7, 8, 9]);
        final original = Cryptography.instance;
        final crypto = RevokingCryptography();
        Cryptography.instance = crypto;
        addTearDown(() {
          Cryptography.instance = original;
        });
        var fired = false;
        crypto.duringHash = (input) {
          if (!fired &&
              input.toString() == fixture.b.signer.publicKey.toString()) {
            fired = true;
            final old = fixture.members[fixture.b.deviceId]!;
            fixture.members[fixture.b.deviceId] = MemberKeys(
              deviceId: old.deviceId,
              signingPublicKey: old.signingPublicKey,
              exchangePublicKey: changeTls
                  ? old.exchangePublicKey
                  : List.filled(32, 99),
              tlsFingerprint: changeTls
                  ? List.filled(64, '0').join()
                  : old.tlsFingerprint,
            );
          }
        };
        final result = await fixture.client().get(fixture.path(fixture.b));
        expect(fired, isTrue);
        expect(result, isA<Err<List<int>>>());
      },
    );
  }
  for (final revokeLocal in [true, false]) {
    test(
      'async server verification rejects ${revokeLocal ? 'local' : 'peer'} revocation',
      () async {
        final fixture = LanFixture();
        await fixture.init();
        addTearDown(fixture.dispose);
        await fixture.write(fixture.b, [7, 8, 9]);
        final original = Cryptography.instance;
        final crypto = RevokingCryptography();
        Cryptography.instance = crypto;
        addTearDown(() {
          Cryptography.instance = original;
        });
        var fired = false;
        crypto.duringHash = (input) {
          if (!fired &&
              input.toString() == fixture.a.signer.publicKey.toString()) {
            fired = true;
            fixture.members.remove(
              revokeLocal ? fixture.b.deviceId : fixture.a.deviceId,
            );
          }
        };
        final result = await fixture.client().get(fixture.path(fixture.b));
        expect(fired, isTrue);
        expect(result, isA<Err<List<int>>>());
      },
    );
  }
  for (final revokeLocal in [true, false]) {
    test(
      'async response identity verification rejects ${revokeLocal ? 'local' : 'peer'} revocation',
      () async {
        final fixture = LanFixture();
        await fixture.init();
        addTearDown(fixture.dispose);
        await fixture.write(fixture.b, [7, 8, 9]);
        final original = Cryptography.instance;
        final crypto = RevokingCryptography();
        Cryptography.instance = crypto;
        addTearDown(() {
          Cryptography.instance = original;
        });
        var fired = false;
        crypto.duringHash = (input) {
          if (!fired &&
              input.toString() == fixture.b.signer.publicKey.toString()) {
            fired = true;
            fixture.members.remove(
              revokeLocal ? fixture.a.deviceId : fixture.b.deviceId,
            );
          }
        };
        final result = await fixture.client().get(fixture.path(fixture.b));
        expect(fired, isTrue);
        expect(result, isA<Err<List<int>>>());
      },
    );
  }
  for (final revokeLocal in [true, false]) {
    test(
      'final authorization rejects ${revokeLocal ? 'local' : 'peer'} revocation',
      () async {
        final fixture = LanFixture();
        await fixture.init();
        addTearDown(fixture.dispose);
        await fixture.write(fixture.b, [7, 8, 9]);
        var reads = 0;
        MemberKeys? authorize(String vault, String id) {
          final member = fixture.authorize(vault, id);
          if (++reads == 6) {
            if (revokeLocal) {
              fixture.members.remove(fixture.a.deviceId);
            } else {
              scheduleMicrotask(
                () => fixture.members.remove(fixture.b.deviceId),
              );
            }
          }
          return member;
        }

        final result = await fixture
            .client(authorization: authorize)
            .get(fixture.path(fixture.b));
        expect(result, isA<Err<List<int>>>());
        expect(
          fixture.members.containsKey(
            revokeLocal ? fixture.a.deviceId : fixture.b.deviceId,
          ),
          isFalse,
        );
      },
    );
  }
}
