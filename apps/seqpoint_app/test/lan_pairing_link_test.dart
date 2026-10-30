import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import 'package:seqpoint_app/sync/lan_pairing_link.dart';
import 'package:seqpoint_app/sync/sync_pairing_code.dart';

void main() {
  test('LAN QR rejects malformed envelopes and tampered invitations', () async {
    String wrap(Map<String, Object?> payload) => encodePairingCode(
      PairingCodeKind.invitation,
      payload,
    ).replaceFirst('seqpoint-pair-v1:invitation:', 'seqpoint-lan-v1:');
    final keys = await DeviceKeys.fromSeeds(
      List.filled(32, 5),
      List.filled(32, 6),
    );
    final invitation = await PairingInvitation.create(
      keys: keys,
      vaultPublicId: 'vault',
      tlsFingerprint: 'c' * 64,
    );
    final valid = <String, Object?>{
      'v': 1,
      'addresses': ['192.168.1.8:43210'],
      'invitation': invitation.toQrPayload(),
    };
    for (final payload in <Map<String, Object?>>[
      {},
      {...valid, 'v': 2},
      {...valid, 'extra': true},
      {...valid, 'addresses': []},
      {
        ...valid,
        'addresses': [1],
      },
      {
        ...valid,
        'addresses': ['nas.example.com:443'],
      },
      {...valid, 'invitation': 'bad'},
    ]) {
      await expectLater(
        LanPairingLink.decode(wrap(payload)),
        throwsFormatException,
      );
    }
    for (final code in [
      'https://example.com',
      'seqpoint-lan-v1:***',
      'seqpoint-lan-v1:${'a' * 2900}',
    ]) {
      await expectLater(LanPairingLink.decode(code), throwsFormatException);
    }
    await expectLater(
      LanPairingLink.decode(
        wrap({
          ...valid,
          'invitation': {...invitation.toQrPayload(), 'vault_id': 'changed'},
        }),
      ),
      throwsStateError,
    );
  });

  test('LAN QR decode verifies invitation and rejects expiry', () async {
    final clock = FakeClock(DateTime.utc(2030));
    final keys = await DeviceKeys.fromSeeds(
      List.filled(32, 3),
      List.filled(32, 4),
    );
    final invitation = await PairingInvitation.create(
      keys: keys,
      vaultPublicId: 'vault',
      tlsFingerprint: 'b' * 64,
      clock: clock,
    );
    final code = LanPairingLink(
      addresses: [
        LanPairingAddress.parse('192.168.1.8:43210'),
        LanPairingAddress.parse('[fd00::8]:43210'),
      ],
      invitation: invitation,
    ).encode();
    final restored = await LanPairingLink.decode(code, clock: clock);
    expect(restored.addresses.map((a) => a.toString()), [
      '192.168.1.8:43210',
      '[fd00::8]:43210',
    ]);
    expect(restored.invitation.sessionId, invitation.sessionId);
    expect(restored.invitation.initiator.tlsFingerprint, 'b' * 64);
    expect(restored.invitation.pairingSecret, invitation.pairingSecret);
    clock.advance(const Duration(minutes: 11));
    await expectLater(
      LanPairingLink.decode(code, clock: clock),
      throwsStateError,
    );
  });

  test('LAN QR encodes bounded addresses and a signed invitation', () async {
    final keys = await DeviceKeys.fromSeeds(
      List.filled(32, 1),
      List.filled(32, 2),
    );
    final invitation = await PairingInvitation.create(
      keys: keys,
      vaultPublicId: 'vault',
      tlsFingerprint: 'a' * 64,
    );
    final address = LanPairingAddress.parse('192.168.1.8:43210');
    final link = LanPairingLink(addresses: [address], invitation: invitation);
    final code = link.encode();
    expect(code, startsWith('seqpoint-lan-v1:'));
    expect(code.length, lessThanOrEqualTo(2900));
    final payload = decodePairingCode(
      code.replaceFirst('seqpoint-lan-v1:', 'seqpoint-pair-v1:invitation:'),
      PairingCodeKind.invitation,
    );
    expect(payload['addresses'], ['192.168.1.8:43210']);
    expect(payload['invitation'], invitation.toQrPayload());
    for (final addresses in <List<LanPairingAddress>>[
      [],
      [address, address],
      List.generate(
        9,
        (i) => LanPairingAddress.parse('192.168.1.${i + 1}:43210'),
      ),
    ]) {
      expect(
        () => LanPairingLink(
          addresses: addresses,
          invitation: invitation,
        ).encode(),
        throwsFormatException,
      );
    }
    invitation.cancel();
    expect(link.encode, throwsStateError);
  });

  test('LAN address accepts IPv4 and bracketed IPv6 with a port', () {
    final ipv4 = LanPairingAddress.parse(' 192.168.1.8:43210 ');
    expect(ipv4.host, '192.168.1.8');
    expect(ipv4.port, 43210);
    expect(ipv4.toString(), '192.168.1.8:43210');
    final ipv6 = LanPairingAddress.parse('[fd00::8]:443');
    expect(ipv6.host, 'fd00::8');
    expect(ipv6.toString(), '[fd00::8]:443');
    expect(LanPairingAddress.parse('127.0.0.1:1').port, 1);
    expect(LanPairingAddress.parse('192.168.1.8:65535').port, 65535);
  });

  test('LAN address rejects non-address inputs and non-connectable hosts', () {
    for (final input in [
      '',
      '192.168.1.8',
      'nas.example.com:8384',
      '192.168.1.8:0',
      '192.168.1.8:65536',
      '192.168.1.8:-1',
      '192.168.1.8:abc',
      'https://192.168.1.8:443',
      'user@192.168.1.8:443',
      '192.168.1.8:443/path',
      '192.168.1.8:443?key=secret',
      '0.0.0.0:43210',
      '[::]:43210',
      '[0:0:0:0:0:0:0:0]:43210',
      '224.0.0.1:43210',
      '255.255.255.255:43210',
      'fd00::8:443',
    ]) {
      expect(
        () => LanPairingAddress.parse(input),
        throwsFormatException,
        reason: input,
      );
    }
  });
}
