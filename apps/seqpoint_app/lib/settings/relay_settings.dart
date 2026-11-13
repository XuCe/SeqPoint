import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync/app_sync_service.dart';
import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';

class RelaySettings extends StatefulWidget {
  const RelaySettings({
    super.key,
    required this.service,
    required this.disabled,
  });
  final AppSyncService service;
  final bool disabled;
  @override
  State<RelaySettings> createState() => _RelaySettingsState();
}

class _RelaySettingsState extends State<RelaySettings> {
  final _address = TextEditingController();
  bool _loading = true, _working = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await widget.service.loadRelayEndpoint();
      if (mounted) _address.text = saved;
    } catch (_) {
      _message = '读取节点地址失败，请重新填写后保存';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working || _loading || widget.disabled || widget.service.busy) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _message = '操作未完成：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled =
        widget.disabled || !widget.service.canSync || _loading || _working;
    final service = widget.service;
    return SettingsCard(
      icon: Icons.cloud_outlined,
      title: '云中转',
      subtitle: '不在同一网络也能同步：数据加密后暂存在你自建的节点，手机和电脑不用同时在线',
      highlighted: service.automaticEnabled,
      children: [
        if (_message ?? service.relayMessage case final message?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(message, style: const TextStyle(fontSize: 13, color: SeqTokens.accentInk)),
          ),
        SwitchListTile(
          value: service.automaticEnabled,
          onChanged: disabled ? null : (value) => _run(() => service.setAutomaticEnabled(value)),
          title: const Text('自动云同步'),
          subtitle: const Text('编辑后自动上传，空闲时定期拉取；断网后退避重试'),
        ),
        SwitchListTile(
          value: service.mediaSyncEnabled,
          onChanged: disabled ? null : (value) => _run(() => service.setMediaSyncEnabled(value)),
          title: const Text('同步附件和录音'),
          subtitle: const Text('包含已有原文件；移动数据下也同步，限速并按块续传'),
        ),
        if (service.mediaPending) const ListTile(
          leading: Icon(Icons.cloud_upload_outlined),
          title: Text('仍有数据待传'),
          subtitle: Text('已完成的分块会保留，下一轮继续；也可点击“云同步一次”'),
        ),
        if (service.transferredBytes > 0) ListTile(
          title: Text('本轮分块传输 ${(service.transferredBytes / 1048576).toStringAsFixed(2)} MiB'),
          subtitle: const Text('包含上传与下载；传输节流约 2 MiB/s'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _address,
                enabled: !disabled,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '节点地址（HTTP / HTTPS）',
                  hintText: 'https://sync.example.com',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await service.saveRelayEndpoint(_address.text);
                            await service.syncRelay();
                          }),
                    child: Text(_working ? '处理中…' : '云同步一次'),
                  ),
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await service.saveRelayEndpoint(_address.text);
                            if (mounted) setState(() => _message = '节点地址已保存');
                          }),
                    child: const Text('保存地址'),
                  ),
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await Clipboard.setData(
                              ClipboardData(text: service.relayNodeConfiguration),
                            );
                            if (mounted) {
                              setState(() => _message = '节点配置已复制：仅含空间 ID、配对设备公钥和配额');
                            }
                          }),
                    child: const Text('复制节点配置'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '先完成设备配对，再把节点配置保存为服务器上的 node.json；'
                '新增或撤销设备后需重新导出配置并重启节点。'
                '内容按需压缩后加密，重复内容不重复传输，离线设备可从检查点追赶。请定期备份节点数据。',
                style: TextStyle(fontSize: 12.5, height: 1.6, color: SeqTokens.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
