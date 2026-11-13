import 'dart:io';
import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import '../app/app_scope.dart';
import '../sync/app_sync_service.dart';
import '../sync/sync_pairing_page.dart';
import '../sync/lan_pairing_page.dart';
import '../sync/sync_membership_controller.dart';
import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';
import 'relay_settings.dart';
import 'syncthing_settings.dart';

/// 设备与同步。
///
/// 顶部是设备卡（本机 + 已配对设备 + 添加设备），中间是两种同步方式：
/// 局域网直连与云中转；身份、手动配对、手动连接和 Syncthing 收进"高级"。
/// 口径必须诚实：没有可达副本时绝不显示"已同步"。
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
      title: '设备与同步',
      footnote: '当前尚未启用设备同步。配对、密钥保存及连接完成后，'
          '才会通过加密文件交换数据；没有可达副本时不会显示已同步。'
          '完成验证的历史检查点可用于恢复离线设备。',
      children: [
        _DeviceCard(
          status: '仅本机',
          detail: '此版本尚未接入设备同步服务',
          peers: [],
        ),
        SettingsLabel('同步方式'),
        SettingsCard(
          icon: Icons.wifi_rounded,
          title: '局域网直连',
          subtitle: '同一网络里的设备直接交换，不经过任何服务器',
          trailing: Switch(value: false, onChanged: null),
        ),
        SettingsCard(
          icon: Icons.cloud_outlined,
          title: '云中转',
          subtitle: '不在同一网络也能同步，数据加密后暂存在节点上',
          trailing: Switch(value: false, onChanged: null),
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
    final addDevice = disabled || recovering || conflicted ? null : () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => LanPairingPage(service: service)));
    Widget peerRow(MemberKeys peer) => _PeerRow(
          deviceId: peer.deviceId,
          onRevoke: disabled || recovering || conflicted || version == null
              ? null : () => _confirmRevoke(service, peer, version),
        );
    return SettingsScaffold(title: '设备与同步',
      footnote: '配对后通过加密连接交换数据。本机上传不代表对端已收到。'
        '旧日志在检查点验证完成后回收，离线设备可从检查点继续同步。', children: [
      if (_error ?? service.error case final message?)
        ListTile(leading: const Icon(Icons.error_outline), title: Text(message)),
      if (!recovering && !conflicted) ...[
        _DeviceCard(
          status: peers.isEmpty ? '仅本机' : '已和 ${peers.length} 台设备配对',
          detail: peers.isEmpty ? '数据只在这台设备上；配对后会自动互相同步'
              : '修改在已配对设备之间加密交换',
          thisDevice: service.identity?.name,
          peers: [for (final peer in peers) peerRow(peer)],
          onAdd: addDevice,
        ),
        const SettingsLabel('同步方式'),
        SettingsCard(
          icon: Icons.wifi_rounded,
          title: '局域网直连',
          subtitle: '同一网络里的设备直接交换，不经过任何服务器',
          highlighted: service.lanEnabled,
          children: [
            SwitchListTile(value: service.lanEnabled,
              onChanged: disabled || !service.prepared ? null : (value) =>
                _run(service, () => service.setLanEnabled(value)),
              title: const Text('局域网自动双向同步'),
              subtitle: const Text('同一网络中的已配对设备自动交换修改')),
            for (final peer in service.lanPeers) ListTile(
              leading: const Icon(Icons.devices, size: 20), title: Text('设备 ${peer.deviceId.substring(0, 8)}'),
              subtitle: Text('${peer.host}:${peer.port} · ${service.lanEnabled ? '自动同步已开启' : '已暂停'}')),
          ],
        ),
        RelaySettings(key: ValueKey(service.relayVaultId), service: service, disabled: disabled),
      ],
      ExpansionTile(key: ValueKey('advanced-$recovering-$conflicted'),
        initiallyExpanded: recovering || conflicted,
        tilePadding: const EdgeInsets.symmetric(horizontal: 26),
        title: Text(recovering || conflicted ? '恢复同步' : '高级同步设置',
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
        subtitle: recovering || conflicted ? null
          : const Text('本机身份、手动配对、手动连接、Syncthing', style: TextStyle(fontSize: 12.5)),
        children: [
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
      if (peers.isNotEmpty && (recovering || conflicted))
        SettingsGroup(label: '已验证设备', children: [for (final peer in peers) peerRow(peer)]),
      if (service.prepared && !recovering && !conflicted) _connection(service, disabled),
      if (service.lastRound case final round?) SettingsGroup(label: '最近一轮', children: [
        ListTile(title: Text('本机已发布 ${round.pushed} 条 · 已合入 ${round.pulled} 条'),
          subtitle: Text('待合并记录 ${round.pendingObjects} · 等待设备 ${round.waitingPeers.length}\n'
            '尚无对端接收回执，不能据此确认两台设备内容一致')),
        for (final peer in round.waitingPeers)
          ListTile(title: const Text('等待接收的设备'), subtitle: SelectableText(peer)),
      ]),
      if (!recovering && !conflicted)
        SyncthingSettings(key: ValueKey('syncthing-${service.identity?.deviceId}-${service.relayVaultId}'),
          service: service, disabled: disabled),
      const SizedBox(height: 8),
      ]),
    ]);
  }

  Widget _connection(AppSyncService service, bool disabled) {
    final peers = service.verifiedPeers;
    final peer = peers.any((p) => p.deviceId == _peerId) ? _peerId : peers.firstOrNull?.deviceId;
    final canConnect = !disabled && service.canSync && peer != null;
    return SettingsGroup(label: '手动连接', children: [
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

/// 设备卡：本机与已配对设备排成一列，像时间线上的点；底部是添加设备。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.status,
    required this.detail,
    required this.peers,
    this.thisDevice,
    this.onAdd,
  });

  final String status;
  final String detail;
  final String? thisDevice;
  final List<Widget> peers;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Material(
          color: SeqTokens.raised,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFFECE6D8))),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle,
                    color: peers.isEmpty ? SeqTokens.inkFaint : SeqTokens.syncDot)),
                const SizedBox(width: 10),
                Expanded(child: Text(status, style: TextStyle(fontFamily: SeqFonts.serif.first,
                    fontFamilyFallback: SeqFonts.serif, fontSize: 18, fontWeight: FontWeight.w700))),
              ]),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 19),
                child: Text(detail, style: const TextStyle(fontSize: 13, color: SeqTokens.inkMuted)),
              ),
              const SizedBox(height: 14),
              _DeviceLine(icon: Icons.laptop_mac_outlined, title: thisDevice ?? '这台设备',
                  caption: '本机', first: true, last: peers.isEmpty),
              for (var i = 0; i < peers.length; i++)
                _DeviceLine.wrap(peers[i], last: i == peers.length - 1),
              const SizedBox(height: 12),
              Row(children: [
                FilledButton.icon(
                  onPressed: onAdd,
                  style: FilledButton.styleFrom(backgroundColor: SeqTokens.ink,
                      foregroundColor: SeqTokens.paper, minimumSize: const Size(0, 40)),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: const Text('添加设备'),
                ),
                const SizedBox(width: 12),
                const Expanded(child: Text('电脑显示二维码，手机扫一扫；也可输入对方 IP:端口',
                    style: TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted))),
              ]),
            ]),
          ),
        ),
      );
}

