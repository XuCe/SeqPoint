import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'device_join_link.dart';
import 'hosted_invite.dart';

/// 扫描已连接设备上的加入二维码（也接受服务器邀请二维码），返回链接文本。
class JoinQrScanPage extends StatefulWidget {
  const JoinQrScanPage({super.key});
  @override
  State<JoinQrScanPage> createState() => _JoinQrScanPageState();
}

bool _isSyncLink(String value) {
  if (DeviceJoinLink.looksLike(value)) return true;
  try {
    return HostedInvite.parse(value).gateway;
  } on FormatException {
    return false;
  }
}

class _JoinQrScanPageState extends State<JoinQrScanPage> {
  bool _finished = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描加入二维码')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                if (_finished) return;
                final code = capture.barcodes
                    .map((item) => item.rawValue?.trim())
                    .whereType<String>()
                    .where(_isSyncLink)
                    .firstOrNull;
                if (code == null) {
                  setState(() => _error = '请扫描已连接设备上「添加设备」显示的二维码');
                  return;
                }
                _finished = true;
                Navigator.pop(context, code);
              },
              errorBuilder: (_, _) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('无法使用相机。请在系统设置中允许相机权限，或返回粘贴加入链接。'),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error ?? '把已连接设备上显示的二维码放入画面'),
          ),
        ],
      ),
    ),
  );
}
