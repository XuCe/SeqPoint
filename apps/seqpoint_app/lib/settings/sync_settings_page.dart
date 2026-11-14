import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../sync/add_device_page.dart';
import '../sync/app_sync_service.dart';
import '../sync/join_qr_scan_page.dart';
import '../sync/sync_membership_controller.dart';
import '../sync/sync_pairing_page.dart';
import '../theme/seq_tokens.dart';
import 'settings_scaffold.dart';

/// 设备与同步。
///
/// 只有一种同步：所有设备经序点同步网关交换加密数据。
/// 第一台设备粘贴服务器邀请；其他设备在已连接设备上点「添加设备」，扫码或粘贴链接加入。
/// 口径必须诚实：没有连接服务器时绝不显示"已同步"。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key, this.service, this.initialLink = ''});
  final AppSyncService? service;

  /// 从邀请或加入链接唤起时预填。
  final String initialLink;

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final _name = TextEditingController(text: '此设备');
  final _identityForm = GlobalKey<FormState>();
  late final _link = TextEditingController(text: widget.initialLink);
  bool _working = false, _confirming = false;
  String? _error, _progress, _origin;
  bool _pending = false;
  int? _loadedRevision;
  AppSyncService? _loadedFor;

  @override
  void dispose() {
    _name.dispose();
    _link.dispose();
    super.dispose();
  }

  bool get _restoring =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.restoring ?? false;

  /// 服务器地址和待登记状态存放在异步存储里，按服务的设置版本刷新。
  void _reload(AppSyncService service) {
    final revision = Object.hash(service.relaySettingsRevision, service.relayVaultId,
        service.identity?.deviceId);
    if (identical(_loadedFor, service) && _loadedRevision == revision) return;
    _loadedFor = service;
    _loadedRevision = revision;
    unawaited(() async {
      String? origin;
      var pending = false;
      try {
        origin = await service.gatewayOrigin();
        pending = await service.hasPendingEnrollment();
      } catch (_) {}
      if (mounted) setState(() { _origin = origin; _pending = pending; });
    }());
  }

  Future<void> _run(AppSyncService service, Future<void> Function() action,
      {String Function(Object error)? message}) async {
    if (_working || service.busy || _restoring) return;
    setState(() { _working = true; _error = null; });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = message?.call(error) ?? service.error ?? '操作未完成，请检查设备状态后重试');
      }
    } finally {
      if (mounted) setState(() { _working = false; _progress = null; _loadedRevision = null; });
    }
  }

  String _linkError(Object error) => error is FormatException
      ? error.message
      : error is SocketException || error is TimeoutException || error is HttpException
      ? '无法连接同步服务器，请检查网络和链接中的地址'
      : '连接未完成，请检查链接后重试';

  Future<void> _connect(AppSyncService service) => _run(service, () async {
    final link = _link.text.trim();
    if (link.isEmpty) throw const FormatException('请先粘贴链接或扫一扫');
    void progress(String step) { if (mounted) setState(() => _progress = step); }
    try {
      await service.connectWithLink(link, cancelled: () => !mounted, onProgress: progress);
    } on VaultSwitchRequired catch (required) {
      if (!mounted) return;
      setState(() => _progress = null);
      if (!await _confirmSwitch(required.reasons) || !mounted) return;
      await service.connectWithLink(link, cancelled: () => !mounted, onProgress: progress,
          leaveCurrentVault: true);
    }
    if (!mounted) return;
    _link.clear();
    ScaffoldMessenger.of(context)..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已连接同步服务器，正在同步')));
    unawaited(service.syncRelay().then<void>((_) {}, onError: (Object _) {}));
  }, message: _linkError);

  Future<bool> _confirmSwitch(List<String> reasons) async {
    _confirming = true;
    try {
      return await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('换到新的同步空间？'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('这台设备目前在另一个同步空间里：'),
            const SizedBox(height: 8),
            for (final reason in reasons) Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text('· $reason'),
            ),
            const SizedBox(height: 8),
            const Text('继续后本机会先退出原空间，再加入新空间。'
                '本机的便签、事项、标签和附件都会保留，并合并到新空间。'),
          ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('退出原空间并加入')),
        ],
      )) ?? false;
    } finally {
      _confirming = false;
    }
  }

  Future<void> _confirmLeave(AppSyncService service, {required bool connected}) =>
      _run(service, () async {
    _confirming = true;
    bool? confirmed;
    try {
      confirmed = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        scrollable: true,
        title: const Text('退出同步空间？'),
        content: Text('本机的便签、事项、标签和附件都会保留，只是不再与其他设备同步。'
            '${connected ? '\n其他设备不受影响；需要时可在它们的「设备与同步」里撤销本机。' : ''}'
            '\n之后可以粘贴服务器邀请或加入链接，重新开始同步。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('退出')),
        ],
      ));
    } finally {
      _confirming = false;
    }
    if (confirmed != true || !mounted) return;
    await service.leaveVault();
    if (mounted) {
      ScaffoldMessenger.of(context)..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已退出同步空间，本机数据已保留')));
    }
  });

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text?.trim() ?? '';
    if (!mounted) return;
    setState(() {
      _link.text = text;
      _error = text.isEmpty ? '剪贴板是空的' : null;
    });
  }

  Future<void> _scan(AppSyncService service) async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const JoinQrScanPage()));
    if (code == null || !mounted) return;
    _link.text = code;
    await _connect(service);
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
    if (_restoring || service.busy || service.requiresNewIdentity || service.hasMembershipConflict ||
        !identical(version, service.membershipVersion)) {
      setState(() => _error = '成员状态已变化，请重新核对后再撤销');
      return;
    }
    await service.revokePeer(peer, expectedVersion: version);
    if (_origin != null) {
      try { await service.syncRelay(); } catch (_) {}
    }
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
      return ListenableBuilder(listenable: service, builder: (context, _) {
        _reload(service);
        return _settings(service, restoring: scope?.restoring ?? false);
      });
    }
    return const SettingsScaffold(
      title: '设备与同步',
      footnote: '当前尚未启用设备同步。',
      children: [
        _DeviceCard(status: '仅本机', detail: '此版本尚未接入设备同步服务', peers: []),
      ],
    );
  }

  Widget _settings(AppSyncService service, {required bool restoring}) {
    final disabled = restoring || _working || service.busy;
    final recovering = service.requiresNewIdentity;
    final conflicted = service.hasMembershipConflict;
    final connected = _origin != null && service.canSync;
    final peers = service.verifiedPeers, version = service.membershipVersion;
    Widget peerRow(MemberKeys peer) => _PeerRow(
          deviceId: peer.deviceId,
          onRevoke: disabled || recovering || conflicted || version == null
              ? null : () => _confirmRevoke(service, peer, version),
        );
    final message = _error ?? service.error;
    return SettingsScaffold(title: '设备与同步',
      footnote: '笔记在本机加密后经同步服务器交换，服务器看不到内容。'
        '第一台设备粘贴服务器邀请；以后的设备在已连接的设备上点「添加设备」，扫码或粘贴链接即可。',
      children: [
      if (message != null)
        ListTile(leading: const Icon(Icons.error_outline), title: Text(message)),
      if (restoring) const ListTile(title: Text('正在恢复备份，同步操作暂不可用')),
      if (_working && !_confirming) const LinearProgressIndicator(),
      if (service.prepared && !recovering &&
          (service.error != null || service.membershipState == SyncMembershipControllerState.blocked))
        ListTile(title: const Text('重新核验已保存的安全记录'),
          trailing: OutlinedButton(onPressed: disabled ? null : () => _run(service,
            () => service.prepare(service.identity?.name ?? _name.text.trim())),
            child: const Text('重新读取安全记录'))),
      if (!recovering && !conflicted) ...[
        if (service.hasVault || connected) _DeviceCard(
          status: connected ? '已连接同步服务器' : '尚未连接同步服务器',
          detail: connected
              ? (peers.isEmpty ? '${_host(_origin!)} · 添加设备后自动互相同步'
                  : '${_host(_origin!)} · ${peers.length + 1} 台设备自动同步')
              : '下方粘贴链接后开始同步',
          online: connected,
          thisDevice: service.identity?.name,
          peers: [for (final peer in peers) peerRow(peer)],
          onAdd: connected && !disabled ? () => Navigator.of(context).push<void>(
              MaterialPageRoute(builder: (_) => AddDevicePage(service: service))) : null,
        ),
        if (connected) _syncCard(service, disabled)
        else if (_pending) _retryCard(service, disabled)
        else _connectCard(service, disabled),
      ],
      if (recovering || conflicted) _recovery(service, disabled, peers, peerRow),
      if (service.hasVault && !recovering) SettingsGroup(label: '本机同步空间', children: [
        ListTile(
          title: const Text('退出同步空间'),
          subtitle: const Text('本机数据都会保留。退出后可重新连接服务器，或加入其他设备所在的空间。'),
          trailing: OutlinedButton(
            key: const ValueKey('sync-leave'),
            onPressed: disabled ? null : () => _confirmLeave(service, connected: connected),
            style: OutlinedButton.styleFrom(foregroundColor: SeqTokens.dangerInk,
                side: const BorderSide(color: SeqTokens.line)),
            child: const Text('退出'),
          ),
        ),
      ]),
    ]);
  }

  static String _host(String origin) => Uri.tryParse(origin)?.authority ?? origin;

  Widget _syncCard(AppSyncService service, bool disabled) {
    final round = service.lastRound;
    return SettingsCard(
      icon: Icons.sync_rounded,
      title: '同步',
      subtitle: service.relayMessage ?? (round == null ? service.status
          : '上次：上传 ${round.pushed} 条 · 合入 ${round.pulled} 条'),
      highlighted: service.automaticEnabled,
      children: [
        SwitchListTile(value: service.automaticEnabled,
          onChanged: disabled ? null : (value) => _run(service, () => service.setAutomaticEnabled(value)),
          title: const Text('自动同步'),
          subtitle: const Text('修改后自动上传，打开应用时定期拉取')),
        SwitchListTile(value: service.mediaSyncEnabled,
          onChanged: disabled ? null : (value) => _run(service, () => service.setMediaSyncEnabled(value)),
          title: const Text('同步附件和录音'),
          subtitle: const Text('移动数据下也会同步，分块续传')),
        if (service.mediaPending) const ListTile(
          leading: Icon(Icons.cloud_upload_outlined),
          title: Text('仍有附件待传'),
          subtitle: Text('已完成的分块会保留，下一轮继续')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Align(alignment: Alignment.centerLeft, child: FilledButton.icon(
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: Text(_working ? '同步中…' : '立即同步'),
            onPressed: disabled ? null : () => _run(service, () async { await service.syncRelay(); },
                message: (_) => service.relayMessage ?? '同步未完成，请检查网络后重试'),
          )),
        ),
      ],
    );
  }

  Widget _retryCard(AppSyncService service, bool disabled) => SettingsCard(
        icon: Icons.cloud_off_outlined,
        title: '还差一步：连接同步服务器',
        subtitle: '本机已加入资料库，但登记到同步服务器时没有完成（可能是网络中断）。',
        highlighted: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Align(alignment: Alignment.centerLeft, child: FilledButton(
              onPressed: disabled ? null : () => _run(service, () async {
                await service.retryEnrollment();
                unawaited(service.syncRelay().then<void>((_) {}, onError: (Object _) {}));
              }, message: _linkError),
              child: const Text('重试连接'),
            )),
          ),
        ],
      );

  Widget _connectCard(AppSyncService service, bool disabled) {
    final mobile = Platform.isAndroid || Platform.isIOS;
    return SettingsCard(
      icon: Icons.cloud_outlined,
      title: '连接同步服务器',
      subtitle: '第一台设备：粘贴服务器管理页生成的邀请链接。\n'
          '其他设备：在已连接的设备上点「添加设备」，${mobile ? '扫它显示的二维码' : '把它显示的链接复制过来'}。',
      highlighted: true,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              key: const ValueKey('sync-link'),
              controller: _link,
              enabled: !disabled,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              onChanged: (_) { if (_error != null) setState(() => _error = null); },
              onSubmitted: (_) => _connect(service),
              decoration: const InputDecoration(labelText: '邀请链接或加入链接',
                  hintText: 'http://… /invite#… 或 /join#…'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                onPressed: disabled ? null : () => _connect(service),
                child: Text(_working ? '连接中…' : '连接'),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('粘贴'),
                onPressed: disabled ? null : _paste,
              ),
              if (mobile) OutlinedButton.icon(
                icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                label: const Text('扫一扫'),
                onPressed: disabled ? null : () => _scan(service),
              ),
            ]),
            if (_progress case final step?) Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(step, style: const TextStyle(fontSize: 13, color: SeqTokens.inkMuted)),
            ),
          ]),
        ),
      ],
    );
  }

  /// 备份恢复或成员冲突后的处理；正常使用不会出现。
  Widget _recovery(AppSyncService service, bool disabled, List<MemberKeys> peers,
      Widget Function(MemberKeys) peerRow) {
    final recovering = service.requiresNewIdentity;
    final conflicted = service.hasMembershipConflict;
    final pending = service.pendingIdentity;
    return ExpansionTile(key: const ValueKey('sync-recovery'),
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 26),
      title: const Text('恢复同步', style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
      children: [
        SettingsGroup(label: '本机', children: [
          ListTile(title: Text(service.status)),
          if (recovering) const ListTile(title: Text('恢复后需要新设备身份'),
            subtitle: Text('旧身份不再用于发布。先生成新身份，再向可信设备重新配对；旧密钥保留。')),
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
          if (service.prepared && !recovering && conflicted) ...[
            const ListTile(title: Text('成员控制发生冲突'),
              subtitle: Text('同步已暂停。重新确认新的成员控制前，不接收或发布业务。')),
            ListTile(title: const Text('恢复成员控制'),
              subtitle: const Text('发起恢复邀请，或加入同一同步空间的恢复邀请'),
              trailing: const Icon(Icons.chevron_right),
              onTap: disabled ? null : () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => SyncPairingPage(service: service, controlRecovery: true)))),
          ],
        ]),
        if (peers.isNotEmpty)
          SettingsGroup(label: '已验证设备', children: [for (final peer in peers) peerRow(peer)]),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 设备卡：本机与已配对设备排成一列，像时间线上的点；底部是添加设备。
class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.status,
    required this.detail,
    required this.peers,
    this.online = false,
    this.thisDevice,
    this.onAdd,
  });

  final String status;
  final String detail;
  final bool online;
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
                    color: online ? SeqTokens.syncDot : SeqTokens.inkFaint)),
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
              if (onAdd != null) ...[
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
                  const Expanded(child: Text('新设备扫码或粘贴链接即可加入，无需在同一网络',
                      style: TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted))),
                ]),
              ],
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