/// 设备列表里的一行：左侧圆点与竖线串起各台设备。
class _DeviceLine extends StatelessWidget {
  const _DeviceLine({required this.icon, required this.title, this.caption,
    this.first = false, this.last = false, this.child});

  factory _DeviceLine.wrap(Widget child, {required bool last}) =>
      _DeviceLine(icon: Icons.devices_other_outlined, title: '', last: last, child: child);

  final IconData icon;
  final String title;
  final String? caption;
  final bool first, last;
  final Widget? child;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 20,
            child: Stack(alignment: Alignment.topCenter, children: [
              if (!(first && last)) Positioned(
                top: first ? 18 : 0, bottom: last ? null : 0, height: last ? 18 : null,
                child: Container(width: 2, color: SeqTokens.line),
              ),
              Padding(padding: const EdgeInsets.only(top: 12), child: Container(
                width: 12, height: 12,
                decoration: BoxDecoration(shape: BoxShape.circle,
                    color: first ? SeqTokens.accent : SeqTokens.raised,
                    border: first ? null : Border.all(color: SeqTokens.syncDot, width: 2)),
              )),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(child: child ?? Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(icon, size: 18, color: SeqTokens.inkSoft),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 14.5))),
              if (caption != null) Text(caption!, style: const TextStyle(fontSize: 12.5,
                  color: SeqTokens.inkMuted)),
            ]),
          )),
        ]),
      );
}

/// 已配对设备：短编号 + 完整设备号（可复制核对）+ 撤销。
class _PeerRow extends StatelessWidget {
  const _PeerRow({required this.deviceId, required this.onRevoke});

  final String deviceId;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          const Icon(Icons.devices_other_outlined, size: 18, color: SeqTokens.inkSoft),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('设备 ${deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId}',
                style: const TextStyle(fontSize: 14.5)),
            SelectableText(deviceId, maxLines: 1,
                style: const TextStyle(fontSize: 11.5, color: SeqTokens.inkFaint)),
          ])),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onRevoke,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34),
                foregroundColor: SeqTokens.dangerInk,
                side: const BorderSide(color: SeqTokens.line)),
            child: const Text('撤销'),
          ),
        ]),
      );
}
