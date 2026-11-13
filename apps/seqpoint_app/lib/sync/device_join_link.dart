import 'dart:convert';

import 'package:seqpoint_core/seqpoint_core.dart';

/// 已连接同步服务器的设备给新设备的一次性加入链接：`{网关地址}/join#{配对秘密}`。
///
/// 秘密只在两台设备之间传递（扫码或复制），网关只看到由它派生的信箱编号，
/// 因此网关既不能冒充新设备，也拿不到资料库密钥。
final class DeviceJoinLink {
  DeviceJoinLink._(this.origin, this.secret);

  final String origin;
  final String secret;

  static final _secret = RegExp(r'^[A-Za-z0-9_-]{43}$');

  factory DeviceJoinLink.parse(String value) {
    final text = value.trim();
    final uri = Uri.tryParse(text);
    if (text.length > 2048 ||
        uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.path != '/join' ||
        !_secret.hasMatch(uri.fragment)) {
      throw const FormatException('请使用已连接设备上显示的完整加入链接');
    }
    return DeviceJoinLink._(uri.origin, uri.fragment);
  }

  /// 由已连接设备创建：[secret] 是配对邀请里的一次性秘密。
  factory DeviceJoinLink.create(String origin, String secret) =>
      DeviceJoinLink.parse('$origin/join#$secret');

  /// 网关上的信箱编号；不可逆推出秘密。
  String get mailbox {
    final hex = lanSha256(utf8.encode('seqpoint-join-v1\n$secret'));
    final bytes = [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  @override
  String toString() => '$origin/join#$secret';

  static bool looksLike(String value) {
    try {
      DeviceJoinLink.parse(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}
