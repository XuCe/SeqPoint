import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late RelayTransport relay;
  setUp(() async {
    final context = SecurityContext()
      ..useCertificateChain('test/sync/transport/fixtures/localhost_cert.pem')
      ..usePrivateKey('test/sync/transport/fixtures/localhost_key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(
        'test/sync/transport/fixtures/localhost_cert.pem',
      );
    relay = RelayTransport(
      endpoint: 'https://127.0.0.1:${server.port}',
      vaultPublicId: 'v' * 43,
      keys: await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2)),
      httpClient: HttpClient(context: trust)
        ..badCertificateCallback = (certificate, host, port) =>
            host == '127.0.0.1' &&
            port == server.port &&
            certificate.pem.trim() ==
                File('test/sync/transport/fixtures/localhost_cert.pem')
                    .readAsStringSync()
                    .trim(),
    );
  });
  tearDown(() async {
    relay.close();
    await server.close(force: true);
  });
  test('rejects redirects without following them', () async {
    var count = 0;
    server.listen((request) async {
      count++;
      request.response.statusCode = 302;
      request.response.headers.set('location', '/elsewhere');
      await request.response.close();
    });
    final result = await relay.list('members');
    expect(result, isA<Err<List<RemoteFile>>>());
    expect((result as Err).message, contains('302'));
    expect(count, 1);
  });
  test('rejects traversal entries and non-owned writes', () async {
    server.listen((request) async {
      request.response.write('[{"name":"../private","size":1}]');
      await request.response.close();
    });
    expect((await relay.list('members') as Err).code, 'relay_invalid_list');
    expect(await relay.put('members/${'z' * 43}.json', [1]), isA<Err<void>>());
    expect(await relay.get('../private'), isA<Err<List<int>>>());
    expect(
      await relay.delete('members/${relay.selfDeviceId}.json'),
      isA<Err<void>>(),
    );
  });
}
