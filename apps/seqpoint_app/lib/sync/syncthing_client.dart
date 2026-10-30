import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_platform/seqpoint_platform.dart';

/// Keys never appear in URLs, response errors, or logs.
class SyncthingClient {
  SyncthingClient(this.endpoint);
  final EngineEndpoint endpoint;

  Future<({String deviceId, List<String> addresses})> shareVault({
    required String localDeviceId,
    required String folderId,
    String? expectedNasId,
  }) async {
    _deviceId(localDeviceId);
    if (!RegExp(r'^seqpoint-[a-f0-9]{64}$').hasMatch(folderId)) {
      throw const FormatException('Invalid SeqPoint folder ID');
    }
    final status = await request('GET', 'system/status') as Map;
    final nasId = status['myID'] as String;
    _deviceId(nasId);
    if (nasId == localDeviceId ||
        (expectedNasId != null && expectedNasId != nasId)) {
      throw StateError('Syncthing NAS identity changed');
    }
    final devices = await request('GET', 'config/devices') as List;
    if (!devices.any((d) => d['deviceID'] == localDeviceId)) {
      final template = await request('GET', 'config/defaults/device') as Map;
      await request('PUT', 'config/devices/$localDeviceId', {
        ...template,
        'deviceID': localDeviceId,
        'name': 'SeqPoint',
        'autoAcceptFolders': false,
        'introducer': false,
      });
    }
    await _shareFolder(folderId, localDeviceId, nasId, status);
    final addresses = <String>{'dynamic'};
    final listeners = status['connectionServiceStatus'] as Map? ?? const {};
    for (final value in listeners.keys) {
      final listen = Uri.tryParse(value as String);
      if (listen?.scheme == 'tcp' &&
          listen!.hasPort &&
          listen.port > 0 &&
          listen.port <= 65535) {
        addresses.add(
          Uri(
            scheme: 'tcp',
            host: Uri.parse(endpoint.baseUrl).host,
            port: listen.port,
          ).toString(),
        );
      }
    }
    return (deviceId: nasId, addresses: addresses.toList());
  }

  static String parseAddress(String input) {
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入 Syncthing 管理域名和端口');
    }
    if (uri.scheme == 'http') {
      final ip = InternetAddress.tryParse(uri.host);
      final bytes = ip?.rawAddress;
      final private =
          ip != null &&
          (ip.isLoopback ||
              (bytes!.length == 4 &&
                  (bytes[0] == 10 ||
                      (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                      (bytes[0] == 192 && bytes[1] == 168))) ||
              (bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc));
      if (!private) throw const FormatException('公网管理接口需要 HTTPS 保护 API Key');
    }
    return uri.replace(path: '').toString();
  }

  static void _deviceId(String id) {
    if (!RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(id)) {
      throw const FormatException('Invalid Syncthing device ID');
    }
  }

  Future<void> _shareFolder(
    String id,
    String localId,
    String nasId,
    Map status,
  ) async {
    final folders = await request('GET', 'config/folders') as List;
    final matches = folders.where((f) => f['id'] == id);
    if (matches.isEmpty) {
      final template = await request('GET', 'config/defaults/folder') as Map;
      final base = (template['path'] as String?)?.trim();
      final home = base == null || base.isEmpty
          ? status['tilde'] as String?
          : base;
      if (home == null || home.isEmpty) {
        throw StateError('NAS storage path unavailable');
      }
      final separator = status['pathSeparator'] == r'\' ? r'\' : '/';
      await request('PUT', 'config/folders/$id', {
        ...template,
        'id': id,
        'label': 'SeqPoint',
        'path': '$home${separator}SeqPoint$separator$id',
        'type': 'sendreceive',
        'paused': false,
        'devices': [
          {'deviceID': nasId},
          {'deviceID': localId},
        ],
      });
      return;
    }
    final folder = matches.single as Map;
    if (folder['type'] != 'sendreceive' || folder['paused'] == true) {
      throw StateError('NAS SeqPoint folder must be active and send-receive');
    }
    final devices = List<Map>.from(folder['devices'] as List);
    if (devices.any((d) => d['deviceID'] == localId)) return;
    devices.add({'deviceID': localId});
    await request('PATCH', 'config/folders/$id', {'devices': devices});
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await (() async {
        final uri = Uri.parse('${endpoint.baseUrl}/rest/$path');
        final request = await client.openUrl(method, uri);
        request.followRedirects = false;
        request.headers.set('X-API-Key', endpoint.apiKey);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('Syncthing API HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 4 * 1024 * 1024) {
            throw StateError('Syncthing API response too large');
          }
          bytes.addAll(chunk);
        }
        try {
          return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
        } on FormatException {
          throw StateError('Invalid Syncthing API response');
        }
      })().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }
}
