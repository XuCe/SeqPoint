part of 'app_sync_service.dart';

class LanPairingCoordinator extends ChangeNotifier {
  LanPairingCoordinator(this._service);
  final AppSyncService _service;
  LanPairingServer? _server;
  LanPairingClient? _client;
  PairingInvitation? _ticket;
  PairingHandshake? _session;
  Timer? _expiry;
  String? _token, _peerHost, connectedPeer, error;
  String _status = '未连接';
  bool _host = false, _authorized = false, _reconnect = false;
  bool _closed = true;
  int _generation = 0;
  Future<void>? _closing;
  final _pending = <Future<Object?>>{};
  int _stage = 0;
  Map<String, Object?>? _confirmation;
  LanPairingLink? link;
  String get status => _status;
  String? _shortCode;
  String? get shortCode => _shortCode;
  LanPeer? connectedAddress;
  bool get awaitingApproval =>
      _server != null && !_authorized && _session != null && !_closed;
  int? get port => _server?.port;
  List<LanPairingAddress> addresses = [];
  String _random() =>
      base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)));
  Map<String, Object?> _map(Object? value) =>
      Map<String, Object?>.from(value as Map);
  void _changed(String status) {
    _status = status;
    notifyListeners();
  }

  void _requireOpen() {
    if (_closed || _service._closed) throw StateError('配对已结束');
  }

  Future<T> _track<T>(Future<T> Function() action) async {
    _requireOpen();
    final operation = Future<T>.sync(action);
    _pending.add(operation);
    try {
      return await operation;
    } finally {
      _pending.remove(operation);
    }
  }

  Future<void> _begin(Future<void> Function() action) async {
    final generation = ++_generation;
    await _drain();
    if (generation != _generation || _service._closed) {
      throw StateError('配对已取消');
    }
    _closed = false;
    await _track(action);
  }

  Future<void> _drain() =>
      _closing ??= _drainAll().whenComplete(() => _closing = null);
  Future<void> _drainAll() async {
    _closed = true;
    await _shutdown();
    await Future.wait(
      _pending.toList().map((operation) async {
        try {
          await operation;
        } catch (_) {}
      }),
    );
    await _shutdown();
  }

  Future<Map<String, Object?>> _receive(
    Map<String, Object?> message,
    InternetAddress peer,
  ) => _track(() => _receiveMessage(message, peer));

  Future<Map<String, Object?>> _receiveMessage(
    Map<String, Object?> message,
    InternetAddress peer,
  ) async {
    _requireOpen();
    if (message['action'] == 'hello') return _hello(message, peer);
    if (message['token'] != _token ||
        _token == null ||
        peer.address != _peerHost) {
      throw StateError('连接会话不匹配');
    }
    switch (message['action']) {
      case 'handshake':
        return _handshake(message);
      case 'poll':
        return {'confirmation': _confirmation};
      case 'confirm':
        return _confirm(message);
      case 'ack':
        if (_stage != 4) throw StateError('对端尚未保存配对');
        await _service._rememberLanPeer(connectedAddress!);
        _requireOpen();
        _stage = 5;
        connectedPeer = _peer.deviceId;
        _expiry?.cancel();
        _expiry = Timer(const Duration(seconds: 1), () => unawaited(_retire()));
        _changed('已连接');
        return {'ok': true};
      case 'saved':
        return _saved(message);
      default:
        throw const FormatException('未知配对消息');
    }
  }

  PairingParticipant get _peer => _host
      ? _session!.response.transcript.responder
      : _session!.response.transcript.initiator;

  Future<Map<String, Object?>> _handshake(Map<String, Object?> message) async {
    if (_stage != 1) throw StateError('配对顺序错误');
    _session = _host
        ? await _service.acceptResponse(_map(message['response']))
        : await _service.respondToInvitation(_map(message['invitation']));
    _requireOpen();
    _shortCode = _session!.shortCode;
    if (_reconnect &&
        !_service._sameMember(
          _service._authorize(_service.relayVaultId!, _peer.deviceId),
          _peer,
        )) {
      throw StateError('已配对设备身份不匹配');
    }
    if (_authorized) {
      _confirmation = await _session!.confirmShortCode(_shortCode!);
    }
    _requireOpen();
    _stage = 2;
    _changed(_authorized ? '正在建立连接' : '请核对两端短码并允许');
    return {
      if (!_host) 'response': _session!.response.toJson(),
      'confirmation': _confirmation,
    };
  }

  Future<Map<String, Object?>> _confirm(Map<String, Object?> message) async {
    if (_stage != 2 || !_authorized) throw StateError('尚未允许配对');
    await _session!.acceptConfirmation(_map(message['confirmation']));
    if (_host && !_service.hasVault) {
      await _service._newVault(
        vaultPublicId: _session!.response.transcript.vaultPublicId,
      );
    }
    final grant = _host && !_reconnect
        ? await _service.finishHost(_session!)
        : null;
    _requireOpen();
    _stage = 3;
    return {'grant': grant};
  }

  Future<Map<String, Object?>> _hello(
    Map<String, Object?> message,
    InternetAddress peer,
  ) async {
    if (_stage != 0 ||
        message['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_=-]{44}$').hasMatch(message['token'] as String)) {
      throw StateError('已有配对连接');
    }
    final vault = message['vault'];
    if (vault != null && (vault is! String || vault.length > 128)) {
      throw const FormatException('同步空间标识错误');
    }
    if (_service.hasVault && vault != null && vault != _service.relayVaultId) {
      throw StateError('两台设备属于不同同步空间，不能直接合并');
    }
    _ticket!.checkActive();
    _authorized = message['ticket'] == base64UrlEncode(_ticket!.pairingSecret);
    _token = message['token'] as String;
    _peerHost = peer.address;
    _stage = 1;
    _reconnect = _service.hasVault && vault == _service.relayVaultId;
    _host = _service.hasVault || vault == null;
    PairingInvitation? invitation;
    if (_host) {
      if (_service.hasVault) {
        invitation = await _service.createInvitation();
      } else {
        _service.cancelPairing();
        invitation = await PairingInvitation.create(
          keys: _service._local!.keys,
          vaultPublicId: _ticket!.vaultPublicId,
          tlsFingerprint: _service._tls!.fingerprint,
        );
        _service._invitation = invitation;
      }
    }
    return {
      'host': _host,
      'reconnect': _reconnect,
      if (_host) 'invitation': invitation!.toQrPayload(),
    };
  }

  Future<Map<String, Object?>> _saved(Map<String, Object?> message) async {
    if (_stage != 3) throw StateError('配对尚未确认');
    final peerPort = message['port'];
    if (peerPort is! int || peerPort < 1 || peerPort > 65535) {
      throw const FormatException('监听端口错误');
    }
    if (!_host && !_reconnect) {
      await _service.finishGuest(_session!, _map(message['grant']));
    }
    _requireOpen();
    final localPort = await _service.startServer();
    _requireOpen();
    connectedAddress = LanPeer(
      deviceId: _peer.deviceId,
      host: _peerHost!,
      port: peerPort,
      tlsFingerprint: _peer.tlsFingerprint,
    );
    _stage = 4;
    return {'port': localPort};
  }

  Future<void> connect(LanPairingLink invitation) => _begin(() async {
    final verified = await LanPairingLink.decode(invitation.encode());
    _requireOpen();
    await _connectActive(
      verified.addresses.first,
      invitation: verified.invitation,
      alternatives: verified.addresses.skip(1).toList(),
    );
  });

  Future<void> connectAddress(LanPairingAddress address) => _connect(address);

  Future<Map<String, Object?>> _post(
    String action, [
    Map<String, Object?> body = const {},
  ]) {
    _requireOpen();
    return _client!.post({'action': action, 'token': _token, ...body});
  }

  Future<void> _connect(
    LanPairingAddress address, {
    PairingInvitation? invitation,
  }) => _begin(() => _connectActive(address, invitation: invitation));

  Future<void> _connectActive(
    LanPairingAddress address, {
    PairingInvitation? invitation,
    List<LanPairingAddress> alternatives = const [],
  }) async {
    _service._requirePrepared();
    _service._requireNormalMode();
    _closed = false;
    connectedPeer = null;
    error = null;
    _token = _random();
    _expiry = Timer(const Duration(minutes: 10), () => unawaited(close()));
    _changed('正在连接');
    try {
      Map<String, Object?>? hello;
      final candidates = [address, ...alternatives];
      for (final candidate in candidates) {
        _requireOpen();
        _client?.close();
        _client = LanPairingClient(
          candidate,
          expectedFingerprint: invitation?.initiator.tlsFingerprint,
        );
        try {
          hello = await _post('hello', {
            'vault': _service.relayVaultId,
            if (invitation != null)
              'ticket': base64UrlEncode(invitation.pairingSecret),
          });
          address = candidate;
          break;
        } catch (error) {
          if ((error is! SocketException && error is! TimeoutException) ||
              candidate == candidates.last) {
            rethrow;
          }
        }
      }
      _requireOpen();
      await _exchange(address, hello!);
    } catch (_) {
      await _shutdown();
      error = '连接失败或已取消，请检查地址并重新配对';
      _changed('连接失败');
      rethrow;
    }
  }

  Future<void> _exchange(
    LanPairingAddress address,
    Map<String, Object?> hello,
  ) async {
    _host = hello['host'] == false;
    _reconnect = hello['reconnect'] == true;
    Map<String, Object?> reply;
    if (_host) {
      if (!_service.hasVault) throw StateError('同步空间缺失');
      final invitation = await _service.createInvitation();
      reply = await _post('handshake', {
        'invitation': invitation.toQrPayload(),
      });
      _session = await _service.acceptResponse(_map(reply['response']));
    } else {
      final invitation = await PairingInvitation.fromQr(
        _map(hello['invitation']),
      );
      if (_service.hasVault &&
          invitation.vaultPublicId != _service.relayVaultId) {
        throw StateError('两台设备属于不同同步空间');
      }
      if (invitation.initiator.tlsFingerprint != _client!.fingerprint) {
        throw StateError('邀请身份与连接证书不匹配');
      }
      _session = await _service.respondToInvitation(invitation.toQrPayload());
      reply = await _post('handshake', {
        'response': _session!.response.toJson(),
      });
    }
    if (_peer.tlsFingerprint != _client!.fingerprint ||
        (_reconnect &&
            !_service._sameMember(
              _service._authorize(_service.relayVaultId!, _peer.deviceId),
              _peer,
            ))) {
      throw StateError('对端授权身份不匹配');
    }
    _shortCode = _session!.shortCode;
    _changed('请在对端核对短码并允许连接');
    while (reply['confirmation'] == null) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      reply = await _post('poll');
    }
    // The listener's proof is issued only for a QR capability or explicit approval.
    await _session!.acceptConfirmation(_map(reply['confirmation']));
    final confirmation = await _session!.confirmShortCode(_shortCode!);
    final grant = await _post('confirm', {'confirmation': confirmation});
    await _completeConnection(address, grant);
  }

  Future<void> _completeConnection(
    LanPairingAddress address,
    Map<String, Object?> reply,
  ) async {
    Map<String, Object?>? grant;
    if (!_reconnect) {
      if (_host) {
        grant = await _service.finishHost(_session!);
      } else {
        await _service.finishGuest(_session!, _map(reply['grant']));
      }
    }
    _requireOpen();
    final localPort = await _service.startServer();
    final saved = await _post('saved', {'grant': grant, 'port': localPort});
    final port = saved['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('对端监听端口无效');
    }
    connectedAddress = LanPeer(
      deviceId: _peer.deviceId,
      host: address.host,
      port: port,
      tlsFingerprint: _peer.tlsFingerprint,
    );
    await _service._rememberLanPeer(connectedAddress!);
    final acknowledged = await _post('ack');
    _requireOpen();
    if (acknowledged['ok'] != true) throw StateError('对端未确认保存');
    connectedPeer = _peer.deviceId;
    _expiry?.cancel();
    _client?.close();
    _client = null;
    _changed('已连接');
  }

  Future<void> _retire() async {
    _ticket?.cancel();
    link = null;
    final server = _server;
    _server = null;
    await server?.close();
  }

  Future<void> listen({InternetAddress? address}) =>
      _begin(() => _listen(address));

  Future<void> _listen(InternetAddress? address) async {
    _service._requirePrepared();
    _service._requireNormalMode();
    _closed = false;
    _stage = 0;
    connectedPeer = null;
    error = null;
    _authorized = false;
    _reconnect = false;
    _ticket = await PairingInvitation.create(
      keys: _service._local!.keys,
      vaultPublicId: _random().replaceAll('=', ''),
      tlsFingerprint: _service._tls!.fingerprint,
    );
    _requireOpen();
    _server = await LanPairingServer.listen(
      identity: _service._tls!,
      address: address,
      onMessage: _receive,
      onTimeout: () => unawaited(close()),
    );
    _requireOpen();
    final hosts = address != null && address != InternetAddress.anyIPv4
        ? [address]
        : (await NetworkInterface.list(type: InternetAddressType.IPv4))
              .expand((interface) => interface.addresses)
              .toList();
    addresses = hosts
        .take(8)
        .map(
          (host) => LanPairingAddress.parse(
            '${host.type == InternetAddressType.IPv6 ? '[${host.address}]' : host.address}:$port',
          ),
        )
        .toList();
    _requireOpen();
    if (addresses.isEmpty) {
      await _shutdown();
      throw StateError('未找到局域网地址');
    }
    link = LanPairingLink(addresses: addresses, invitation: _ticket!);
    _expiry = Timer(const Duration(minutes: 10), () => unawaited(close()));
    _changed('等待设备连接');
  }

  Future<void> allow(String code) => _track(() async {
    _requireOpen();
    if (_session == null || _authorized) throw StateError('没有待确认的连接');
    _confirmation = await _session!.confirmShortCode(code);
    _requireOpen();
    _authorized = true;
    _changed('正在建立连接');
  });

  Future<void> reject() => close();

  Future<void> close() {
    _generation++;
    return _drain();
  }

  Future<void> _shutdown() async {
    _closed = true;
    _expiry?.cancel();
    _client?.close();
    _client = null;
    await _server?.close();
    _server = null;
    _ticket?.cancel();
    _ticket = null;
    _session?.cancel();
    _session = null;
    _confirmation = null;
    _token = null;
    _shortCode = null;
    connectedPeer = null;
    connectedAddress = null;
    link = null;
    addresses = [];
    _changed('未连接');
  }
}
