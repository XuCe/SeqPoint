import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/lan_pairing_link.dart';
import 'package:seqpoint_app/sync/lan_pairing_network.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  late LanTlsIdentity identity;
  setUpAll(() async => identity = await LanTlsIdentity.generate());
  test(
    'a timed out handler closes the endpoint before accepting another request',
    () async {
      final gate = Completer<void>(), expired = Completer<void>();
      var calls = 0;
      final server = await LanPairingServer.listen(
        identity: identity,
        address: InternetAddress.loopbackIPv4,
        onTimeout: expired.complete,
        onMessage: (_, _) async {
          calls++;
          await gate.future;
          return {};
        },
      );
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await server.close();
      });
      final address = LanPairingAddress.parse('127.0.0.1:${server.port}');
      final client = LanPairingClient(
        address,
        expectedFingerprint: identity.fingerprint,
      );
      addTearDown(client.close);
      await expectLater(client.post({}), throwsA(anything));
      await expired.future.timeout(const Duration(seconds: 2));
      final another = LanPairingClient(
        address,
        expectedFingerprint: identity.fingerprint,
      );
      addTearDown(another.close);
      await expectLater(another.post({}), throwsA(anything));
      expect(calls, 1);
      gate.complete();
    },
  );

  test(
    'oversized messages and closed clients cannot reach the handler',
    () async {
      var calls = 0;
      final server = await LanPairingServer.listen(
        identity: identity,
        address: InternetAddress.loopbackIPv4,
        onMessage: (_, _) async {
          calls++;
          return {};
        },
      );
      addTearDown(server.close);
      final client = LanPairingClient(
        LanPairingAddress.parse('127.0.0.1:${server.port}'),
        expectedFingerprint: identity.fingerprint,
      );
      await expectLater(
        client.post({'large': 'x' * (512 * 1024)}),
        throwsStateError,
      );
      client.close();
      await expectLater(client.post({}), throwsStateError);
      expect(calls, 0);
    },
  );

  test('pairing messages use an isolated pinned TLS connection', () async {
    final server = await LanPairingServer.listen(
      identity: identity,
      address: InternetAddress.loopbackIPv4,
      onMessage: (message, peer) async {
        expect(peer.isLoopback, isTrue);
        return {'reply': message['hello']};
      },
    );
    addTearDown(server.close);
    final address = LanPairingAddress.parse('127.0.0.1:${server.port}');
    final client = LanPairingClient(
      address,
      expectedFingerprint: identity.fingerprint,
    );
    addTearDown(client.close);
    expect(await client.post({'hello': 'device'}), {'reply': 'device'});
    expect(client.fingerprint, identity.fingerprint);
  });

  test('wrong QR certificate pin cannot send pairing messages', () async {
    var calls = 0;
    final server = await LanPairingServer.listen(
      identity: identity,
      address: InternetAddress.loopbackIPv4,
      onMessage: (message, peer) async {
        calls++;
        return {};
      },
    );
    addTearDown(server.close);
    final client = LanPairingClient(
      LanPairingAddress.parse('127.0.0.1:${server.port}'),
      expectedFingerprint: '0' * 64,
    );
    addTearDown(client.close);
    await expectLater(
      client.post({'hello': 'device'}),
      throwsA(isA<HandshakeException>()),
    );
    expect(calls, 0);
  });
}
