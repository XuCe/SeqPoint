import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/seq_tokens.dart';
import 'app_sync_service.dart';

/// 已连接设备上的"添加设备"：显示一次性加入二维码和链接，等新设备打开。
class AddDevicePage extends StatefulWidget {
  const AddDevicePage({super.key, required this.service});
  final AppSyncService service;
  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  late AddDeviceSession _session;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _begin();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _session.stage == AddDeviceStage.waiting) setState(() {});
    });
  }

  void _begin() {
    _session = widget.service.startAddDevice()..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _restart() {
    _session
      ..removeListener(_changed)
      ..cancel()
      ..dispose();
    setState(_begin);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _session
      ..removeListener(_changed)
      ..cancel()
      ..dispose();
    super.dispose();
  }

  String _remaining() {
    final left = _session.expiresAt?.difference(DateTime.now().toUtc()) ?? Duration.zero;
    if (left.isNegative) return '已失效';
    final minutes = left.inMinutes, seconds = left.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')} 后失效';
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('添加设备')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: switch (session.stage) {
                AddDeviceStage.preparing => const _Progress('正在生成加入链接…'),
                AddDeviceStage.waiting => _waiting(session),
                AddDeviceStage.connecting => const _Progress('新设备已打开链接，正在加密交换资料库密钥…'),
                AddDeviceStage.done => _done(session),
                AddDeviceStage.failed => _failed(session),
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _waiting(AddDeviceSession session) {
    final link = session.link.toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('在新设备上打开序点 →「设置 → 设备与同步」，点「扫一扫」扫描下面的二维码；'
          '电脑没有摄像头时，把链接复制过去粘贴即可。',
          style: TextStyle(fontSize: 14, height: 1.6)),
      const SizedBox(height: 20),
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SeqTokens.line)),
          child: QrImageView(key: const ValueKey('join-qr'), data: link, size: 220,
              backgroundColor: Colors.white),
        ),
      ),
      const SizedBox(height: 16),
      SelectableText(link, key: const ValueKey('join-link'), textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted)),
      const SizedBox(height: 12),
      Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('复制链接'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: link));
            if (!mounted) return;
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(const SnackBar(content: Text('加入链接已复制')));
          },
        ),
      ),
      const SizedBox(height: 16),
      Text('${_remaining()} · 只能使用一次 · 请只发给自己的设备',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted)),
      const SizedBox(height: 8),
      const Text('保持此页面打开，直到新设备显示已连接。',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted)),
    ]);
  }

  Widget _done(AddDeviceSession session) => Column(children: [
        const Icon(Icons.check_circle_rounded, size: 56, color: SeqTokens.syncDot),
        const SizedBox(height: 12),
        Text('已添加设备 ${session.joinedDevice?.substring(0, 8) ?? ''}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(session.error ?? '新设备会通过同步服务器自动收到全部内容。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, height: 1.6, color: SeqTokens.inkMuted)),
        const SizedBox(height: 20),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('完成')),
      ]);

  Widget _failed(AddDeviceSession session) => Column(children: [
        const Icon(Icons.error_outline_rounded, size: 48, color: SeqTokens.dangerInk),
        const SizedBox(height: 12),
        Text(session.error ?? '添加设备未完成', textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14.5, height: 1.6)),
        const SizedBox(height: 20),
        FilledButton(onPressed: _restart, child: const Text('重新生成')),
      ]);
}

class _Progress extends StatelessWidget {
  const _Progress(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(text, textAlign: TextAlign.center),
        ]),
      );
}
