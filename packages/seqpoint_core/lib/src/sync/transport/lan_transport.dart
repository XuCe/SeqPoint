import 'dart:convert';
import 'dart:io';

import '../../identity/device_keys.dart';
import '../../identity/member_keys.dart';
import '../../util/result.dart';
import 'lan_protocol.dart';
import 'vault_transport.dart';

/// Manually paired, pinned HTTPS pull. Mutations stay in the local vault.
class LanTransport implements VaultTransport {
  LanTransport({
    required this.keys,
    required this.vaultPublicId,
    required this.peer,
    required this.authorize,
    LanLimits? limits,
  }) : limits = limits ?? LanLimits() {
    final address = InternetAddress.tryParse(peer.host);
    final raw = address?.rawAddress;
    final privateV4 =
        raw?.length == 4 &&
        (raw![0] == 10 ||
            raw[0] == 192 && raw[1] == 168 ||
            raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31);
    final privateV6 = raw?.length == 16 && (raw![0] & 254) == 252;
    if (address == null ||
        !(address.isLoopback ||
            address.isLinkLocal ||
            privateV4 ||
            privateV6) ||
        peer.port < 1 ||
        peer.port > 65535 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(peer.tlsFingerprint)) {
      throw ArgumentError(
        'LAN peer requires a private literal address and TLS pin',
      );
    }
  }

  final DeviceKeys keys;
  final String vaultPublicId;
  final LanPeer peer;
  final LanAuthorization authorize;
  final LanLimits limits;
  String get selfDeviceId => keys.deviceId;

  @override
  String get id => 'lan';

  @override
  TransportStatus get status =>
      const TransportStatus(kind: TransportStatusKind.localOnly);

  Future<Result<List<LanPeer>>> discover() async =>
      const Err('lan_manual_pairing_required');

  @override
  Future<Result<List<RemoteFile>>> list(String dirPath) async => _list(dirPath);

  List<MemberKeys> _authorized() {
    final local = lanMember(authorize, vaultPublicId, keys.deviceId);
    final member = lanMember(authorize, vaultPublicId, peer.deviceId);
    if (member.tlsFingerprint != peer.tlsFingerprint) {
      throw StateError('LAN peer TLS identity changed');
    }
    return [local, member];
  }

  Future<Result<List<RemoteFile>>> _list(String path) async {
    try {
      final members = _authorized();
      final result = await _read('list', path);
      if (result is Err<List<int>>) {
        return Err(result.code, cause: result.cause);
      }
      final value = jsonDecode(utf8.decode(result.valueOrNull!));
      if (value is! List || value.length > limits.maxFiles) {
        throw const FormatException('Invalid LAN listing');
      }
      final names = <String>{};
      final files = <RemoteFile>[];
      for (final entry in value) {
        if (entry is! Map ||
            entry.length != 2 ||
            entry['name'] is! String ||
            entry['size'] is! int ||
            (entry['size'] as int) < 0 ||
            (entry['size'] as int) > limits.maxFileBytes ||
            !lanOwnedPath('$path/${entry['name']}', peer.deviceId) ||
            !names.add(entry['name'] as String)) {
          throw const FormatException('Unowned or invalid LAN listing entry');
        }
        files.add(
          RemoteFile(name: entry['name'] as String, size: entry['size'] as int),
        );
      }
      lanCheckMembers(authorize, vaultPublicId, members);
      return Ok(files);
    } catch (error) {
      return Err('lan_invalid_listing', cause: error);
    }
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

  Future<Result<List<int>>> _read(String action, String path) =>
      _track(_readRequest(action, path));

  Future<Result<List<int>>> _readRequest(String action, String path) async {
    if (!lanOwnedPath(path, peer.deviceId, directory: action == 'list')) {
      return const Err('lan_unowned_path');
    }
    if (_closed || _active >= 8) return const Err('lan_unavailable');
    _active++;
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..autoUncompress = false
      ..connectionTimeout = limits.timeout
      ..findProxy = (_) {
        return 'DIRECT';
      }
      ..badCertificateCallback = (certificate, host, port) =>
          host == peer.host &&
          port == peer.port &&
          lanSha256(certificate.der) == peer.tlsFingerprint;
    _clients.add(client);
    try {
      final members = _authorized();
      final body = await _track(_exchange(client, action, path, members))
          .timeout(limits.timeout);
      lanCheckMembers(authorize, vaultPublicId, members);
      return Ok(body);
    } catch (error) {
      return Err('lan_transfer_failed', cause: error);
    } finally {
      _active--;
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<List<int>> _exchange(
    HttpClient client,
    String action,
    String path,
    List<MemberKeys> members,
  ) async {
    lanCheckMembers(authorize, vaultPublicId, members);
    final packet = await LanRequest.create(
      keys: keys,
      vault: vaultPublicId,
      target: peer.deviceId,
      pin: peer.tlsFingerprint,
      action: action,
      path: path,
    );
    final bytes = packet.bytes;
    final uri = Uri(
      scheme: 'https',
      host: peer.host,
      port: peer.port,
      path: '/seqpoint/v1/read',
    );
    final request = await client.postUrl(uri);
    lanCheckMembers(authorize, vaultPublicId, members);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.contentType = ContentType.json;
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final cap = action == 'list' ? limits.maxListBytes : limits.maxFileBytes;
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > cap ||
        response.headers.value(HttpHeaders.contentEncodingHeader) != null ||
        response.certificate == null ||
        lanSha256(response.certificate!.der) != peer.tlsFingerprint) {
      throw StateError('Invalid or unpinned LAN response');
    }
    final body = await lanReadBounded(response, cap, limits.timeout);
    lanCheckMembers(authorize, vaultPublicId, members);
    final member = members[1];
    final proof = response.headers.value('x-seqpoint-signature');
    if (proof == null || proof.length != 88) {
      throw StateError('Missing LAN response signature');
    }
    await member.verifySignature(
      lanResponseMessage(bytes, body),
      base64Url.decode(proof),
    );
    lanCheckMembers(authorize, vaultPublicId, members);
    return body;
  }

  int _active = 0;
  bool _closed = false;
  final Set<HttpClient> _clients = {};
  final Set<Future<void>> _pending = {};
  void close() {
    _closed = true;
    for (final client in _clients) {
      client.close(force: true);
    }
  }

  /// Includes raw signing/verification futures that outlived a timeout wrapper.
  Future<void> closeAndDrain() async {
    close();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }

  @override
  Future<Result<List<int>>> get(String filePath) async =>
      _read('get', filePath);

  @override
  Future<Result<void>> put(String filePath, List<int> bytes) async =>
      const Err('lan_read_only');

  @override
  Future<Result<void>> delete(String filePath) async =>
      const Err('lan_read_only');
}

class LanPeer {
  const LanPeer({
    required this.deviceId,
    required this.host,
    required this.port,
    required this.tlsFingerprint,
  });
  final String deviceId;
  final String host;
  final int port;
  final String tlsFingerprint;
}
