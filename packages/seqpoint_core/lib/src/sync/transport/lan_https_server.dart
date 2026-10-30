import 'dart:convert';
import 'dart:io';

import '../../identity/device_keys.dart';
import '../../identity/member_keys.dart';
import 'lan_file_source.dart';
import 'lan_protocol.dart';

/// A read-only endpoint. The caller supplies a securely stored TLS identity.
class LanHttpsServer {
  LanHttpsServer._(
    this.server,
    this.keys,
    this.vaultPublicId,
    this.tlsFingerprint,
    this.authorize,
    this.source,
    this.limits,
  );
  final HttpServer server;
  final DeviceKeys keys;
  final String vaultPublicId, tlsFingerprint;
  final LanAuthorization authorize;
  final LanFileSource source;
  final LanLimits limits;
  final Map<String, int> seenNonces = {};
  int get port => server.port;

  Future<List<MemberKeys>> authenticate(
    LanRequest packet, {
    bool replayCheck = true,
  }) async {
    if (_closing) throw StateError('LAN server is closing');
    final now = DateTime.now().millisecondsSinceEpoch;
    if (packet.fields[0] != vaultPublicId ||
        packet.fields[2] != keys.deviceId ||
        packet.fields[3] != tlsFingerprint ||
        (packet.millis - now).abs() > 30000 ||
        !{'get', 'list'}.contains(packet.action) ||
        !lanOwnedPath(
          packet.path,
          keys.deviceId,
          directory: packet.action == 'list',
        )) {
      throw StateError('Invalid LAN request scope');
    }
    final local = lanMember(authorize, vaultPublicId, keys.deviceId);
    if (local.tlsFingerprint != tlsFingerprint) {
      throw StateError('Local TLS identity changed');
    }
    final peer = lanMember(authorize, vaultPublicId, packet.sender);
    await peer.verifySignature(packet.message, packet.signature);
    final members = [local, peer];
    lanCheckMembers(authorize, vaultPublicId, members);
    if (replayCheck) {
      seenNonces.removeWhere((_, expiry) => expiry < now);
      final replayKey = '${packet.sender}:${packet.nonce}';
      if (seenNonces.containsKey(replayKey) || seenNonces.length >= 1024) {
        throw StateError('Replayed LAN request or replay cache full');
      }
      seenNonces[replayKey] = packet.millis + 30000;
    }
    return members;
  }

  Future<(List<int>, String, List<MemberKeys>)> buildResponse(
    HttpRequest request,
  ) async {
    if (request.method != 'POST' ||
        request.uri.toString() != '/seqpoint/v1/read' ||
        request.contentLength > LanLimits.maxRequestBytes) {
      throw StateError('Invalid LAN HTTP request');
    }
    final bytes = await lanReadBounded(
      request,
      LanLimits.maxRequestBytes,
      limits.timeout,
    );
    final packet = LanRequest.decode(bytes);
    final members = await authenticate(packet);
    lanCheckMembers(authorize, vaultPublicId, members);
    final body = packet.action == 'list'
        ? await source.list(packet.path)
        : await source.read(packet.path);
    final signature = await keys.signer.sign(lanResponseMessage(bytes, body));
    lanCheckMembers(authorize, vaultPublicId, members);
    return (body, base64UrlEncode(signature), members);
  }

  static Future<LanHttpsServer> start({
    required SecurityContext securityContext,
    required DeviceKeys keys,
    required String vaultPublicId,
    required String tlsFingerprint,
    required LanPublishedFiles publishedFiles,
    required LanAuthorization authorize,
    InternetAddress? address,
    int port = 0,
    LanLimits? limits,
  }) async {
    final local = lanMember(authorize, vaultPublicId, keys.deviceId);
    if (local.tlsFingerprint != tlsFingerprint ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(vaultPublicId)) {
      throw ArgumentError('Invalid currently authorized LAN identity');
    }
    final bound = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      securityContext,
    );
    final result = LanHttpsServer._(
      bound,
      keys,
      vaultPublicId,
      tlsFingerprint,
      authorize,
      LanFileSource(keys.deviceId, publishedFiles, limits ?? LanLimits()),
      limits ?? LanLimits(),
    );
    bound.idleTimeout = result.limits.timeout;
    bound.listen(result.handle);
    return result;
  }

  Future<T> _track<T>(Future<T> pending) {
    late Future<void> completion;
    completion = pending.then<void>(
      (_) {
        _pending.remove(completion);
      },
      onError: (Object _, StackTrace _) {
        _pending.remove(completion);
      },
    );
    _pending.add(completion);
    return pending;
  }

  Future<void> handle(HttpRequest request) => _track(_handle(request));

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.persistentConnection = false;
    response.deadline = limits.timeout;
    if (_closing || _active + _sending >= 8) {
      response.statusCode = HttpStatus.serviceUnavailable;
      try {
        await response.close();
      } catch (_) {
        /* peer closed */
      }
      return;
    }
    _active++;
    var sending = false;
    try {
      final pending = _track(
        buildResponse(request).whenComplete(() => _active--),
      );
      final (body, signature, members) = await pending.timeout(limits.timeout);
      if (_closing) throw StateError('LAN server is closing');
      lanCheckMembers(authorize, vaultPublicId, members);
      sending = true;
      _sending++;
      response.headers.set('x-seqpoint-signature', signature);
      response.headers.contentType = ContentType.binary;
      response.contentLength = body.length;
      response.add(body);
    } catch (_) {
      try {
        response.statusCode = HttpStatus.forbidden;
      } catch (_) {
        /* deadline closed */
      }
    }
    try {
      await response.close().timeout(limits.timeout);
    } catch (_) {
      // A closed or timed-out peer has no response to receive.
    } finally {
      if (sending) _sending--;
    }
  }

  int _active = 0;
  int _sending = 0;
  bool _closing = false;
  final Set<Future<void>> _pending = {};
  Future<void>? _closed;

  Future<void> close() {
    _closing = true;
    return _closed ??= _drain();
  }

  Future<void> _drain() async {
    await server.close(force: true);
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}
