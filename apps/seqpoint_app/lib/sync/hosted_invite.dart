import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

class HostedInvite {
  HostedInvite._(
    this.origin,
    this.token,
    this.issuer,
    this.grant, {
    this.gateway = false,
  });
  final bool gateway;
  final String origin, token, issuer, grant;

  factory HostedInvite.parse(String value) {
    final uri = Uri.tryParse(value.trim());
    if (value.length > 2048 ||
        uri == null ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' && uri.fragment.startsWith('gw.'))) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.path != '/invite') {
      throw const FormatException('请使用运营方发来的完整邀请链接');
    }
    final gateway = uri.fragment.startsWith('gw.');
    final fragment = gateway ? uri.fragment.substring(3) : uri.fragment;
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(fragment)) {
      return HostedInvite._(uri.origin, fragment, '', '', gateway: gateway);
    }
    final parts = fragment.split('.');
    if (parts.length == 2 &&
        RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(parts[0]) &&
        RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(parts[1])) {
      String standard(String raw) =>
          base64Encode(base64Url.decode(base64Url.normalize(raw)));
      return HostedInvite._(
        uri.origin,
        '',
        standard(parts[0]),
        standard(parts[1]),
        gateway: gateway,
      );
    }
    throw const FormatException('邀请链接不完整，请重新复制');
  }

  static HostedInvite revoke(
    String origin,
    String memberId, {
    bool gateway = false,
  }) => HostedInvite._(origin, 'revoke:$memberId', '', '', gateway: gateway);

  static Future<String> delegate(
    String origin,
    String folder,
    Ed25519Signer signer,
    List<int> guest, {
    bool gateway = false,
  }) async {
    final signature = await signer.sign(
      utf8.encode(
        [
          gateway ? 'seqpoint-gateway-grant-v1' : 'seqpoint-grant-v1',
          origin,
          folder,
          base64Encode(guest),
        ].join('\n'),
      ),
    );
    String raw(List<int> bytes) => base64UrlEncode(bytes).replaceAll('=', '');
    return '$origin/invite#${gateway ? 'gw.' : ''}${raw(signer.publicKey)}.${raw(signature)}';
  }
}

extension HostedEnrollment on HostedInvite {
  Future<String> enroll(
    String folder,
    String device,
    Ed25519Signer signer,
  ) async {
    final key = base64Encode(signer.publicKey);
    final proof = await signer.sign(
      utf8.encode(
        [
          gateway ? 'seqpoint-gateway-enroll-v1' : 'seqpoint-enroll-v1',
          origin,
          folder,
          device,
          key,
          token,
          issuer,
          grant,
        ].join('\n'),
      ),
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    Future<String> send() async {
      final request = await client.postUrl(Uri.parse('$origin/v1/enroll'));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      final body = utf8.encode(
        jsonEncode({
          'Folder': folder,
          'Device': device,
          'PublicKey': key,
          'Signature': base64Encode(proof),
          'Invite': token,
          'Issuer': issuer,
          'Grant': grant,
        }),
      );
      request.contentLength = body.length;
      request.add(body);
      final response = await request.close();
      if (response.statusCode == 403) {
        throw const FormatException('邀请已使用、已过期或设备未获授权');
      }
      if (response.statusCode != 200) throw const HttpException('节点暂时不可用，请重试');
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024) {
          throw const FormatException('节点响应过长');
        }
        bytes.addAll(chunk);
      }
      final id = (jsonDecode(utf8.decode(bytes)) as Map)['device'];
      if (gateway && id == device) return device;
      if (gateway ||
          id is! String ||
          !RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(id) ||
          id == device) {
        throw const FormatException('节点设备身份无效');
      }
      return id;
    }

    try {
      return await send().timeout(const Duration(seconds: 25));
    } finally {
      client.close(force: true);
    }
  }
}
