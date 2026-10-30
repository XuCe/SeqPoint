import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_platform/seqpoint_platform.dart';

/// Keys never appear in URLs, response errors, or logs.
class SyncthingClient {
  SyncthingClient(this.endpoint);
  final EngineEndpoint endpoint;

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
        return bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes));
      })().timeout(const Duration(seconds: 10));
    } finally {
      client.close(force: true);
    }
  }
}
