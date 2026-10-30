import 'dart:convert';

import 'package:seqpoint_core/src/identity/membership_file.dart';
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

import 'membership_fixture.dart';

void main() {
  test('wire rejects aliases, duplicate keys, foreign scope and excessive recipients', () async {
    final f = await membershipFixture();
    final file = MembershipFile(
      vaultPublicId: 'v1',
      authorityId: f.initial.authorityId,
      issuerDeviceId: f.founder.deviceId,
      events: [f.add],
    );
    final json = jsonDecode(utf8.decode(file.encode())) as Map<String, dynamic>;
    void decode(List<int> bytes) => MembershipFile.decode(
      bytes,
      issuerFileDeviceId: f.founder.deviceId,
      expectedVaultPublicId: 'v1',
      expectedAuthorityId: f.initial.authorityId,
    );
    for (final change in [
      {'v': 1.0},
      {'vault_id': 'other'},
      {'authority_id': base64UrlEncode(List.filled(32, 3)).replaceAll('=', '')},
    ]) {
      expect(
        () => decode(utf8.encode(jsonEncode({...json, ...change}))),
        throwsFormatException,
      );
    }
    final duplicate = utf8
        .decode(file.encode())
        .replaceFirst('"v":1', '"v":1,"v":1');
    expect(() => decode(utf8.encode(duplicate)), throwsFormatException);
    expect(() => decode([255]), throwsFormatException);
    expect(() => decode([256]), throwsFormatException);
    final envelope = (f.add.toJson()['envelopes'] as List).single as Map;
    final envelopes = [
      for (var i = 0; i <= MembershipFile.maxRecipients; i++)
        {
          ...envelope,
          'recipient_id': base64UrlEncode(
            List.generate(
              32,
              (b) => b == 0
                  ? i ~/ 256
                  : b == 1
                  ? i % 256
                  : 0,
            ),
          ).replaceAll('=', ''),
        },
    ];
    final event = MembershipEvent.fromJson({
      ...f.add.toJson(),
      'envelopes': envelopes,
    });
    expect(
      () => MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: [event],
      ),
      throwsFormatException,
    );
    expect(
      () => decode(
        utf8.encode(
          jsonEncode({
            ...json,
            'events': [event.toJson()],
          }),
        ),
      ),
      throwsFormatException,
    );
  });

  test(
    'otherwise well formed histories still obey the total byte cap',
    () async {
      final f = await membershipFixture();
      String id(int value) => base64UrlEncode(
        List.generate(
          32,
          (index) => index == 0
              ? value ~/ 256
              : index == 1
              ? value % 256
              : 0,
        ),
      ).replaceAll('=', '');
      final envelope = (f.add.toJson()['envelopes'] as List).single as Map;
      final event = MembershipEvent.fromJson({
        ...f.add.toJson(),
        'envelopes': [
          for (var index = 0; index < MembershipFile.maxRecipients; index++)
            {...envelope, 'recipient_id': id(index)},
        ],
      });
      final events = [
        for (var index = 0; index < 24; index++)
          MembershipEvent.fromJson({
            ...event.toJson(),
            'issuer_seq': index + 1,
            'event_id': id(index),
          }),
      ];
      final bytes = utf8.encode(
        jsonEncode({
          'purpose': 'seqpoint-membership-file-v1',
          'v': 1,
          'vault_id': 'v1',
          'authority_id': f.initial.authorityId,
          'issuer_id': f.founder.deviceId,
          'events': [for (final entry in events) entry.toJson()],
        }),
      );
      expect(bytes.length, greaterThan(MembershipFile.maxFileBytes));
      expect(
        () => MembershipFile.decode(
          bytes,
          issuerFileDeviceId: f.founder.deviceId,
          expectedVaultPublicId: 'v1',
          expectedAuthorityId: f.initial.authorityId,
        ),
        throwsFormatException,
      );
      expect(
        () => MembershipFile(
          vaultPublicId: 'v1',
          authorityId: f.initial.authorityId,
          issuerDeviceId: f.founder.deviceId,
          events: events,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'unknown parents wait and public subject keys cannot authorize an issuer',
    () async {
      final f = await membershipFixture();
      MembershipFile file(MembershipEvent event) => MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: event.issuerDeviceId,
        events: [event],
      );
      final waiting = MembershipEvent.fromJson({
        ...f.add.toJson(),
        'parent_hash': base64UrlEncode(List.filled(32, 99)).replaceAll('=', ''),
      });
      final reducer = MembershipReducer(trustedAnchor: f.initial);
      expect(await file(waiting).ingestInto(reducer), [
        MembershipApplyResult.waiting,
      ]);
      expect(reducer.state.headHash, f.initial.headHash);
      expect(reducer.isMemberAuthorized(f.guest.deviceId), isFalse);
      final impersonated = MembershipEvent.fromJson({
        ...f.add.toJson(),
        'issuer_id': f.guest.deviceId,
        'event_id': base64UrlEncode(List.filled(32, 98)).replaceAll('=', ''),
      });
      await expectLater(
        file(impersonated).ingestInto(reducer),
        throwsStateError,
      );
      expect(reducer.state.headHash, f.initial.headHash);
      final emptyWrongScope = MembershipFile(
        vaultPublicId: 'different',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: const [],
      );
      await expectLater(emptyWrongScope.ingestInto(reducer), throwsStateError);
    },
  );

  test(
    'immutable issuer history rejects truncation, reordering and body changes',
    () async {
      final f = await membershipFixture();
      final rotate = await MembershipEvent.create(
        parent: f.reducer.state,
        issuer: f.founder,
        type: MembershipEventType.rotate,
      );
      MembershipFile file(List<MembershipEvent> events) => MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: events,
      );
      final previous = file([f.add]);
      final extended = file([f.add, rotate]);
      extended.validateExtensionOf(previous);
      extended.validateExtensionOf(extended);
      expect(() => previous.validateExtensionOf(extended), throwsStateError);
      expect(() => file([rotate, f.add]), throwsFormatException);
      final changed = MembershipEvent.fromJson({
        ...f.add.toJson(),
        'issued_at': f.add.issuedAt + 1,
      });
      expect(
        () => file([changed, rotate]).validateExtensionOf(previous),
        throwsStateError,
      );
      expect(() => file([f.add, f.add]), throwsFormatException);
    },
  );

  test('bounded wire rejects oversized files and event lists', () async {
    final f = await membershipFixture();
    final events = List.generate(
      MembershipFile.maxEvents + 1,
      (index) => MembershipEvent.fromJson({
        ...f.add.toJson(),
        'issuer_seq': index + 1,
        'event_id': base64UrlEncode(
          List.generate(
            32,
            (byte) => byte == 0
                ? index ~/ 256
                : byte == 1
                ? index % 256
                : 0,
          ),
        ).replaceAll('=', ''),
      }),
    );
    expect(
      () => MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: events,
      ),
      throwsFormatException,
    );
    expect(
      () => MembershipFile.decode(
        List.filled(MembershipFile.maxFileBytes + 1, 32),
        issuerFileDeviceId: f.founder.deviceId,
        expectedVaultPublicId: 'v1',
        expectedAuthorityId: f.initial.authorityId,
      ),
      throwsFormatException,
    );
  });

  test(
    'wire rejects noncanonical JSON, unexpected fields and invalid scope',
    () async {
      final f = await membershipFixture();
      final file = MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: [f.add],
      );
      void decode(List<int> bytes) => MembershipFile.decode(
        bytes,
        issuerFileDeviceId: f.founder.deviceId,
        expectedVaultPublicId: 'v1',
        expectedAuthorityId: f.initial.authorityId,
      );
      expect(() => decode([...file.encode(), 32]), throwsFormatException);
      final json =
          jsonDecode(utf8.decode(file.encode())) as Map<String, dynamic>;
      json['extra'] = true;
      expect(
        () => decode(utf8.encode(jsonEncode(json))),
        throwsFormatException,
      );
      for (final id in ['../evil', 'a' * 43, '']) {
        expect(
          () => MembershipFile(
            vaultPublicId: 'v1',
            authorityId: f.initial.authorityId,
            issuerDeviceId: id,
            events: const [],
          ),
          throwsFormatException,
        );
      }
      expect(
        () => MembershipFile(
          vaultPublicId: '../vault',
          authorityId: f.initial.authorityId,
          issuerDeviceId: f.founder.deviceId,
          events: const [],
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'issuer file roundtrip ingests facts only into an existing anchor',
    () async {
      final f = await membershipFixture();
      final file = MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: [f.add],
      );
      final decoded = MembershipFile.decode(
        file.encode(),
        issuerFileDeviceId: f.founder.deviceId,
        expectedVaultPublicId: 'v1',
        expectedAuthorityId: f.initial.authorityId,
      );
      final reducer = MembershipReducer(trustedAnchor: f.initial);
      expect(await decoded.ingestInto(reducer), [
        MembershipApplyResult.applied,
      ]);
      expect(await decoded.ingestInto(reducer), [
        MembershipApplyResult.duplicate,
      ]);
      expect(reducer.state.members.keys, contains(f.guest.deviceId));
      expect(decoded.path, 'members/${f.founder.deviceId}.json');
      expect(() => decoded.events.clear(), throwsUnsupportedError);
    },
  );

  test(
    'file ownership follows the issuer rather than the added subject',
    () async {
      final f = await membershipFixture();
      final bytes = MembershipFile(
        vaultPublicId: 'v1',
        authorityId: f.initial.authorityId,
        issuerDeviceId: f.founder.deviceId,
        events: [f.add],
      ).encode();
      expect(
        () => MembershipFile.decode(
          bytes,
          issuerFileDeviceId: f.guest.deviceId,
          expectedVaultPublicId: 'v1',
          expectedAuthorityId: f.initial.authorityId,
        ),
        throwsFormatException,
      );
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      json['issuer_id'] = f.guest.deviceId;
      expect(
        () => MembershipFile.decode(
          utf8.encode(jsonEncode(json)),
          issuerFileDeviceId: f.guest.deviceId,
          expectedVaultPublicId: 'v1',
          expectedAuthorityId: f.initial.authorityId,
        ),
        throwsFormatException,
      );
    },
  );
}
