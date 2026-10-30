import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

import 'lan_sync_runtime_fixture.dart';

class RelayNodeFixture {
  final runtime = RuntimeFixture();
  late Directory directory;
  Process? process;
  late int port;
  Future<void> init() async {
    await runtime.init(vaultId: 'v' * 43);
    directory = await Directory.systemTemp.createTemp('seqpoint-relay-');
    await File('${directory.path}/config.json').writeAsString(
      jsonEncode({
        'vaultId': 'v' * 43,
        'devices': {
          for (final node in [runtime.a, runtime.b])
            node.keys.deviceId: base64UrlEncode(node.keys.signer.publicKey)
                .replaceAll('=', ''),
        },
      }),
    );
    await start();
  }

  Future<void> start() async {
    process = await Process.start(
      Platform.environment['SEQPOINT_NODE_BINARY']!,
      [
        '-config',
        '${directory.path}/config.json',
        '-data',
        '${directory.path}/data',
        '-listen',
        '127.0.0.1:0',
        '-tls-cert',
        'test/sync/transport/fixtures/localhost_cert.pem',
        '-tls-key',
        'test/sync/transport/fixtures/localhost_key.pem',
      ],
    );
    unawaited(process!.stderr.drain<void>());
    final ready = Completer<int>();
    process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.startsWith('listening=') && !ready.isCompleted) {
              ready.complete(int.parse(line.split(':').last));
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(StateError('Node exited'));
            }
          },
        );
    port = await ready.future.timeout(const Duration(seconds: 15));
  }

  RelayTransport client(RuntimeNode node) => RelayTransport(
    endpoint: 'https://127.0.0.1:$port',
    vaultPublicId: 'v' * 43,
    keys: node.keys,
    httpClient: HttpClient()
      ..badCertificateCallback = (certificate, host, port) =>
          host == '127.0.0.1' &&
          port == this.port &&
          certificate.pem.trim() ==
              File('test/sync/transport/fixtures/localhost_cert.pem')
                  .readAsStringSync()
                  .trim(),
  );
  Future<void> stop() async {
    process?.kill(ProcessSignal.sigterm);
    await process?.exitCode;
    process = null;
  }

  Future<void> close() async {
    await stop();
    await runtime.dispose();
    await directory.delete(recursive: true);
  }
}
