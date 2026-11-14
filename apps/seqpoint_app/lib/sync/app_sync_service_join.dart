part of 'app_sync_service.dart';

enum AddDeviceStage { preparing, waiting, connecting, done, failed }

/// 已连接设备上的一次"添加设备"：生成加入链接，等新设备打开后完成配对。
///
/// 持有链接即视为授权，与当面扫码配对相同；链接 10 分钟内有效且只能用一次。
class AddDeviceSession extends ChangeNotifier {
  AddDeviceSession._(this._service);
  final AppSyncService _service;
  AddDeviceStage _stage = AddDeviceStage.preparing;
  DeviceJoinLink? _link;
  DateTime? _expiresAt;
  String? _error, _joinedDevice;
  bool _cancelled = false;
  GatewayMailbox? _mailbox;

  AddDeviceStage get stage => _stage;
  DeviceJoinLink? get link => _link;
  DateTime? get expiresAt => _expiresAt;
  String? get error => _error;
  String? get joinedDevice => _joinedDevice;
  bool get active =>
      !_cancelled && _stage != AddDeviceStage.done && _stage != AddDeviceStage.failed;

  void _set(AddDeviceStage stage) {
    if (_cancelled) return;
    _stage = stage;
    notifyListeners();
  }

  void _check() {
    if (_cancelled || _service._closed) throw StateError('已取消');
  }

  Future<void> _start() async {
    final service = _service;
    try {
      service._requirePrepared();
      service._requireNormalMode();
      final origin = await service.gatewayOrigin();
      if (origin == null || !service.canSync) {
        throw const FormatException('请先连接同步服务器');
      }
      final invitation = await service.createInvitation();
      _check();
      final payload = Map<String, Object?>.of(invitation.toQrPayload());
      final link = DeviceJoinLink.create(origin, payload.remove('secret')! as String);
      final mailbox = _mailbox = GatewayMailbox(origin, link.mailbox);
      await mailbox.open(vault: service.relayVaultId!, device: service.identity!.deviceId,
          signer: service._local!.keys.signer, invitation: jsonEncode(payload));
      _check();
      _link = link;
      _expiresAt = invitation.expiresAt;
      _set(AddDeviceStage.waiting);
      final deadline = invitation.expiresAt;
      bool cancelled() => _cancelled || service._closed;
      final response = await mailbox.waitFor('response', deadline: deadline, cancelled: cancelled);
      _set(AddDeviceStage.connecting);
      final session = await service.acceptResponse(response);
      final guest = session.response.transcript.responder;
      if (guest.deviceId == service.identity!.deviceId) {
        throw const FormatException('请在另一台设备上打开加入链接');
      }
      // 新设备持有一次性秘密即为授权，与扫描配对二维码一致。
      await mailbox.write('host', await session.confirmShortCode(session.shortCode));
      await session.acceptConfirmation(
          await mailbox.waitFor('guest', deadline: deadline, cancelled: cancelled));
      _check();
      final grant = await service.finishHost(session);
      if (grant['hosted_invite'] is! String) throw StateError('同步服务器授权生成失败');
      await mailbox.write('grant', grant);
      _joinedDevice = guest.deviceId;
      // 先把新成员发布到服务器，其他设备随后即可接受它的修改。
      service._automatic?.request();
      _set(AddDeviceStage.done);
      try {
        final done = await mailbox.waitFor('done',
            deadline: DateTime.now().toUtc().add(const Duration(minutes: 3)), cancelled: cancelled);
        if (done['ok'] != true && !_cancelled) {
          _error = '新设备尚未连接同步服务器，请在新设备上点「重试连接」';
          notifyListeners();
        }
      } catch (_) {
        // 成员已保存；新设备是否登记成功以它自己的页面为准。
      }
      service._automatic?.request();
    } catch (error) {
      if (_cancelled) return;
      _error = error is FormatException
          ? error.message
          : error is SocketException || error is TimeoutException || error is HttpException
          ? '无法连接同步服务器，请检查网络后重试'
          : '添加设备未完成，请重新生成加入链接';
      _set(AddDeviceStage.failed);
    } finally {
      _mailbox?.close();
    }
  }

  void cancel() {
    if (_cancelled) return;
    final unfinished = active;
    _cancelled = true;
    _mailbox?.close();
    if (unfinished) _service.cancelPairing();
    if (identical(_service._joining, this)) _service._joining = null;
  }
}

