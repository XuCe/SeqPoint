import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import '../app/app_scope.dart';
import '../settings/settings_scaffold.dart';
import 'app_sync_service.dart';
import 'sync_pairing_code.dart';

class SyncPairingPage extends StatefulWidget {
  const SyncPairingPage({super.key, required this.service, this.restoring = false,
    this.identityRecovery = false, this.controlRecovery = false})
      : assert(!(identityRecovery && controlRecovery));
  final AppSyncService service;
  final bool restoring;
  final bool identityRecovery;
  final bool controlRecovery;

  @override
  State<SyncPairingPage> createState() => _SyncPairingPageState();
}

class _SyncPairingPageState extends State<SyncPairingPage> {
  bool _working = false;
  String? _error, _outgoing;
  String? _confirmationCode;
  PairingCodeKind _outKind = PairingCodeKind.invitation;
  bool _copied = false;
  bool _expired = false;
  Timer? _expiry;
  bool? _host;
  PairingHandshake? _session;
  PairingInvitation? _invitation;
  bool _ownConfirmed = false, _peerConfirmed = false;
  bool _saved = false, _grantCreated = false;
  final _short = TextEditingController();
  final _shortForm = GlobalKey<FormState>();
  final _input = TextEditingController();
  final _inputForm = GlobalKey<FormState>();

  Future<void> _run(Future<void> Function() action) async {
    if (_working || _expired || widget.service.busy || widget.restoring ||
        (context.dependOnInheritedWidgetOfExactType<AppScope>()?.restoring ?? false)) {
      return;
    }
    setState(() { _working = true; _error = null; });
    try { await action(); }
    catch (_) { _error = widget.service.error ?? '配对未完成，请核对配对码并重新开始'; }
    finally {
      if (mounted) { setState(() => _working = false); }
      else { _session?.cancel(); _invitation?.cancel(); _expiry?.cancel(); }
    }
  }

