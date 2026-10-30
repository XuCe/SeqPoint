import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync/app_sync_service.dart';
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
    return SettingsGroup(
      label: '云中转',
      children: [
        ListTile(
          title: const Text('自建 HTTPS 节点'),
          subtitle: Text(
            _message ??
                widget.service.relayMessage ??
                '手机和电脑无需同时在线；保存节点后可自动交换数据。',
          ),
        ),
        SwitchListTile(
          value:widget.service.automaticEnabled,
          onChanged:disabled?null:(value)=>_run(()=>widget.service.setAutomaticEnabled(value)),
          title:const Text('自动云同步'),
          subtitle:const Text('编辑后自动上传，空闲时定期拉取；断网后退避重试'),
        ),
        SwitchListTile(
          value:widget.service.mediaSyncEnabled,
          onChanged:disabled?null:(value)=>_run(()=>widget.service.setMediaSyncEnabled(value)),
          title:const Text('同步附件和录音'),
          subtitle:const Text('包含已有原文件；移动数据下也同步，限速并按块续传'),
        ),
        if(widget.service.mediaPending) const ListTile(
          leading:Icon(Icons.cloud_upload_outlined),title:Text('仍有数据待传'),
          subtitle:Text('已完成的分块会保留，下一轮继续；也可点击“云同步一次”'),
        ),
        if(widget.service.transferredBytes>0) ListTile(
          title:Text('本轮分块传输 ${(widget.service.transferredBytes/1048576).toStringAsFixed(2)} MiB'),
          subtitle:const Text('包含上传与下载；传输节流约 2 MiB/s'),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _address,
                enabled: !disabled,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '节点 HTTPS 地址',
                  hintText: 'https://sync.example.com',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await widget.service.saveRelayEndpoint(
                              _address.text,
                            );
                            if (mounted) setState(() => _message = '节点地址已保存');
                          }),
                    child: const Text('保存地址'),
                  ),
                  FilledButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await widget.service.saveRelayEndpoint(
                              _address.text,
                            );
                            await widget.service.syncRelay();
                          }),
                    child: Text(_working ? '处理中…' : '云同步一次'),
                  ),
                  OutlinedButton(
                    onPressed: disabled
                        ? null
                        : () => _run(() async {
                            await Clipboard.setData(
                              ClipboardData(
                                text: widget.service.relayNodeConfiguration,
                              ),
                            );
                            if (mounted) {
                              setState(
                                () => _message = '节点配置已复制：仅含空间 ID、配对设备公钥和配额',
                              );
                            }
                          }),
                    child: const Text('复制节点配置'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                '先完成设备配对，再将节点配置保存为服务器上的 node.json。'
                '新增或撤销设备后需重新导出配置并重启节点。',
              ),
              const SizedBox(height: 8),
              const Text(
                '文字、附件和录音按需无损压缩后加密；重复内容不重复传输。'
                '历史会生成可验证检查点并回收旧日志，离线设备仍可追赶。'
                '手机回到应用后自动补传，桌面应用运行时持续同步。请定期备份节点数据。',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
