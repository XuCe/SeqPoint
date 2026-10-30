import 'dart:io';

import 'package:seqpoint_core/src/identity/device_keys.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:seqpoint_core/src/util/result.dart';
import 'package:test/test.dart';

import 'lan_fixture.dart';

void main() {
  late LanFixture fixture;
  setUp(() async {
    fixture = LanFixture();
    await fixture.init();
  });
  tearDown(() => fixture.dispose());
  test('LAN transport rejects remote mutations', () async {
    final transport = fixture.client();
    expect(
      await transport.put('ops/local/202610-0001.log', [1]),
      isA<Err<void>>(),
    );
    expect(
      await transport.delete('ops/local/202610-0001.log'),
      isA<Err<void>>(),
    );
  });

  test(
    'two pinned HTTPS instances list and pull only their own bytes',
    () async {
      await fixture.write(fixture.a, [1, 2]);
      await fixture.write(fixture.b, [3, 4, 5]);
      final a = fixture.client(), b = fixture.client(reverse: true);
      expect(
        (await a.list('ops/${fixture.b.deviceId}')).valueOrNull?.single.name,
        '202610-0001.log',
      );
      expect((await a.get(fixture.path(fixture.b))).valueOrNull, [3, 4, 5]);
      expect((await b.get(fixture.path(fixture.a))).valueOrNull, [1, 2]);
      expect(a.status.peerCount, 0);
    },
  );
  test('server rejects replayed signed requests', () async {
    await fixture.write(fixture.b, [9]);
    final packet = await fixture.packet();
    expect(await fixture.send(packet.bytes), HttpStatus.ok);
    expect(await fixture.send(packet.bytes), HttpStatus.forbidden);
  });

  test('server rejects unknown, revoked and tampered signers', () async {
    await fixture.write(fixture.b, [9]);
    final stranger = await DeviceKeys.fromSeeds(
      List.filled(32, 7),
      List.filled(32, 8),
    );
    expect(
      await fixture.send((await fixture.packet(keys: stranger)).bytes),
      HttpStatus.forbidden,
    );
    final packet = await fixture.packet();
    packet.signature[0] ^= 1;
    expect(await fixture.send(packet.bytes), HttpStatus.forbidden);
    fixture.members.remove(fixture.a.deviceId);
    expect(
      await fixture.send((await fixture.packet()).bytes),
      HttpStatus.forbidden,
    );
  });

  test(
    'server rejects traversal, unowned paths and request body overflow',
    () async {
      for (final path in [
        '../secret',
        '/etc/passwd',
        fixture.path(fixture.a),
        'ops/${fixture.b.deviceId}/../secret',
        'attachments/hash.bin',
        'manifest.json',
        'ops/${fixture.b.deviceId}/%2e%2e/secret',
      ]) {
        expect(
          await fixture.send((await fixture.packet(path: path)).bytes),
          HttpStatus.forbidden,
          reason: path,
        );
      }
      expect(await fixture.send(List.filled(4097, 32)), HttpStatus.forbidden);
      expect(
        await fixture.send((await fixture.packet()).bytes, path: '/other'),
        HttpStatus.forbidden,
      );
    },
  );
  test(
    'chunked request bodies are capped despite a valid signed packet',
    () async {
      await fixture.write(fixture.b, [9]);
      final packet = await fixture.packet();
      expect(
        await fixture.send([
          ...packet.bytes,
          ...List.filled(4097, 32),
        ], chunked: true),
        HttpStatus.forbidden,
      );
    },
  );

  test(
    'expired and incorrectly scoped requests fail with valid signatures',
    () async {
      await fixture.write(fixture.b, [9]);
      final original = await fixture.packet();
      for (final change in <int, Object>{
        0: 'another-vault',
        2: fixture.a.deviceId,
        3: List.filled(64, '0').join(),
        4: DateTime.now().millisecondsSinceEpoch - 60000,
      }.entries) {
        final fields = List<Object>.of(original.fields)
          ..[change.key] = change.value;
        final signature = await fixture.a.signer.sign(
          LanRequest(fields, []).message,
        );
        expect(
          await fixture.send(LanRequest(fields, signature).bytes),
          HttpStatus.forbidden,
        );
      }
    },
  );
}
