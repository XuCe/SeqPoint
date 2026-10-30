import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/src/identity/member_keys.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:seqpoint_core/src/sync/transport/lan_transport.dart';
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
  Future<LanTransport> fake(
    Future<void> Function(HttpRequest) handler, {
    LanLimits? limits,
  }) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      fixture.context(),
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        /* test peer disconnected */
      }
    });
    return fixture.client(port: server.port, limits: limits);
  }

  Future<void> reply(
    HttpRequest request,
    List<int> body, {
    List<int>? signedBody,
    List<int>? signedRequest,
    void Function()? beforeSend,
  }) async {
    final bytes = await lanReadBounded(
      request,
      4096,
      const Duration(seconds: 1),
    );
    final signature = await fixture.b.signer.sign(
      lanResponseMessage(signedRequest ?? bytes, signedBody ?? body),
    );
    request.response.headers.set(
      'x-seqpoint-signature',
      base64UrlEncode(signature),
    );
    beforeSend?.call();
    request.response.add(body);
    await request.response.close();
  }

  test(
    'wrong pinned certificate is rejected before HTTP authorization is sent',
    () async {
      final wrong = List.filled(64, '0').join();
      final member = fixture.members[fixture.b.deviceId]!;
      fixture.members[fixture.b.deviceId] = MemberKeys(
        deviceId: member.deviceId,
        signingPublicKey: member.signingPublicKey,
        exchangePublicKey: member.exchangePublicKey,
        tlsFingerprint: wrong,
      );
      final transport = fixture.client(pinOverride: wrong);
      expect(
        await transport.get(fixture.path(fixture.b)),
        isA<Err<List<int>>>(),
      );
      expect(fixture.serverB.seenNonces, isEmpty);
    },
  );
  test(
    'redirect responses are rejected without following the target',
    () async {
      final transport = await fake((request) async {
        await request.drain<void>();
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'https://127.0.0.1:${fixture.serverB.port}/seqpoint/v1/read',
        );
        await request.response.close();
      });
      expect(
        await transport.get(fixture.path(fixture.b)),
        isA<Err<List<int>>>(),
      );
      expect(fixture.serverB.seenNonces, isEmpty);
    },
  );

  test(
    'modified bytes and signatures bound to another request are rejected',
    () async {
      final modified = await fake(
        (request) => reply(request, [2], signedBody: [1]),
      );
      expect(
        await modified.get(fixture.path(fixture.b)),
        isA<Err<List<int>>>(),
      );
      final replayed = await fake(
        (request) => reply(request, [1], signedRequest: [9]),
      );
      expect(
        await replayed.get(fixture.path(fixture.b)),
        isA<Err<List<int>>>(),
      );
    },
  );

  test(
    'revoked peer is checked again before delivering received bytes',
    () async {
      final transport = await fake(
        (request) => reply(
          request,
          [1],
          beforeSend: () {
            fixture.members.remove(fixture.b.deviceId);
          },
        ),
      );
      expect(
        await transport.get(fixture.path(fixture.b)),
        isA<Err<List<int>>>(),
      );
    },
  );
  test('chunked file responses are capped while reading', () async {
    final transport = await fake((request) async {
      await request.drain<void>();
      request.response.add(List.filled(33, 1));
      await request.response.close();
    }, limits: LanLimits(maxFileBytes: 32));
    expect(await transport.get(fixture.path(fixture.b)), isA<Err<List<int>>>());
  });

  test('total request timeout aborts a peer that never responds', () async {
    final transport = await fake((request) async {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await request.response.close();
    }, limits: LanLimits(timeout: const Duration(milliseconds: 40)));
    final watch = Stopwatch()..start();
    expect(await transport.get(fixture.path(fixture.b)), isA<Err<List<int>>>());
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('signed listings cannot advertise unowned or duplicate files', () async {
    final transport = await fake(
      (request) => reply(
        request,
        utf8.encode(
          jsonEncode([
            {'name': '../secret', 'size': 1},
          ]),
        ),
      ),
    );
    expect((await transport.list('ops/${fixture.b.deviceId}')).isOk, isFalse);
    final duplicate = await fake(
      (request) => reply(
        request,
        utf8.encode(
          jsonEncode([
            {'name': '202610-0001.log', 'size': 1},
            {'name': '202610-0001.log', 'size': 1},
          ]),
        ),
      ),
    );
    expect((await duplicate.list('ops/${fixture.b.deviceId}')).isOk, isFalse);
  });
}
