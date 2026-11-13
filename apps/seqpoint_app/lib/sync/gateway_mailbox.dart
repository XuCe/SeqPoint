import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

/// 网关上的临时配对信箱：只转交配对消息，10 分钟后自动消失。
class GatewayMailbox {
  GatewayMailbox(this.origin, this.id);

  final String origin;
  final String id;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  /// 已在资料库中的设备开启信箱，并放入去掉秘密的配对邀请。
  Future<void> open({
    required String vault,
    required String device,
    required Ed25519Signer signer,
    required String invitation,
  }) async {
    final key = base64Encode(signer.publicKey);
    final signature = await signer.sign(utf8.encode([
      'seqpoint-gateway-pair-v1', origin, vault, device, key, id, invitation,
    ].join('\n')));
    final status = await _send('POST', '/v1/pair', jsonEncode({
      'Vault': vault,
      'Device': device,
      'PublicKey': key,
      'Session': id,
      'Invitation': invitation,
      'Signature': base64Encode(signature),
    }));
    if (status == 404) {
      throw const FormatException('同步服务器版本过旧，请先更新序点同步网关');
    }
    if (status == 401 || status == 403) {
      throw const FormatException('本机未在同步服务器登记，或资料库已暂停');
    }
    if (status == 429 || status == 503) {
      throw const HttpException('同时添加的设备过多，请稍后再试');
    }
    if (status != 200) throw const HttpException('同步服务器暂时不可用，请重试');
  }

  /// 读取信箱；信箱不存在或已过期时返回 null。
  Future<Map<String, Object?>?> read() async {
    final request = await _client
        .getUrl(Uri.parse('$origin/v1/pair/$id'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await _body(response);
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw const HttpException('同步服务器暂时不可用，请重试');
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('配对信箱内容错误');
    }
    return decoded;
  }

  Future<void> write(String slot, Map<String, Object?> message) async {
    final status = await _send('PUT', '/v1/pair/$id/$slot', jsonEncode(message));
    if (status == 404) throw const FormatException('加入链接已过期，请重新生成');
    if (status == 409) throw const FormatException('加入链接已被其他设备使用');
    if (status != 200) throw const HttpException('同步服务器暂时不可用，请重试');
  }

  /// 轮询直到对端写入 [slot]，或超过 [deadline]、[cancelled] 为真。
  Future<Map<String, Object?>> waitFor(
    String slot, {
    required DateTime deadline,
    bool Function()? cancelled,
    Duration interval = const Duration(seconds: 1),
  }) async {
    while (true) {
      if (cancelled?.call() ?? false) throw StateError('已取消');
      if (!DateTime.now().toUtc().isBefore(deadline)) {
        throw const FormatException('加入链接已过期，请重新生成');
      }
      Map<String, Object?>? slots;
      try {
        slots = await read();
      } on SocketException {
        slots = const {};
      } on TimeoutException {
        slots = const {};
      } on HttpException {
        slots = const {};
      }
      if (slots == null) throw const FormatException('加入链接已过期或已被使用，请重新生成');
      final value = slots[slot];
      if (value is Map<String, Object?>) return value;
      if (value != null) throw const FormatException('配对消息格式错误');
      await Future<void>.delayed(interval);
    }
  }

  Future<int> _send(String method, String path, String json) async {
    final request = await _client
        .openUrl(method, Uri.parse('$origin$path'))
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    final bytes = utf8.encode(json);
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close().timeout(const Duration(seconds: 15));
    await _body(response);
    return response.statusCode;
  }

  Future<String> _body(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > 512 * 1024) {
        throw const FormatException('配对信箱响应过长');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  void close() => _client.close(force: true);
}
