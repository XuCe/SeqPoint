import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

import '../sync/syncthing_client.dart';

class SyncthingEngineHost implements SyncEngineHost {
  SyncthingEngineHost({
    required this.home,
    required this.secrets,
    this.executable,
  });
  final Directory home;
  final SecretStore secrets;
  final String? executable;
  static const _channel = MethodChannel('seqpoint/syncthing');
  Future<void> _tail = Future.value();
  EngineEndpoint? _endpoint;
  Process? _process;
  bool get _mobile => Platform.isAndroid || Platform.isIOS;
  String get _binary =>
      executable ??
      '${File(Platform.resolvedExecutable).parent.path}/${Platform.isWindows ? 'syncthing.exe' : 'syncthing'}';

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  bool get isSupported =>
      _mobile || Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  @override
  Future<bool> isInstalled() async =>
      isSupported && (_mobile || await File(_binary).exists());
  @override
  Future<void> install({void Function(double)? onProgress}) async {
    if (!await isInstalled()) {
      throw StateError('Syncthing engine is not bundled');
    }
    onProgress?.call(1);
  }

  @override
  Future<void> uninstall() async =>
      throw UnsupportedError('Bundled engine cannot be uninstalled');
  @override
  Future<EngineEndpoint> start() => _run(_start);

  @override
  Future<String?> localDeviceId() => _run(() async {
    final api = SyncthingClient(await _start());
    final status = await api.request('GET', 'system/status') as Map;
    return status['myID'] as String;
  });

  @override
  Future<void> configure({
    required String vaultFolderPath,
    required String vaultFolderId,
    required List<String> peerDeviceIds,
    bool paused = false,
    String? discoveryUrl,
    String? relayUrl,
  }) => _run(() async {
    if (discoveryUrl != null || relayUrl != null) {
      throw UnsupportedError('Custom discovery and relay are not supported');
    }
    final api = SyncthingClient(await _start());
    final config = await api.request('GET', 'config') as Map;
    for (final id in peerDeviceIds) {
      if (!RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(id)) {
        throw FormatException('Invalid Syncthing device ID');
      }
      if ((config['devices'] as List).any((d) => d['deviceID'] == id)) {
        await api.request('PATCH', 'config/devices/$id', {'paused': paused});
        continue;
      }
      final device = await api.request('GET', 'config/defaults/device') as Map;
      await api.request('PUT', 'config/devices/$id', {
        ...device,
        'deviceID': id,
        'paused': paused,
      });
    }
    final folders = (config['folders'] as List).where(
      (f) => f['id'] == vaultFolderId,
    );
    final folder = folders.isEmpty
        ? await api.request('GET', 'config/defaults/folder') as Map
        : folders.single as Map;
    if (folders.isNotEmpty && folder['path'] != vaultFolderPath) {
      throw StateError('Syncthing folder belongs to another path');
    }
    final self =
        (await api.request('GET', 'system/status') as Map)['myID'] as String;
    final devices = [
      for (final id in {self, ...peerDeviceIds}) {'deviceID': id},
    ];
    await api.request(
      'PUT',
      'config/folders/${Uri.encodeComponent(vaultFolderId)}',
      {
        ...folder,
        'id': vaultFolderId,
        'path': vaultFolderPath,
        'label': 'SeqPoint',
        'type': 'sendreceive',
        'paused': paused,
        'devices': devices,
      },
    );
  });

  Future<void> _launchDesktop(EngineEndpoint endpoint) async {
    final cert = await File('${home.path}/cert.pem').exists();
    final key = await File('${home.path}/key.pem').exists();
    final configured =
        await File('${home.path}/config.xml').exists() ||
        await Directory('${home.path}/index-v2').exists();
    if (cert != key || (configured && !cert)) {
      throw StateError('Syncthing identity is incomplete');
    }
    if (cert) {
      try {
        final certificate = File('${home.path}/cert.pem');
        final privateKey = File('${home.path}/key.pem');
        if (await certificate.length() > 65536 ||
            await privateKey.length() > 65536) {
          throw StateError('Identity exceeds limit');
        }
        SecurityContext()
          ..useCertificateChainBytes(await certificate.readAsBytes())
          ..usePrivateKeyBytes(await privateKey.readAsBytes());
      } catch (_) {
        throw StateError('Syncthing identity is damaged');
      }
    }
    final environment = Map<String, String>.of(Platform.environment)
      ..removeWhere((key, _) => key.startsWith('ST'));
    environment.addAll({'STMONITORED': 'yes', 'STGUIAPIKEY': endpoint.apiKey});
    final process = await Process.start(
      _binary,
      [
        'serve',
        '--home=${home.absolute.path}',
        '--no-browser',
        '--no-restart',
        '--paused',
        '--no-upgrade',
        '--gui-address=${endpoint.baseUrl}',
        '--log-level=WARN',
        '--log-file=-',
      ],
      environment: environment,
      includeParentEnvironment: false,
    );
    _process = process;
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (identical(_process, process)) {
          _process = null;
          _endpoint = null;
        }
      }),
    );
  }

  @override
  Future<void> stop() => _run(_stop);

  Future<void> _stop() async {
    final endpoint = _endpoint;
    final process = _process;
    if (_mobile) {
      if (endpoint != null) await _channel.invokeMethod<void>('stop');
    } else if (process != null) {
      try {
        if (endpoint != null) {
          await SyncthingClient(endpoint).request('POST', 'system/shutdown');
        }
        await process.exitCode.timeout(const Duration(seconds: 10));
      } catch (_) {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
    }
    _process = null;
    _endpoint = null;
  }

  Future<EngineEndpoint> _start() async {
    if (_endpoint != null) return _endpoint!;
    await install();
    await home.create(recursive: true);
    const keyName = 'seqpoint.syncthing.local-api-key';
    var key = await secrets.read(keyName);
    if (key == null) {
      final random = Random.secure();
      key = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)));
      await secrets.write(keyName, key);
      if (await secrets.read(keyName) != key) throw StateError('Key not saved');
    }
    if (key.length < 32) throw StateError('Invalid Syncthing API key');
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final address = '127.0.0.1:${socket.port}';
    await socket.close();
    final endpoint = EngineEndpoint(baseUrl: 'http://$address', apiKey: key);
    try {
      if (_mobile) {
        await _channel.invokeMethod<void>('start', {
          'home': home.absolute.path,
          'address': address,
          'apiKey': key,
        });
      } else {
        await _launchDesktop(endpoint);
      }
      _endpoint = endpoint;
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (true) {
        try {
          await SyncthingClient(endpoint).request('GET', 'system/status');
          return endpoint;
        } on SocketException {
          if (DateTime.now().isAfter(deadline) ||
              (!_mobile && _process == null)) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {
      await _stop();
      rethrow;
    }
  }
}
