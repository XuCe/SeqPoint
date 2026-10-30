import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/syncthing_engine_host.dart';
import 'package:seqpoint_app/sync/syncthing_client.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

Future<int> _port() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _arrives(File file, String value) async {
  final until = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(until)) {
    if (await file.exists() && await file.readAsString() == value) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Syncthing file did not arrive: ${file.path}');
}

void main() {
  final executable = Platform.environment['SEQPOINT_SYNCTHING_BIN'];
  test(
    'real engines transfer both ways and preserve unrelated folders',
    () async {
      final root = await Directory.systemTemp.createTemp('seqpoint-transfer-');
      final a = SyncthingEngineHost(
        home: Directory('${root.path}/a'),
        secrets: _Secrets(),
        executable: executable,
      );
      final b = SyncthingEngineHost(
        home: Directory('${root.path}/b'),
        secrets: _Secrets(),
        executable: executable,
      );
      try {
        await _transfer(root, a, b);
      } finally {
        await a.stop();
        await b.stop();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: executable == null
        ? 'Set SEQPOINT_SYNCTHING_BIN for real engine'
        : false,
  );
}

Future<void> _transfer(
  Directory root,
  SyncthingEngineHost a,
  SyncthingEngineHost b,
) async {
  final ap = SyncthingClient(await a.start());
  final bp = SyncthingClient(await b.start());
  final aid = (await a.localDeviceId())!;
  final bid = (await b.localDeviceId())!;
  final pa = await _port(), pb = await _port();
  for (final entry in [(ap, pa), (bp, pb)]) {
    final config = await entry.$1.request('GET', 'config') as Map;
    expect(config['folders'], isEmpty);
    await entry.$1.request('PATCH', 'config/options', {
      'listenAddresses': ['tcp://127.0.0.1:${entry.$2}'],
      'globalAnnounceEnabled': false,
      'localAnnounceEnabled': false,
      'relaysEnabled': false,
      'natEnabled': false,
    });
  }
  final fa = await Directory('${root.path}/a-data').create();
  final fb = await Directory('${root.path}/b-data').create();
  await a.configure(
    vaultFolderPath: '${root.path}/unrelated',
    vaultFolderId: 'unrelated',
    peerDeviceIds: [],
  );
  for (var i = 0; i < 2; i++) {
    await a.configure(
      vaultFolderPath: fa.path,
      vaultFolderId: 'seqpoint-test',
      peerDeviceIds: [bid],
    );
    await b.configure(
      vaultFolderPath: fb.path,
      vaultFolderId: 'seqpoint-test',
      peerDeviceIds: [aid],
    );
  }
  await ap.request('PATCH', 'config/devices/$bid', {
    'addresses': ['tcp://127.0.0.1:$pb'],
  });
  await bp.request('PATCH', 'config/devices/$aid', {
    'addresses': ['tcp://127.0.0.1:$pa'],
  });
  final folders = await ap.request('GET', 'config/folders') as List;
  expect(folders.map((f) => f['id']).toSet(), {'unrelated', 'seqpoint-test'});
  await File('${fa.path}/out.bin').writeAsString('from-a');
  await ap.request('POST', 'db/scan?folder=seqpoint-test');
  await _arrives(File('${fb.path}/out.bin'), 'from-a');
  await File('${fb.path}/back.bin').writeAsString('from-b');
  await bp.request('POST', 'db/scan?folder=seqpoint-test');
  await _arrives(File('${fa.path}/back.bin'), 'from-b');
}
