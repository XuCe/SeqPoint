import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'lan_protocol.dart';

import '../../identity/device_keys.dart';
import '../../util/result.dart';
import 'vault_transport.dart';

/// HTTPS store-and-forward for encrypted operations and signed membership.
class RelayTransport implements VaultTransport {
  RelayTransport({
    required this.endpoint,
    required this.vaultPublicId,
    required this.keys,
    HttpClient? httpClient,
  }) : _http = httpClient ?? HttpClient() {
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(vaultPublicId)) {
      _http.close(force: true);
      throw ArgumentError('Relay requires an HTTPS origin and a vault ID');
    }
    _http.connectionTimeout = const Duration(seconds: 15);
  }

  /// 自建节点地址。用户可改为自己的另一台服务器。
  final String endpoint;
  final String vaultPublicId;
  final DeviceKeys keys;
  final HttpClient _http;
  String get selfDeviceId => keys.deviceId;
  static const maxFile = 12 * 1024 * 1024;
  static const timeout = Duration(seconds: 30);
  bool _closed = false;
  void close() {
    _closed = true;
    _http.close(force: true);
  }

  static const _device = r'[A-Za-z0-9_-]{43}';
  static final _file = RegExp(
    '^(ops/$_device/[0-9]{6}-[0-9]{4,}\\.log|(?:members|acks|checkpoints)/$_device\\.json|(?:blobs|manifests)/$_device/[a-f0-9]{64}\\.(?:bin|json))\$',
  );
  static final _directory = RegExp('^(members|acks|ops/$_device)\$');

  @override
  String get id => 'relay';

  @override
  TransportStatus get status => _status;
  TransportStatus _status = const TransportStatus(
    kind: TransportStatusKind.localOnly,
  );

  @override
  Future<Result<List<RemoteFile>>> list(String dirPath) async {
    if (!_directory.hasMatch(dirPath)) return const Err('relay_invalid_path');
    final all = <RemoteFile>[];
    String? after;
    do {
      final page = await listPage(dirPath, after: after ?? '');
      if (page is Err<RelayPage>) return Err(page.code, message: page.message);
      final value = (page as Ok<RelayPage>).value;
      all.addAll(value.files);
      after = value.next;
    } while (after != null);
    return Ok(all);
  }

  Future<Result<RelayPage>> listPage(String dirPath, {String after = ''}) async {
    if (!_directory.hasMatch(dirPath)) return const Err('relay_invalid_path');
    final result = await _request('POST', 'scan', dirPath, utf8.encode(jsonEncode({'after':after})));
    if (result is Err<List<int>>) return Err(result.code, message: result.message);
    try {
      final page = jsonDecode(utf8.decode((result as Ok<List<int>>).value)) as Map;
      final rows = page['files'] as List;
      if (rows.length > 256) throw const FormatException('Page too large');
      var previous = after;
      final files = <RemoteFile>[];
      for (final row in rows) {
        final name = row['name'] as String, size = row['size'] as int;
        if (name.contains('/') || !_file.hasMatch('$dirPath/$name') ||
            name.compareTo(previous) <= 0 || size < 0 || size > maxFile) {
          throw const FormatException('Invalid relay page');
        }
        files.add(RemoteFile(name:name,size:size)); previous=name;
      }
      final next = page['next'] as String?;
      if (next != null && (files.isEmpty || next != previous)) {
        throw const FormatException('Invalid page cursor');
      }
      return Ok(RelayPage(files,next));
    } catch (error) { return Err('relay_invalid_list',cause:error); }
  }

  @override
  Future<Result<List<int>>> get(String filePath) => _file.hasMatch(filePath)
      ? _request('GET', 'file', filePath, const [])
      : Future.value(const Err('relay_invalid_path'));

  @override
  Future<Result<void>> put(String filePath, List<int> bytes) async {
    if (!_file.hasMatch(filePath) ||
        !(filePath.startsWith('ops/$selfDeviceId/') ||
            filePath.startsWith('blobs/$selfDeviceId/') ||
            filePath.startsWith('manifests/$selfDeviceId/') ||
            filePath == 'members/$selfDeviceId.json' ||
            filePath == 'acks/$selfDeviceId.json')) {
      return const Err('relay_not_owned');
    }
    final result = await _request('PUT', 'file', filePath, bytes);
    return result is Err<List<int>>
        ? Err(result.code, message: result.message)
        : const Ok(null);
  }

  @override
  Future<Result<void>> delete(String filePath) async =>
      const Err('relay_history_retained');

  Future<Result<Map<String,String>>> inventory(List<String> paths) async {
    if (paths.length > 256 || paths.any((p)=>!_file.hasMatch(p))) {
      return const Err('relay_invalid_path');
    }
    final response = await _request('POST','inventory','',utf8.encode(jsonEncode(paths)));
    if (response is Err<List<int>>) return Err(response.code,message:response.message);
    try {
      final hashes=Map<String,String>.from(jsonDecode(utf8.decode((response as Ok<List<int>>).value)) as Map);
      if (hashes.length!=paths.toSet().length || paths.any((p)=>!hashes.containsKey(p)) ||
          hashes.values.any((h)=>h.isNotEmpty && !RegExp(r'^[a-f0-9]{64}$').hasMatch(h))) {
        throw const FormatException('Invalid inventory');
      }
      return Ok(hashes);
    } catch(error) { return Err('relay_invalid_inventory',cause:error); }
  }

  Future<Result<bool>> putChanged(String path,List<int> bytes) async {
    final found=await inventory([path]);
    if(found is Err<Map<String,String>>) return Err(found.code,message:found.message);
    if((found as Ok<Map<String,String>>).value[path]==lanSha256(bytes)) return const Ok(false);
    final result=await put(path,bytes);
    return result is Err<void> ? Err(result.code,message:result.message) : const Ok(true);
  }

  Future<Result<int>> commitCheckpoint({required String author,required String previous,
      required List<int> manifest,required String segment}) async {
    if(!RegExp('^$_device\$').hasMatch(author)) return const Err('relay_invalid_author');
    final response=await _request('POST','checkpoint',author,utf8.encode(jsonEncode({
      'previous':previous,'manifest':base64UrlEncode(manifest),'segment':segment})));
    if(response is Err<List<int>>) return Err(response.code,message:response.message);
    try {
      final result=jsonDecode(utf8.decode((response as Ok<List<int>>).value)) as Map;
      if(result['hash']!=lanSha256(manifest) || result['reclaimed'] is! int || (result['reclaimed'] as int)<0) {
        throw const FormatException('Invalid checkpoint commit response');
      }
      return Ok(result['reclaimed'] as int);
    } catch(error) {return Err('relay_invalid_checkpoint_commit',cause:error);}
  }

  Future<Result<List<int>>> _request(
    String method,
    String action,
    String path,
    List<int> body,
  ) async {
    try {
      final bytes = await _send(method, action, path, body).timeout(timeout);
      if (method == 'PUT') {
        _status = const TransportStatus(kind: TransportStatusKind.pendingRelay);
      }
      return Ok(bytes);
    } catch (error) {
      close();
      _status = TransportStatus(
        kind: TransportStatusKind.error,
        message: '$error',
      );
      return Err('relay_request_failed', message: '$error', cause: error);
    }
  }

  Future<List<int>> _send(
    String method,
    String action,
    String path,
    List<int> body,
  ) async {
    if (_closed || body.length > maxFile) {
      throw StateError('Relay closed or file too large');
    }
    final stamp = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    final random = Random.secure();
    final nonce = base64UrlEncode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    final canonical = [
      'seqpoint-relay-v2',
      method,
      vaultPublicId,
      selfDeviceId,
      action,
      path,
      lanSha256(body),
      stamp,
      nonce,
    ].join('\n');
    final signature = base64UrlEncode(
      await keys.signer.sign(utf8.encode(canonical)),
    ).replaceAll('=', '');
    if (_closed) throw StateError('Relay closed');
    final uri = Uri.parse(endpoint).replace(
      path: '/seqpoint/relay/v2/$action',
      queryParameters: {'vault': vaultPublicId, 'path': path},
    );
    final request = await _http.openUrl(method, uri);
    request.followRedirects = false;
    request.headers.set('X-Seqpoint-Device', selfDeviceId);
    request.headers.set('X-Seqpoint-Time', stamp);
    request.headers.set('X-Seqpoint-Nonce', nonce);
    request.headers.set('X-Seqpoint-Signature', signature);
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    if (response.statusCode != (method == 'PUT' ? 204 : 200)) {
      throw HttpException('Relay HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxFile) {
        throw StateError('Relay response too large');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  /// 云端当前暂存量，设置页展示用。
  Future<Result<int>> usedBytes() async {
    final result = await _request('GET', 'usage', '', const []);
    if (result is Err<List<int>>) {
      return Err(result.code, message: result.message);
    }
    try {
      final used =
          (jsonDecode(utf8.decode((result as Ok<List<int>>).value))
                  as Map)['used_bytes']
              as int;
      if (used < 0) throw const FormatException('Invalid usage');
      return Ok(used);
    } catch (error) {
      return Err('relay_invalid_usage', cause: error);
    }
  }
}

class RelayPage {
  const RelayPage(this.files,this.next);
  final List<RemoteFile> files;
  final String? next;
}
