import 'package:flutter/material.dart';

import '../sync/app_sync_service.dart';
import 'settings_scaffold.dart';

class SyncthingSettings extends StatefulWidget {
  const SyncthingSettings({
    super.key,
    required this.service,
    required this.disabled,
  });
  final AppSyncService service;
  final bool disabled;
  @override
  State<SyncthingSettings> createState() => _SyncthingSettingsState();
}

class _SyncthingSettingsState extends State<SyncthingSettings> {
  final _address = TextEditingController(), _key = TextEditingController();
  bool _loading = true, _working = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await widget.service.loadSyncthingAddress();
      if (mounted) _address.text = value;
    } catch (_) {
      _error = '安全配置读取失败，请重新填写';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working || _loading || widget.disabled || widget.service.busy) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '操作未完成，请检查配对、管理地址、API Key 和 NAS 状态');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => _content(context);

  List<Widget> _fields(bool disabled) => [
    TextField(
      controller: _address,
      enabled: !disabled,
      key: const ValueKey('syncthing-address'),
      keyboardType: TextInputType.url,
      autocorrect: false,
      decoration: const InputDecoration(
        labelText: 'NAS 管理地址（域名＋端口）',
        hintText: 'nas.example.com:8384',
      ),
    ),
    const SizedBox(height: 12),
    TextField(
      controller: _key,
      enabled: !disabled,
      obscureText: true,
      key: const ValueKey('syncthing-api-key'),
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(
        labelText: '管理 API Key',
        hintText: '首次填写；相同地址留空可保留已存密钥',
      ),
    ),
  ];

  Widget _buttons(bool disabled) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      FilledButton(
        onPressed: disabled
            ? null
            : () => _run(() async {
                await widget.service.saveSyncthing(
                  address: _address.text,
                  apiKey: _key.text,
                );
                if (mounted) _key.clear();
              }),
        child: const Text('保存并授权'),
      ),
      OutlinedButton(
        onPressed: disabled || !widget.service.syncthingEnabled
            ? null
            : () => _run(() async {
                await widget.service.syncSyncthing();
              }),
        child: const Text('同步一次'),
      ),
    ],
  );

  Widget _content(BuildContext context) {
    final service = widget.service;
    final disabled =
        widget.disabled ||
        service.busy ||
        !service.canSync ||
        !service.syncthingSupported ||
        _loading ||
        _working;
    return SettingsGroup(
      label: 'Syncthing 跨网同步',
      children: [
        ListTile(
          title: const Text('连接自己的 NAS'),
          subtitle: Text(
            _error ??
                (service.syncthingMessage.isNotEmpty
                    ? service.syncthingMessage
                    : '先在局域网配对，再配置 NAS；两台设备无需同时在线。'),
          ),
        ),
        SwitchListTile(
          value: service.syncthingEnabled,
          onChanged: disabled
              ? null
              : (value) => _run(() => service.setSyncthingEnabled(value)),
          title: const Text('开启跨网同步'),
        ),
        SwitchListTile(
          value: service.mediaSyncEnabled,
          onChanged: disabled
              ? null
              : (value) => _run(() => service.setMediaSyncEnabled(value)),
          title: const Text('同步附件和录音'),
          subtitle: const Text('原文件加密传输；移动网络也会同步'),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ..._fields(disabled),
              const SizedBox(height: 12),
              _buttons(disabled),
              const SizedBox(height: 12),
              const Text(
                '填写管理 API 的域名和端口，不是 22000 传输端口。'
                '公网默认使用 HTTPS；API Key 只保存在本机安全存储。手机在前台同步。',
              ),
              if (!service.canSync) const Text('请先完成局域网设备配对。'),
              if (!service.syncthingSupported)
                const Text('当前平台未包含 Syncthing 引擎。'),
              if (_working) const LinearProgressIndicator(),
            ],
          ),
        ),
      ],
    );
  }
}
