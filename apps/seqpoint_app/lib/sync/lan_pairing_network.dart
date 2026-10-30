import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

import 'lan_pairing_link.dart';

const _path = '/seqpoint/pair/v1';
const _limit = 512 * 1024;
const _timeout = Duration(seconds: 10);

class LanPairingClient {
  LanPairingClient(this.address, {String? expectedFingerprint})
    : fingerprint = expectedFingerprint {
    _client.connectionTimeout = _timeout;
    _client.findProxy = (_) => 'DIRECT';
    _client.badCertificateCallback = (certificate, host, port) {
      final actual = lanSha256(certificate.der);
      if (fingerprint != null && fingerprint != actual) return false;
      fingerprint = actual;
      return true;
    };
  }
  final LanPairingAddress address;
  final _client = HttpClient(context: SecurityContext(withTrustedRoots: false));
  String? fingerprint;

  Future<Map<String, Object?>> post(Map<String, Object?> message) =>
      _post(message).timeout(
        _timeout,
        onTimeout: () {
          close();
          throw TimeoutException('Pairing request timed out');
        },
      );

  Future<Map<String, Object?>> _post(Map<String, Object?> message) async {
    final encoded = utf8.encode(jsonEncode(message));
    if (encoded.length > _limit) throw StateError('Pairing message too large');
    final request = await _client.postUrl(
      Uri(scheme: 'https', host: address.host, port: address.port, path: _path),
    );
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.add(encoded);
    final response = await request.close();
    if (response.certificate == null ||
        lanSha256(response.certificate!.der) != fingerprint) {
      throw const HandshakeException('Pairing certificate changed');
    }
    if (response.statusCode != 200) {
      throw StateError('Pairing request rejected');
    }
    final bytes = await lanReadBounded(response, _limit, _timeout);
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map<String, dynamic>) {
      throw const FormatException('Invalid reply');
    }
    return result;
  }

  void close() => _client.close(force: true);
}

class LanPairingServer {
  LanPairingServer._(this._server, this._onMessage, this._onTimeout);
  final void Function()? _onTimeout;
  final HttpServer _server;
  final Future<Map<String, Object?>> Function(
    Map<String, Object?>,
    InternetAddress,
  )
  _onMessage;
  bool _busy = false;
  int get port => _server.port;

  static Future<LanPairingServer> listen({
    required LanTlsIdentity identity,
    required Future<Map<String, Object?>> Function(
      Map<String, Object?>,
      InternetAddress,
    )
    onMessage,
    InternetAddress? address,
    int port = 0,
    void Function()? onTimeout,
  }) async {
    final socket = await HttpServer.bindSecure(
      address ?? InternetAddress.anyIPv4,
      port,
      identity.createSecurityContext(),
    );
    socket.idleTimeout = _timeout;
    final server = LanPairingServer._(socket, onMessage, onTimeout);
    socket.listen(server._handle, onError: (Object _) {});
    return server;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (_busy || request.method != 'POST' || request.uri.toString() != _path) {
      response.statusCode = _busy ? 429 : 404;
      await response.close();
      return;
    }
    _busy = true;
    Future<Map<String, Object?>>? processing;
    try {
      final bytes = await lanReadBounded(
        request,
        _limit,
        _timeout,
      ).timeout(_timeout);
      final message = jsonDecode(utf8.decode(bytes));
      if (message is! Map<String, dynamic>) {
        throw const FormatException('Expected a pairing object');
      }
      processing = _onMessage(message, request.connectionInfo!.remoteAddress);
      final result = await processing.timeout(
        _timeout,
        onTimeout: () {
          _onTimeout?.call();
          unawaited(_server.close(force: true));
          throw TimeoutException('Pairing handler timed out');
        },
      );
      final encoded = utf8.encode(jsonEncode(result));
      if (encoded.length > _limit) throw StateError('Pairing reply too large');
      response.headers.contentType = ContentType.json;
      response.add(encoded);
    } catch (_) {
      response.statusCode = 400;
    } finally {
      try {
        await response.close();
      } catch (_) {}
      try {
        await processing;
      } catch (_) {}
      _busy = false;
    }
  }

  Future<void> close() async => _server.close(force: true);
}
