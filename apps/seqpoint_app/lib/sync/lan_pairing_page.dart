import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../settings/settings_scaffold.dart';
import 'app_sync_service.dart';
import 'lan_pairing_link.dart';
import 'lan_qr_scan_page.dart';

class LanPairingPage extends StatefulWidget {
  const LanPairingPage({super.key, required this.service});
  final AppSyncService service;
  @override
  State<LanPairingPage> createState() => _LanPairingPageState();
}

class _LanPairingPageState extends State<LanPairingPage> {
  final _address = TextEditingController();
  bool _working = false;
  String? _error;
  LanPairingCoordinator get pairing => widget.service.lanPairing;
  @override
  void dispose() {
    _address.dispose();
    unawaited(pairing.close());
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (!widget.service.prepared) {
        await widget.service.prepare(Platform.localHostname);
      }
      if (mounted) await action();
    } catch (_) {
      if (mounted) setState(() => _error = '连接未完成，请检查地址、网络和设备确认状态');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _connect() {
    try {
      final address = LanPairingAddress.parse(_address.text);
      unawaited(_run(() => pairing.connectAddress(address)));
    } on FormatException {
      setState(() => _error = '请输入有效的 IP:端口');
    }
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const LanQrScanPage()));
    if (code == null || !mounted) return;
    await _run(() async {
      final invitation = await LanPairingLink.decode(code);
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('连接此设备？'),
          content: Text('将与 ${invitation.addresses.first} 双向同步序点数据。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('连接'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) await pairing.connect(invitation);
    });
  }

  List<Widget> _waiting() => [
    if (pairing.link case final link?)
      Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: QrImageView(
              data: link.encode(),
              backgroundColor: Colors.white,
              semanticsLabel: '短时局域网配对二维码',
            ),
          ),
        ),
      ),
    for (final address in pairing.addresses)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: SelectableText(address.toString()),
      ),
    if (pairing.shortCode case final code?)
      ListTile(
        title: SelectableText(code),
        subtitle: const Text('核对两台设备短码一致，再在等待连接的一端允许'),
      ),
    if (pairing.awaitingApproval)
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          children: [
            FilledButton(
              onPressed: _working
                  ? null
                  : () => _run(() => pairing.allow(pairing.shortCode!)),
              child: const Text('短码一致，允许同步'),
            ),
            OutlinedButton(
              onPressed: () => pairing.reject(),
              child: const Text('拒绝'),
            ),
          ],
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: pairing,
    builder: (context, _) => SettingsScaffold(
      title: '连接设备',
      footnote: '两台设备连接同一局域网。手机保持应用在前台；离开本页会关闭配对邀请，已配对设备仍按同步设置交换数据。',
      children: [
        SettingsGroup(
          label: '局域网双向同步',
          children: [
            ListTile(
              title: Text(pairing.status),
              subtitle: const Text('扫码，或输入对方显示的 IP:端口'),
            ),
            if (_working) const LinearProgressIndicator(),
            if (_error case final message?)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(liveRegion: true, child: Text(message)),
              ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _working ? null : () => _run(pairing.listen),
                    icon: const Icon(Icons.qr_code),
                    label: const Text('等待设备连接'),
                  ),
                  if (Platform.isAndroid || Platform.isIOS)
                    OutlinedButton.icon(
                      onPressed: _working ? null : _scan,
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('扫一扫'),
                    ),
                  TextButton(
                    onPressed: () => pairing.close(),
                    child: const Text('取消连接'),
                  ),
                ],
              ),
            ),
            ..._waiting(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('lan-address'),
                    controller: _address,
                    enabled: !_working,
                    decoration: const InputDecoration(
                      labelText: '对方 IP:端口',
                      hintText: '192.168.1.10:12345',
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _working ? null : _connect,
                    child: const Text('连接此地址'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
