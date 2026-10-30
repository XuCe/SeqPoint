import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/src/identity/device_keys.dart';
import 'package:seqpoint_core/src/identity/member_keys.dart';
import 'package:seqpoint_core/src/sync/transport/lan_https_server.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:seqpoint_core/src/sync/transport/lan_transport.dart';

class LanFixture {
  late Directory root;
  late DeviceKeys a, b;
  late String pin;
  late LanHttpsServer serverA, serverB;
  final Map<String, MemberKeys> members = {};
  final Map<String, Map<String, List<int>>> publications = {};
  final List<LanTransport> clients = [];
  MemberKeys? authorize(String vault, String id) =>
      vault == 'test-vault' ? members[id] : null;
  SecurityContext context() => SecurityContext()
    ..useCertificateChain('test/sync/transport/fixtures/localhost_cert.pem')
    ..usePrivateKey('test/sync/transport/fixtures/localhost_key.pem');

  Future<void> init({LanLimits? limits}) async {
    root = await Directory.systemTemp.createTemp('seqpoint-lan-test-');
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    final pem = await File('test/sync/transport/fixtures/localhost_cert.pem')
        .readAsLines();
    pin = lanSha256(
      base64Decode(pem.where((line) => !line.startsWith('---')).join()),
    );
    for (final device in [a, b]) {
      publications[device.deviceId] = {};
      members[device.deviceId] = MemberKeys(
        deviceId: device.deviceId,
        signingPublicKey: device.signer.publicKey,
        exchangePublicKey: device.exchangePublicKey,
        tlsFingerprint: pin,
      );
      for (final path in [
        'ops/${device.deviceId}',
        'members',
        'acks',
        'snapshots',
      ]) {
        await Directory('${root.path}/${device.deviceId}/$path')
            .create(recursive: true);
      }
    }
    serverA = await LanHttpsServer.start(
      securityContext: context(),
      keys: a,
      vaultPublicId: 'test-vault',
      tlsFingerprint: pin,
      publishedFiles: () => publications[a.deviceId]!,
      authorize: authorize,
      limits: limits,
    );
    serverB = await LanHttpsServer.start(
      securityContext: context(),
      keys: b,
      vaultPublicId: 'test-vault',
      tlsFingerprint: pin,
      publishedFiles: () => publications[b.deviceId]!,
      authorize: authorize,
      limits: limits,
    );
  }

  Directory directory(DeviceKeys device) =>
      Directory('${root.path}/${device.deviceId}');

  LanTransport client({
    bool reverse = false,
    String? pinOverride,
    LanAuthorization? authorization,
    LanLimits? limits,
    int? port,
  }) {
    final target = reverse ? a : b;
    final transport = LanTransport(
      keys: reverse ? b : a,
      vaultPublicId: 'test-vault',
      authorize: authorization ?? authorize,
      peer: LanPeer(
        deviceId: target.deviceId,
        host: '127.0.0.1',
        port: port ?? (reverse ? serverA.port : serverB.port),
        tlsFingerprint: pinOverride ?? pin,
      ),
      limits: limits,
    );
    clients.add(transport);
    return transport;
  }

  Future<void> dispose() async {
    for (final client in clients) {
      client.close();
    }
    await serverA.close();
    await serverB.close();
    await root.delete(recursive: true);
  }

  String path(DeviceKeys device) => 'ops/${device.deviceId}/202610-0001.log';
  Future<void> write(DeviceKeys device, List<int> bytes) async {
    await File('${directory(device).path}/${path(device)}').writeAsBytes(bytes);
    publications[device.deviceId]![path(device)] = List<int>.of(bytes);
  }

  Future<int> send(
    List<int> bytes, {
    String path = '/seqpoint/v1/read',
    bool chunked = false,
  }) async {
    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    try {
      final request = await client.postUrl(
        Uri.parse('https://127.0.0.1:${serverB.port}$path'),
      );
      if (!chunked) request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<LanRequest> packet({
    String? path,
    String action = 'get',
    DeviceKeys? keys,
  }) => LanRequest.create(
    keys: keys ?? a,
    vault: 'test-vault',
    target: b.deviceId,
    pin: pin,
    action: action,
    path: path ?? this.path(b),
  );
}