  void _watchExpiry(DateTime expiresAt) {
    if (!mounted) return;
    _expiry?.cancel();
    _expiry = Timer(expiresAt.difference(DateTime.now()), () {
      _session?.cancel(); _invitation?.cancel();
      if (mounted) setState(() { _expired = true; _outgoing = null; _confirmationCode = null; });
    });
  }
  @override
  void dispose() {
    _session?.cancel(); _invitation?.cancel();
    _expiry?.cancel();
    _input.dispose();
    _short.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final restoring = widget.restoring ||
        (context.dependOnInheritedWidgetOfExactType<AppScope>()?.restoring ?? false);
    return ListenableBuilder(listenable: widget.service, builder: (context, _) {
      final locked = restoring || _working || widget.service.busy;
      final session = _session;
      final disabled = locked || !widget.service.prepared || _expired ||
          (widget.identityRecovery && !widget.service.hasPendingIdentityRecovery && !_saved) ||
          (widget.controlRecovery && !widget.service.hasMembershipConflict && session == null);
      final active = session?.state == PairingHandshakeState.awaitingConfirmation ||
          session?.state == PairingHandshakeState.ready;
      return SettingsScaffold(
    title: widget.identityRecovery ? '恢复后重新配对' : widget.controlRecovery ? '恢复成员控制' : '配对设备',
    footnote: '配对码仅交给你信任的另一台设备。请当面核对短码。离开此页会取消未完成配对。',
    children: [SettingsGroup(label: '手动配对', children: [
      const ListTile(title: Text('两台设备先分别准备本机')),
      if (widget.identityRecovery) const ListTile(title: Text('使用新身份加入可信设备'),
        subtitle: Text('完成双方短码核对并安全保存授权前，同步保持关闭')),
      if (widget.controlRecovery) const ListTile(title: Text('重新确认成员控制'),
        subtitle: Text('本次仅重新确认配对双方，其他设备需要重新配对。')),
      if (restoring) const ListTile(title: Text('正在恢复备份，配对操作暂不可用')),
      if (_working || widget.service.busy) const LinearProgressIndicator(),
      if (_error case final message?) Semantics(liveRegion: true, child: ListTile(title: Text(message))),
      if (_expired) const ListTile(title: Text('配对码已过期，请重新开始')),
      if (_outgoing case final code?) Padding(padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('将此${_codeLabel(_outKind)}交给另一台设备'),
          SelectableText(code, maxLines: 4),
          OutlinedButton(onPressed: disabled ? null : () => _run(() async {
            await Clipboard.setData(ClipboardData(text: code)); _copied = true;
          }), child: Text('复制${_codeLabel(_outKind)}')),
          if (_copied) const Text('已复制，请仅交给你信任的设备'),
        ])),
      if (_host == null && !widget.identityRecovery) FilledButton(onPressed: disabled ||
        (widget.controlRecovery ? !widget.service.hasMembershipConflict : !widget.service.canCreateInvitation) ? null : () => _run(() async {
        final invitation = widget.controlRecovery
            ? await widget.service.createRecoveryInvitation() : await widget.service.createInvitation();
        _invitation = invitation;
        if (!mounted) { invitation.cancel(); return; }
        _watchExpiry(invitation.expiresAt);
        _outgoing = encodePairingCode(PairingCodeKind.invitation, invitation.toQrPayload());
        _outKind = PairingCodeKind.invitation; _copied = false;
        _host = true;
      }), child: Text(widget.controlRecovery ? '生成恢复邀请' : '生成邀请')),
      if (_host == null) _inputPanel(PairingCodeKind.invitation, '邀请码',
        widget.controlRecovery ? '加入恢复邀请' : '加入邀请', disabled, (payload) async {
        _session = widget.identityRecovery || widget.controlRecovery
            ? await widget.service.respondToRecoveryInvitation(payload)
            : await widget.service.respondToInvitation(payload);
        if (!mounted) { _session!.cancel(); return; }
        _watchExpiry(_session!.response.transcript.expiresAt);
        _host = false; _input.clear();
        _outgoing = encodePairingCode(PairingCodeKind.response, _session!.response.toJson());
        _outKind = PairingCodeKind.response; _copied = false;
      }),
      if (_host == true && _session == null) _inputPanel(PairingCodeKind.response, '应答码', '读取应答', disabled, (payload) async {
        _session = await widget.service.acceptResponse(payload);
        if (!mounted) { _session!.cancel(); return; }
        _input.clear();
        _watchExpiry(_session!.response.transcript.expiresAt);
      }),
      if (session != null && !_saved && !_grantCreated) ListTile(title: const Text('本机短码'),
        subtitle: Text(session.state == PairingHandshakeState.awaitingConfirmation || session.state == PairingHandshakeState.ready
          ? session.shortCode : '配对会话已失效，请重新开始')),
      if (session != null && active && !_saved && !_grantCreated) ...[
        Padding(padding: const EdgeInsets.all(16), child: Form(key: _shortForm,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('请在另一台设备核对本机短码，并在下方输入另一台设备显示的短码。'),
            TextFormField(controller: _short, enabled: !disabled && !_ownConfirmed,
              key: const ValueKey('pairing-short-code'), maxLength: 32,
              decoration: const InputDecoration(labelText: '另一台设备显示的短码'),
              validator: (value) => value == null || value.trim().isEmpty ? '请输入另一台设备的短码' : null),
            FilledButton(onPressed: disabled || _ownConfirmed ? null : () {
              if (_shortForm.currentState!.validate()) {
                _run(() async {
                final proof = await session.confirmShortCode(_short.text);
                _outgoing = encodePairingCode(PairingCodeKind.confirmation, proof);
                _confirmationCode = _outgoing;
                _outKind = PairingCodeKind.confirmation; _copied = false;
                _ownConfirmed = true;
                });
              }
            }, child: const Text('确认短码')),
          ]))),
        if (!_peerConfirmed) _inputPanel(PairingCodeKind.confirmation, '确认码', '验证对端确认', disabled, (payload) async {
          await session.acceptConfirmation(payload); _peerConfirmed = true; _input.clear();
        }),
        ListTile(title: Text(session.state == PairingHandshakeState.ready
          ? '双方短码与确认码均已验证' : '等待双方分别核对短码并交换确认码')),
      ],
      if (session != null && session.state == PairingHandshakeState.ready && !_saved && !_grantCreated)
        if (_host == true) FilledButton(onPressed: disabled ? null : () => _run(() async {
          final packet = await widget.service.finishHost(session);
          _outgoing = encodePairingCode(PairingCodeKind.grant, packet);
          _outKind = PairingCodeKind.grant; _copied = false;
          _grantCreated = true;
        }), child: const Text('安全保存并生成授权码'))
        else _inputPanel(PairingCodeKind.grant, '授权码',
          widget.controlRecovery ? '安全保存恢复' : '安全保存配对', disabled, (payload) async {
          if (widget.identityRecovery) {
            await widget.service.finishIdentityRecovery(session, payload);
          } else if (widget.controlRecovery) {
            await widget.service.recoverFromPairing(session, payload);
          } else {
            await widget.service.finishGuest(session, payload);
          }
          _expiry?.cancel();
          _saved = true; _input.clear(); _outgoing = null;
        }),
      if (_grantCreated) const ListTile(title: Text('本机授权已安全保存'),
        subtitle: Text('请将授权码交给另一台设备。尚未收到对端保存回执。')),
      if (_grantCreated && _confirmationCode != null) Padding(
        padding: const EdgeInsets.all(16), child: Column(children: [
          const Text('另一台设备仍在等待确认？先交给它本机确认码，再交付授权码。'),
          SelectableText(_confirmationCode!, maxLines: 4),
          OutlinedButton(onPressed: disabled ? null : () => _run(() async {
            await Clipboard.setData(ClipboardData(text: _confirmationCode!));
          }), child: const Text('复制确认码')),
        ])),
      if (_saved) ListTile(title: Text(widget.controlRecovery ? '成员控制已安全恢复' : '配对已安全保存'),
        subtitle: const Text('回到同步设置，输入对端 IP 和端口后手动同步')),
      TextButton(onPressed: locked ? null : () {
        widget.service.cancelPairing(); _session?.cancel();
        _expiry?.cancel();
        setState(() {
          _host = null; _session = null; _outgoing = null; _error = null;
          _invitation = null;
          _confirmationCode = null;
          _ownConfirmed = false; _peerConfirmed = false; _saved = false; _grantCreated = false;
          _copied = false;
          _expired = false;
          _input.clear(); _short.clear();
        });
      }, child: const Text('取消并重新开始')),
    ])],
  );
    });
  }

  String _codeLabel(PairingCodeKind kind) => switch (kind) {
    PairingCodeKind.invitation => '邀请码', PairingCodeKind.response => '应答码',
    PairingCodeKind.confirmation => '确认码', PairingCodeKind.grant => '授权码',
  };

  Widget _inputPanel(PairingCodeKind kind, String label, String action, bool disabled,
      Future<void> Function(Map<String, Object?>) next) =>
    Padding(padding: const EdgeInsets.all(16), child: Form(key: _inputForm,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextFormField(controller: _input, enabled: !disabled, maxLines: 4,
          key: const ValueKey('pairing-input'),
          decoration: InputDecoration(labelText: '粘贴对端$label'),
          validator: (value) {
            try { decodePairingCode(value ?? '', kind); return null; }
            catch (_) { return '请输入有效的$label'; }
          }),
        FilledButton(onPressed: disabled ? null : () {
          if (_inputForm.currentState!.validate()) {
            _run(() => next(decodePairingCode(_input.text, kind)));
          }
        }, child: Text(action)),
      ])));
}
