import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/syncthing_engine_host.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  final executable = Platform.environment['SEQPOINT_SYNCTHING_BIN'];
  test(
    'damaged certificate is rejected without changing device identity',
    () async {
      final home = await Directory.systemTemp.createTemp('seqpoint-identity-');
      final host = SyncthingEngineHost(
        home: home,
        secrets: _Secrets(),
        executable: executable,
      );
      try {
        await host.start();
        final id = await host.localDeviceId();
        await host.stop();
        final certificate = File('${home.path}/cert.pem');
        final original = await certificate.readAsBytes();
        await certificate.writeAsString('damaged');
        await expectLater(host.start(), throwsStateError);
        expect(await certificate.readAsString(), 'damaged');
        await certificate.writeAsBytes(original);
        final privateKey = File('${home.path}/key.pem');
        final originalKey = await privateKey.readAsBytes();
        final other = SyncthingEngineHost(
          home: Directory('${home.path}/other'),
          secrets: _Secrets(),
          executable: executable,
        );
        try {
          await other.start();
        } finally {
          await other.stop();
        }
        await privateKey.writeAsBytes(
          await File('${home.path}/other/key.pem').readAsBytes(),
        );
        await expectLater(host.start(), throwsStateError);
        await privateKey.writeAsBytes(originalKey);
        expect(await host.localDeviceId(), id);
      } finally {
        await host.stop();
        await home.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set SEQPOINT_SYNCTHING_BIN for real engine'
        : false,
  );
  test(
    'bundled engine keeps identity and stops before returning',
    () async {
      final home = await Directory.systemTemp.createTemp('seqpoint-engine-');
      final secrets = _Secrets();
      final host = SyncthingEngineHost(
        home: home,
        secrets: secrets,
        executable: executable,
      );
      try {
        final endpoint = await host.start();
        expect(Uri.parse(endpoint.baseUrl).host, '127.0.0.1');
        expect(endpoint.apiKey.length, greaterThanOrEqualTo(32));
        final id = await host.localDeviceId();
        expect(id, matches(RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$')));
        expect((await host.start()).baseUrl, endpoint.baseUrl);
        await host.stop();
        final probe = HttpClient()
          ..connectionTimeout = const Duration(seconds: 1);
        await expectLater(
          probe.getUrl(Uri.parse(endpoint.baseUrl)),
          throwsA(isA<SocketException>()),
        );
        probe.close(force: true);
        await host.start();
        expect(await host.localDeviceId(), id);
        expect(secrets.values.length, 1);
      } finally {
        await host.stop();
        await home.delete(recursive: true);
      }
    },
    skip: executable == null
        ? 'Set SEQPOINT_SYNCTHING_BIN for real engine'
        : false,
  );
}
