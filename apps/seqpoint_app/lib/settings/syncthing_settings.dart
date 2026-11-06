import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'hosted_setup.dart';

import '../sync/app_sync_service.dart';
import 'settings_scaffold.dart';
import 'syncthing_setup_guide.dart';

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
  String? _error, _hosted, _gateway;
  int? _relayRevision;
  bool? _seenEnabled;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SyncthingSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_relayRevision != widget.service.relaySettingsRevision || _seenEnabled != widget.service.syncthingEnabled) _load();
  }

  Future<void> _load() async {
    _relayRevision = widget.service.relaySettingsRevision;
    _seenEnabled = widget.service.syncthingEnabled;
    try {
      final value = await widget.service.loadSyncthingAddress();
      final gateway = await widget.service.gatewayOrigin();
      final hosted = await widget.service.hostedOrigin();
      if (mounted) {
        _hosted = hosted; _gateway = gateway;
        _address.text = hosted == null ? value : '';
      }
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
      if (mounted) setState(() => _error = _gateway != null ? widget.service.relayMessage ?? '请检查网关连接' : '操作未完成，请检查节点连接和授权');
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
        labelText: 'Syncthing 管理 API 地址',
        hintText: 'http://192.168.1.10:8384',
        helperText: '填写内网或 VPN 可达的 HTTP(S) 地址；不是 22000 传输地址',
        helperMaxLines: 3,
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
        labelText: 'Syncthing API Key',
        hintText: '首次填写；相同地址留空可保留已存密钥',
        helperText: '在 Syncthing「操作 → 设置 → 常规」中获取',
        helperMaxLines: 2,
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
      label: '跨网同步',
      children: [
        ListTile(
          title: Text(_gateway != null ? '序点同步网关' : _hosted == null ? '启用云同步' : '托管云节点'),
          subtitle: Text(_error ?? (_gateway ?? _hosted ?? '使用运营方邀请开通，配对后自动加入同一节点')),
          trailing: const Icon(Icons.chevron_right),
          onTap: widget.disabled || _loading ? null : () async {
            final pending = await service.pendingHostedInvite();
            if (!context.mounted) return;
            await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) =>
              HostedSetup(service: service, link: pending ?? '')));
            if (mounted) await _load();
          },
        ),
        if (service.syncthingMessage.isNotEmpty) ListTile(subtitle: Text(service.syncthingMessage)),
        if (_gateway != null || (_hosted != null && service.syncthingEnabled))
          for (final peer in service.verifiedPeers)
            ListTile(title: const Text('复制此设备的加入链接'), subtitle: Text(peer.deviceId),
              onTap: widget.disabled || _working ? null : () => _run(() async {
                final link = await service.hostedGrant(peer);
                if (link != null) await Clipboard.setData(ClipboardData(text: link));
              })),
        if (_gateway != null) ListTile(
          title: const Text('网关同步'), subtitle: Text(service.relayMessage ?? '已开通，等待上传到网关'),
          trailing: TextButton(onPressed: widget.disabled || _working ? null :
              () => _run(() async {await service.syncRelay();}), child: const Text('同步一次'))),
        SwitchListTile(
          value: service.mediaSyncEnabled,
          onChanged: widget.disabled || _working || !service.canSync
              ? null
              : (value) => _run(() => service.setMediaSyncEnabled(value)),
          title: const Text('同步附件和录音'),
          subtitle: const Text('原文件加密传输；移动网络也会同步'),
        ),
        if (_hosted != null) OutlinedButton(onPressed: disabled || !service.syncthingEnabled
            ? null : () => _run(() async {await service.syncSyncthing();}), child: const Text('同步一次')),
        ExpansionTile(title: const Text('自建 Syncthing 节点'), children: [
        SwitchListTile(
          value: service.syncthingEnabled,
          onChanged: disabled
              ? null
              : (value) => _run(() => service.setSyncthingEnabled(value)),
          title: const Text('开启跨网同步'),
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
                '当前方式会自动授权设备和共享目录，每轮同步仍需访问管理 API。'
                '请通过内网或 VPN 连接，不要将 8384 管理端口映射到公网；'
                '只开放 22000 无法完成本页的自动配置。'
                'API Key 仅保存在本机安全存储，手机需在前台同步。',
              ),
              if (!service.canSync) const Text('请先完成局域网设备配对。'),
              if (!service.syncthingSupported)
                const Text('当前平台未包含 Syncthing 引擎。'),
              if (_working) const LinearProgressIndicator(),
            ],
          ),
        ),
        const SyncthingSetupGuide(),
        ]),
      ],
    );
  }
}