extension _AppSyncJoin on AppSyncService {
  Future<void> _joinWithLink(String text, void Function(String step)? onProgress,
      bool Function()? cancelled) async {
    final link = DeviceJoinLink.parse(text);
    bool stopped() => _closed || (cancelled?.call() ?? false);
    void step(String message) {
      if (!stopped()) onProgress?.call(message);
    }
    step('正在读取加入链接');
    if (!prepared) await prepare(AppSyncService._defaultDeviceName());
    _requireNormalMode();
    final mailbox = GatewayMailbox(link.origin, link.mailbox);
    try {
      final slots = await mailbox.read();
      final raw = slots?['invitation'];
      if (raw is! Map<String, Object?>) {
        throw const FormatException('加入链接已过期或已被使用，请在已连接的设备上重新生成');
      }
      final payload = {...raw, 'secret': link.secret};
      final vault = payload['vault_id'];
      final reconnect = hasVault && vault == relayVaultId;
      if (hasVault && !reconnect) {
        if (!await _isSoloVault()) {
          throw const FormatException('这台设备已和其他设备组成了另一个同步空间。'
              '请在那个空间里已连接服务器的设备上点「添加设备」，或先让该空间连接同步服务器');
        }
        // 先验证邀请签名和有效期，再退出本机原有的单机空间；便签数据不受影响。
        await PairingInvitation.fromQr(payload);
        step('正在退出本机原有的单机同步空间');
        await _leaveSoloVault();
      }
      if (reconnect && await gatewayOrigin() == link.origin) return;
      final session = await respondToInvitation(payload);
      final host = session.response.transcript.initiator;
      if (host.deviceId == identity!.deviceId) {
        throw const FormatException('请在另一台设备上打开加入链接');
      }
      if (reconnect && !_sameMember(_authorize(relayVaultId!, host.deviceId), host)) {
        throw const FormatException('链接来自不在本资料库中的设备');
      }
      final deadline = session.response.transcript.expiresAt;
      await mailbox.write('response', session.response.toJson());
      step('等待已连接设备确认');
      await session.acceptConfirmation(
          await mailbox.waitFor('host', deadline: deadline, cancelled: stopped));
      await mailbox.write('guest', await session.confirmShortCode(session.shortCode));
      final grant = await mailbox.waitFor('grant', deadline: deadline, cancelled: stopped);
      step('正在接收资料库密钥');
      if (reconnect) {
        final invite = grant['hosted_invite'];
        if (invite is! String) throw const FormatException('已连接设备没有提供同步服务器授权');
        await _rememberHostedGrant(invite, host);
      } else {
        await _finishGuest(session, grant);
      }
      final pending = await pendingHostedInvite();
      if (pending == null) throw const FormatException('已连接设备没有提供同步服务器授权');
      step('正在连接同步服务器');
      try {
        await enableHosted(pending);
      } catch (_) {
        try { await mailbox.write('done', {'ok': false}); } catch (_) {}
        rethrow;
      }
      try { await mailbox.write('done', {'ok': true}); } catch (_) {}
    } finally {
      mailbox.close();
    }
  }

  /// 本机自建、没有其他成员、也从未连接过服务器的空间：退出它不会影响任何其他设备。
  Future<bool> _isSoloVault() async =>
      hasVault && !_requiresNewIdentity && !hasMembershipConflict && verifiedPeers.isEmpty &&
      (await _relaySetting()).isEmpty && await pendingHostedInvite() == null;

  /// 退出单机空间：清掉同步历史和空间密钥，保留设备身份与全部便签、事项、附件。
  Future<void> _leaveSoloVault() => _run(() async {
    _requirePrepared();
    _requireNormalMode();
    final local = _local!;
    await _runtime?.stop();
    _runtime = null;
    await _controller?.stop();
    await _membershipChanges?.cancel();
    _controller = null;
    _membershipChanges = null;
    _baselineReady = false;
    _listeningPort = null;
    _paused = false;
    // 先清数据库：若此后中断，重启会以原单机空间重新启用，不会卡在半退出状态。
    db.leaveSoloSyncVault();
    await _membershipStore(local).discardSolo(local.keys);
    if (await root.exists()) await root.delete(recursive: true);
    await root.create(recursive: true);
    await _prepare(local.identity.name);
    if (hasVault) throw StateError('退出原同步空间失败');
  });
}
