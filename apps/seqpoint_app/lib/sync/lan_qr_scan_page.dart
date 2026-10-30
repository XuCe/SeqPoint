import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class LanQrScanPage extends StatefulWidget {
  const LanQrScanPage({super.key});
  @override
  State<LanQrScanPage> createState() => _LanQrScanPageState();
}

class _LanQrScanPageState extends State<LanQrScanPage> {
  bool _finished = false;
  String? _error;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('扫描序点配对二维码')),
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                if (_finished) return;
                final code = capture.barcodes
                    .map((item) => item.rawValue)
                    .whereType<String>()
                    .where((value) => value.startsWith('seqpoint-lan-v1:'))
                    .firstOrNull;
                if (code == null) {
                  setState(() => _error = '请扫描另一台设备的序点配对二维码');
                  return;
                }
                _finished = true;
                Navigator.pop(context, code);
              },
              errorBuilder: (_, _) => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('无法使用相机。请在系统设置中允许相机权限，或返回输入对方 IP:端口。'),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_error ?? '把另一台设备显示的二维码放入画面'),
          ),
        ],
      ),
    ),
  );
}
