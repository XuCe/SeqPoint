import 'dart:io';
import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import '../app/app_scope.dart';
import '../sync/app_sync_service.dart';
import '../sync/sync_pairing_page.dart';
import '../sync/lan_pairing_page.dart';
import '../sync/sync_membership_controller.dart';
import 'settings_scaffold.dart';
import 'relay_settings.dart';
import 'syncthing_settings.dart';

/// 同步设置。
///
/// 三条精简通道 + 一个可选引擎。口径必须诚实：
/// 没有可达副本时绝不显示"已同步"。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key, this.service});
  final AppSyncService? service;

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final _name = TextEditingController(text: '此设备');
  final _identityForm = GlobalKey<FormState>();
  final _connectionForm = GlobalKey<FormState>();
  final _host = TextEditingController(), _port = TextEditingController();
  String? _peerId;
  bool _working = false, _confirming = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _host.dispose(); _port.dispose();
    super.dispose();
  }

  Future<void> _run(AppSyncService service, Future<void> Function() action) async {
    if (_working || service.busy ||
        (context.dependOnInheritedWidgetOfExactType<AppScope>()?.restoring ?? false)) {
      return;
    }
    setState(() { _working = true; _error = null; });
    try { await action(); }
    catch (_) {
      if (mounted) setState(() => _error = service.error ?? '操作未完成，请检查设备状态后重试');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _confirmRevoke(AppSyncService service, MemberKeys peer, Object version) =>
      _run(service, () async {
    _confirming = true;
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
      scrollable: true, title: const Text('撤销此设备？'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
        children: [SelectableText(peer.deviceId), const SizedBox(height: 12),
          const Text('撤销后，该设备不再接收新的同步数据；其他成员会在后续同步时更新。'
            '\n此操作不会远程删除该设备已有的数据。')]),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('确认撤销'))]));
    } finally { _confirming = false; }
    if (confirmed != true || !mounted) return;
    final restoring = context.dependOnInheritedWidgetOfExactType<AppScope>()?.restoring ?? false;
    if (restoring || service.busy || service.requiresNewIdentity || service.hasMembershipConflict ||
        !identical(version, service.membershipVersion)) {
      setState(() => _error = '成员状态已变化，请重新核对后再撤销');
      return;
    }
    await service.revokePeer(peer, expectedVersion: version);
    if (mounted) {
      ScaffoldMessenger.of(context)..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('设备已撤销')));
    }
  });

  @override
  Widget build(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    final service = widget.service ?? scope?.sync;
    if (service != null) {
      return ListenableBuilder(listenable: service, builder: (context, _) =>
          _settings(service, restoring: scope?.restoring ?? false));
    }
    return const SettingsScaffold(
      title: '同步',
      footnote: '当前尚未启用设备同步。配对、密钥保存及连接完成后，'
          '才会通过加密文件交换数据；没有可达副本时不会显示已同步。'
          '完成验证的历史检查点可用于恢复离线设备。',
      children: [
        SettingsGroup(
          label: '通道',
          children: [
            SwitchListTile(
              value: false,
              onChanged: null,
              title: Text('本地目录'),
              subtitle: Text('把数据放进网盘同步目录或 NAS 挂载盘'),
            ),
            SwitchListTile(
              value: false,
              onChanged: null,
              title: Text('局域网直连'),
              subtitle: Text('开发中 · 手动连接对端地址，核对配对短码'),
            ),
            SwitchListTile(
              value: false,
              onChanged: null,
              title: Text('云中转'),
              subtitle: Text('异地异时也能同步，数据加密暂存'),
            ),
          ],
        ),
        SettingsGroup(
          label: '设备直连 / NAS 互通',
          children: [
            ListTile(
              title: Text('Syncthing 引擎'),
              subtitle: Text('尚未接入'),
              trailing: Icon(Icons.chevron_right, size: 18),
            ),
          ],
        ),
        SettingsGroup(
          label: '状态',
          children: [
            ListTile(
              leading: Icon(Icons.circle, size: 8),
              title: Text('仅本机'),
              subtitle: Text('此版本尚未接入设备同步服务'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _settings(AppSyncService service, {required bool restoring}) {
    final disabled = restoring || _working || service.busy;
    final recovering = service.requiresNewIdentity;
    final pending = service.pendingIdentity;
    final conflicted = service.hasMembershipConflict;
    final peers = service.verifiedPeers, version = service.membershipVersion;
    return SettingsScaffold(title: '同步',
      footnote: '配对后通过加密连接交换数据。本机上传不代表对端已收到。'
        '旧日志在检查点验证完成后回收，离线设备可从检查点继续同步。', children: [
      SettingsGroup(label: '局域网同步', children: [
        if (_error ?? service.error case final message?)
          ListTile(leading: const Icon(Icons.error_outline), title: Text(message)),
        for (final peer in service.lanPeers) ListTile(
          leading: const Icon(Icons.devices), title: Text('设备 ${peer.deviceId.substring(0, 8)}'),
          subtitle: Text('${peer.host}:${peer.port} · ${service.lanEnabled ? '自动同步已开启' : '已暂停'}')),
        SwitchListTile(value: service.lanEnabled,
          onChanged: disabled || !service.prepared ? null : (value) =>
            _run(service, () => service.setLanEnabled(value)),
          title: const Text('局域网自动双向同步'),
          subtitle: const Text('同一网络中的已配对设备自动交换修改')),
        ListTile(title: const Text('连接手机或电脑'),
          subtitle: const Text('电脑显示二维码，手机扫一扫；也可输入对方 IP:端口'),
          leading: const Icon(Icons.qr_code_scanner), trailing: const Icon(Icons.chevron_right),
          onTap: disabled || recovering || conflicted ? null : () => Navigator.of(context).push<void>(
            MaterialPageRoute(builder: (_) => LanPairingPage(service: service)))),
      ]),
      SyncthingSettings(key: ValueKey('syncthing-${service.identity?.deviceId}-${service.relayVaultId}'),
          service: service, disabled: disabled || recovering || conflicted),
      ExpansionTile(title: const Text('高级同步设置'), children: [
      SettingsGroup(label: '本机', children: [
        ListTile(title: Text(service.status)),
        if (restoring) const ListTile(title: Text('正在恢复备份，同步操作暂不可用')),
        if (recovering) const ListTile(title: Text('恢复后需要新设备身份'),
          subtitle: Text('旧身份不再用于发布。先生成新身份，再向可信设备重新配对；旧密钥保留。')),
        if (disabled && !_confirming) const LinearProgressIndicator(),
        if (!service.prepared || (recovering && !service.hasPendingIdentityRecovery)) Padding(
          padding: const EdgeInsets.all(16),
          child: Form(key: _identityForm, child: Column(children: [
            TextFormField(controller: _name, enabled: !disabled, maxLength: 64,
              key: const ValueKey('sync-device-name'),
              decoration: const InputDecoration(labelText: '本机名称'),
              validator: (value) => value == null || value.trim().isEmpty ? '请输入本机名称' : null),
            FilledButton(onPressed: disabled ? null : () {
              if (_identityForm.currentState!.validate()) {
                _run(service, () async {
                  if (recovering && service.prepared) {
                    await service.beginIdentityRecovery(_name.text.trim());
                  } else {
                    await service.prepare(_name.text.trim());
                  }
                });
              }
            }, child: Text(recovering && service.prepared ? '生成新身份' : '准备本机')),
          ])),
        ),
        if (recovering && service.hasPendingIdentityRecovery && pending != null) ...[
          ListTile(title: Text('新身份 ${pending.name}'), subtitle: SelectableText(pending.deviceId)),
          ListTile(title: const Text('用新身份重新配对'),
            subtitle: const Text('接收可信设备的邀请码，双方核对短码后才启用同步'),
            trailing: const Icon(Icons.chevron_right),
            onTap: disabled ? null : () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => SyncPairingPage(service: service, identityRecovery: true)))),
        ],
        if (service.prepared && !recovering) ...[
          ListTile(title: Text(service.identity?.name ?? _name.text),
            subtitle: const Text('安全身份已准备；传输结果见最近一轮')),
          if (service.error != null || service.membershipState == SyncMembershipControllerState.blocked)
            ListTile(title: const Text('重新核验已保存的安全记录'),
              trailing: OutlinedButton(onPressed: disabled ? null : () => _run(service,
                () => service.prepare(service.identity?.name ?? _name.text.trim())),
                child: const Text('重新读取安全记录'))),
          if (!service.hasVault) ListTile(
            title: const Text('首次设置：创建同步空间'),
            subtitle: const Text('已有另一台设备？直接加入邀请，无需在此创建'),
            trailing: OutlinedButton(onPressed: disabled ? null : () =>
              _run(service, service.newVault), child: const Text('创建同步空间'))),
          if (conflicted) ...[
            const ListTile(title: Text('成员控制发生冲突'),
              subtitle: Text('同步已暂停。重新确认新的成员控制前，不接收或发布业务。')),
            ListTile(title: const Text('恢复成员控制'),
              subtitle: const Text('发起恢复邀请，或加入同一同步空间的恢复邀请'),
              trailing: const Icon(Icons.chevron_right),
              onTap: disabled ? null : () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => SyncPairingPage(service: service, controlRecovery: true)))),
          ],
          if (!conflicted) ListTile(title: const Text('手动配对设备'),
            subtitle: const Text('人工交换配对码，双方核对短码后安全保存'),
            trailing: const Icon(Icons.chevron_right),
            onTap: disabled ? null : () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => SyncPairingPage(service: service)))),
        ],
      ]),
      if (peers.isNotEmpty) SettingsGroup(label: '已验证设备', children: [
        for (final peer in peers) ListTile(title: SelectableText(peer.deviceId),
          trailing: OutlinedButton(onPressed: disabled || recovering || conflicted || version == null
            ? null : () => _confirmRevoke(service, peer, version), child: const Text('撤销'))),
      ]),
      if (service.prepared && !recovering && !conflicted) _connection(service, disabled),
      if (service.lastRound case final round?) SettingsGroup(label: '最近一轮', children: [
        ListTile(title: Text('本机已发布 ${round.pushed} 条 · 已合入 ${round.pulled} 条'),
          subtitle: Text('待合并记录 ${round.pendingObjects} · 等待设备 ${round.waitingPeers.length}\n'
            '尚无对端接收回执，不能据此确认两台设备内容一致')),
        for (final peer in round.waitingPeers)
          ListTile(title: const Text('等待接收的设备'), subtitle: SelectableText(peer)),
      ]),
      RelaySettings(key: ValueKey(service.relayVaultId), service: service, disabled: disabled),
      ]),
      const SettingsGroup(label: '其他通道', children: [
        SwitchListTile(value: false, onChanged: null, title: Text('本地目录'),
          subtitle: Text('尚未接入')),
      ]),
    ]);
  }

  Widget _connection(AppSyncService service, bool disabled) {
    final peers = service.verifiedPeers;
    final peer = peers.any((p) => p.deviceId == _peerId) ? _peerId : peers.firstOrNull?.deviceId;
    final canConnect = !disabled && service.canSync && peer != null;
    return SettingsGroup(label: '局域网直连', children: [
      if (peers.isEmpty) const ListTile(title: Text('先完成配对，再连接已验证设备')),
      if (service.listeningPort case final port?) ListTile(
        title: Text('正在监听端口 $port'), subtitle: const Text('在另一台设备输入本机 IP 和此端口')),
      Padding(padding: const EdgeInsets.all(16), child: Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: disabled || !service.canSync || service.listeningPort != null
          ? null : () => _run(service, () async {
            await service.startServer(address: InternetAddress.anyIPv4);
          }), child: const Text('开始局域网监听')),
        OutlinedButton(onPressed: disabled ? null : () => _run(service, service.pause),
          child: const Text('暂停同步')),
      ])),
      Padding(padding: const EdgeInsets.all(16), child: Form(key: _connectionForm,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (peers.isNotEmpty) DropdownButton<String>(value: peer, isExpanded: true,
            hint: const Text('已验证的对端'),
            items: [for (final p in peers) DropdownMenuItem(value: p.deviceId,
              child: Text('已验证设备 ${p.deviceId.substring(0, 12)}'))],
            onChanged: disabled ? null : (value) => setState(() => _peerId = value)),
          TextFormField(controller: _host, enabled: canConnect,
            key: const ValueKey('sync-host'),
            decoration: const InputDecoration(labelText: '对端 IP 地址'),
            validator: (value) => InternetAddress.tryParse(value?.trim() ?? '') == null
              ? '请输入有效的 IP 地址' : null),
          TextFormField(controller: _port, enabled: canConnect,
            key: const ValueKey('sync-port'), keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '对端端口'),
            validator: (value) { final port = int.tryParse(value?.trim() ?? '');
              return port == null || port < 1 || port > 65535 ? '端口应为 1–65535' : null; }),
          FilledButton(onPressed: !canConnect ? null : () {
            if (_connectionForm.currentState!.validate()) {
              _run(service, () async { await service.syncOnce(peerDeviceId: peer,
                host: _host.text.trim(), port: int.parse(_port.text.trim())); });
            }
          }, child: const Text('连接并同步一次')),
        ]))),
    ]);
  }
}
