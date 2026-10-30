import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';

import 'sync_pairing_code.dart';

final class LanPairingLink {
  LanPairingLink({
    required List<LanPairingAddress> addresses,
    required this.invitation,
  }) : addresses = List.unmodifiable(addresses) {
    if (addresses.isEmpty ||
        addresses.length > 8 ||
        addresses.map((address) => address.toString()).toSet().length !=
            addresses.length) {
      throw const FormatException('局域网地址应为 1–8 个且不能重复');
    }
  }

  static const _prefix = 'seqpoint-lan-v1:';
  static const _invitationPrefix = 'seqpoint-pair-v1:invitation:';
  final List<LanPairingAddress> addresses;
  final PairingInvitation invitation;

  static Future<LanPairingLink> decode(
    String code, {
    Clock clock = const SystemClock(),
  }) async {
    final value = code.trim();
    if (code.length > 2900 || !value.startsWith(_prefix)) {
      throw const FormatException('请扫描 SeqPoint 局域网配对二维码');
    }
    final payload = decodePairingCode(
      value.replaceFirst(_prefix, _invitationPrefix),
      PairingCodeKind.invitation,
    );
    final addresses = payload['addresses'], invitation = payload['invitation'];
    if (payload.length != 3 ||
        payload['v'] != 1 ||
        addresses is! List ||
        addresses.isEmpty ||
        addresses.length > 8 ||
        addresses.any((address) => address is! String) ||
        invitation is! Map<String, Object?>) {
      throw const FormatException('局域网二维码格式错误');
    }
    final parsed = [
      for (final address in addresses)
        LanPairingAddress.parse(address as String),
    ];
    return LanPairingLink(
      addresses: parsed,
      invitation: await PairingInvitation.fromQr(invitation, clock: clock),
    );
  }

  String encode() {
    final code = encodePairingCode(PairingCodeKind.invitation, {
      'v': 1,
      'addresses': addresses.map((address) => address.toString()).toList(),
      'invitation': invitation.toQrPayload(),
    }).replaceFirst(_invitationPrefix, _prefix);
    if (code.length > 2900) throw const FormatException('局域网二维码内容过长');
    return code;
  }
}

final class LanPairingAddress {
  const LanPairingAddress._(this.host, this.port);

  final String host;
  final int port;

  factory LanPairingAddress.parse(String input) {
    final match = RegExp(r'^(?:\[([^\]]+)\]|([^:\s]+)):(\d{1,5})$')
        .firstMatch(input.trim());
    if (match == null) throw const FormatException('请输入 IP:端口');
    final address = InternetAddress.tryParse(match.group(1) ?? match.group(2)!);
    final port = int.parse(match.group(3)!);
    if (address == null ||
        port < 1 ||
        port > 65535 ||
        (match.group(1) != null) !=
            (address.type == InternetAddressType.IPv6) ||
        address.isMulticast ||
        address.rawAddress.every((byte) => byte == 0) ||
        address.address == '255.255.255.255') {
      throw const FormatException('请输入可连接的 IP 地址和 1–65535 端口');
    }
    return LanPairingAddress._(address.address, port);
  }

  @override
  String toString() => '${host.contains(':') ? '[$host]' : host}:$port';
}
