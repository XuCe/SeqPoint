import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../crypto/crypto_primitives.dart';
import '../crypto/vault_key.dart';
import '../crypto/xchacha20_aead.dart';
import '../util/clock.dart';
import 'device_keys.dart';
import 'member_keys.dart';
import 'pairing_invitation.dart';
import 'pairing_response.dart';
import 'pairing_secrets.dart';
import 'pairing_transcript.dart';

enum PairingHandshakeState { awaitingConfirmation, ready, completed, cancelled, expired }

final class PairingHandshake {
  PairingHandshake._(this._invitation, this.response, this.localDeviceId, this._material, this._clock);
  final PairingInvitation _invitation;
  final PairingResponse response;
  final String localDeviceId;
  final Clock _clock;
  ({List<int> encryptionKey, List<int> confirmationKey, String shortCode})? _material;
  bool _expired = false;
  bool _completed = false;
  bool _ownConfirmed = false;
  bool _peerConfirmed = false;
  String? _confirmedCheckpointHash;
  int? _confirmedEpoch;
  String? _confirmedKeyCommitment;
  String? get confirmedCheckpointHash => _confirmedCheckpointHash;
  int? get confirmedEpoch => _confirmedEpoch;
  String? get confirmedKeyCommitment => _confirmedKeyCommitment;
  Future<void> _tail = Future<void>.value();
  PairingHandshakeState get state {
    if (_completed) return PairingHandshakeState.completed;
    if (_invitation.isCancelled) {
      _material = null; return PairingHandshakeState.cancelled;
    }
    if (!_expired) {
      final now = _clock.now().toUtc();
      _expired = !response.transcript.expiresAt.isAfter(now) ||
          response.transcript.expiresAt.difference(now) > PairingTranscript.maxLifetime;
      if (!_expired) {
        try { _invitation.checkActive(); } catch (_) { _expired = true; }
      }
    }
    if (_expired) {
      _material = null;
      return PairingHandshakeState.expired;
    }
    return _ownConfirmed && _peerConfirmed ? PairingHandshakeState.ready : PairingHandshakeState.awaitingConfirmation;
  }
  String get shortCode { _checkLive(); return _material!.shortCode; }
  void cancel() { _invitation.cancel(); _material = null; }
  void _checkLive() {
    final current = state;
    if (current != PairingHandshakeState.awaitingConfirmation && current != PairingHandshakeState.ready) {
      throw StateError('配对会话已失效');
    }
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) { _checkLive(); return action(); });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
  Future<Mac> _proofFor(String sender, List<int> key) => Hmac.sha256().calculateMac(
      utf8.encode(jsonEncode([CryptoSpec.infoSession, 'confirmation', response.transcript.toJson(), sender])),
      secretKey: SecretKey(key));

  void _requireReady(bool initiator) {
    final expected = initiator ? response.transcript.initiator.deviceId : response.transcript.responder.deviceId;
    if (state != PairingHandshakeState.ready || localDeviceId != expected) throw StateError('会话未确认或角色错误');
  }
  List<int> _epochAad(String checkpointHash) => utf8.encode(jsonEncode({
    'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'epoch-key', 'transcript': response.transcript.toJson(),
    'sender_id': response.transcript.initiator.deviceId, 'recipient_id': response.transcript.responder.deviceId,
    'checkpoint_hash': checkpointHash,
  }));
  Future<Map<String, Object?>> sealEpoch(VaultKey key, {required String checkpointHash}) async {
    _requireReady(true);
    parsePairingBytes(checkpointHash, 32);
    final epoch = key.epoch;
    if (epoch < 1 || key.keyBytes.length != 32 || key.keyBytes.any((b) => b < 0 || b > 255)) {
      throw ArgumentError('Epoch密钥格式错误');
    }
    final bytes = List<int>.unmodifiable(key.keyBytes);
    return _enqueue(() async {
      _requireReady(true);
      try {
        final payload = utf8.encode(jsonEncode({'v': 1, 'epoch': epoch, 'key': base64UrlEncode(bytes).replaceAll('=', '')}));
        final frame = await XChaCha20Aead().seal(payload, _material!.encryptionKey, aad: _epochAad(checkpointHash));
        final commitment = await epochKeyCommitment(vaultPublicId: response.transcript.vaultPublicId, keyBytes: bytes);
        _requireReady(true);
        if (frame.length > 256) throw StateError('Epoch封装过大');
        final result = Map<String, Object?>.unmodifiable({
          'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'epoch', 'session_id': response.transcript.sessionId,
          'sender_id': localDeviceId, 'recipient_id': response.transcript.responder.deviceId,
          'checkpoint_hash': checkpointHash,
          'ciphertext': base64UrlEncode(frame).replaceAll('=', ''),
        });
        _confirmedCheckpointHash = checkpointHash;
        _confirmedEpoch = epoch;
        _confirmedKeyCommitment = commitment;
        _completed = true; _material = null; _invitation.cancel(); return result;
      } catch (_) {
        if (state != PairingHandshakeState.expired) cancel();
        throw StateError('Epoch密钥封装失败');
      }
    });
  }

  Future<VaultKey> openEpoch(Map<String, Object?> json) async {
    _requireReady(false);
    late String sender, recipient, session, checkpointHash;
    late List<int> frame;
    try {
      const fields = {'purpose', 'v', 'type', 'session_id', 'sender_id', 'recipient_id', 'ciphertext', 'checkpoint_hash'};
      final s = json['session_id'], from = json['sender_id'], to = json['recipient_id'], text = json['ciphertext'];
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k)) ||
          json['purpose'] != CryptoSpec.infoSession || json['v'] is! int || json['v'] != 1 ||
          json['type'] != 'epoch' || s is! String || s.length > 128 ||
          from is! String || from.length != 43 || to is! String || to.length != 43 ||
          text is! String || text.length < 54 || text.length > 342) {
        throw const FormatException();
      }
      sender = from; recipient = to; session = s;
      parsePairingBytes(json['checkpoint_hash'], 32);
      checkpointHash = json['checkpoint_hash'] as String;
      final decoded = base64Url.decode(base64Url.normalize(text));
      if (decoded.length < CryptoSpec.nonceBytes + CryptoSpec.macBytes || decoded.length > 256 ||
          base64UrlEncode(decoded).replaceAll('=', '') != text) {
        throw const FormatException();
      }
      frame = List<int>.unmodifiable(decoded);
    } catch (_) {
      if (state != PairingHandshakeState.expired) cancel();
      throw const FormatException('Epoch封装消息格式错误');
    }
    if (session != response.transcript.sessionId || sender != response.transcript.initiator.deviceId ||
        recipient != localDeviceId) {
      cancel(); throw StateError('Epoch封装来自错误的设备或会话');
    }
    return _enqueue(() => _decryptEpoch(frame, checkpointHash));
  }

  Future<VaultKey> _decryptEpoch(List<int> frame, String checkpointHash) async {
    _requireReady(false);
    try {
      final bytes = await XChaCha20Aead().open(frame, _material!.encryptionKey, aad: _epochAad(checkpointHash));
      _requireReady(false);
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map || json.length != 3 || json.keys.any((k) => !{'v', 'epoch', 'key'}.contains(k)) ||
          json['v'] is! int || json['v'] != 1 || json['epoch'] is! int || (json['epoch'] as int) < 1) {
        throw const FormatException();
      }
      final key = VaultKey(epoch: json['epoch'] as int,
          keyBytes: List<int>.unmodifiable(parsePairingBytes(json['key'], 32)));
      final commitment = await epochKeyCommitment(
          vaultPublicId: response.transcript.vaultPublicId, keyBytes: key.keyBytes);
      _requireReady(false);
      _confirmedCheckpointHash = checkpointHash;
      _confirmedEpoch = key.epoch;
      _confirmedKeyCommitment = commitment;
      _completed = true; _material = null; _invitation.cancel();
      return key;
    } catch (_) {
      if (state != PairingHandshakeState.expired) cancel();
      throw StateError('Epoch密钥认证或会话状态校验失败');
    }
  }

  Future<Map<String, Object?>> confirmShortCode(String code) => _enqueue(() async {
    if (_ownConfirmed) throw StateError('本机短码已经确认');
    if (code.trim().toUpperCase() != _material!.shortCode) {
      cancel(); throw StateError('配对短码不匹配');
    }
    final mac = await _proofFor(localDeviceId, _material!.confirmationKey);
    _checkLive(); _ownConfirmed = true;
    return Map<String, Object?>.unmodifiable({
      'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'confirmation',
      'session_id': response.transcript.sessionId, 'sender_id': localDeviceId,
      'mac': base64UrlEncode(mac.bytes).replaceAll('=', ''),
    });
  });

  Future<void> acceptConfirmation(Map<String, Object?> json) async {
    late String sender, session;
    late List<int> proof;
    try {
      const fields = {'purpose', 'v', 'type', 'session_id', 'sender_id', 'mac'};
      final sessionValue = json['session_id'], senderValue = json['sender_id'];
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k)) ||
          json['purpose'] != CryptoSpec.infoSession || json['v'] is! int || json['v'] != 1 ||
          json['type'] != 'confirmation' || sessionValue is! String || sessionValue.length > 128 ||
          senderValue is! String || senderValue.length != 43) {
        throw const FormatException();
      }
      sender = senderValue; session = sessionValue;
      proof = List<int>.unmodifiable(parsePairingBytes(json['mac'], 32));
    } catch (_) { cancel(); throw const FormatException('配对确认格式错误'); }
    final peer = localDeviceId == response.transcript.initiator.deviceId
        ? response.transcript.responder.deviceId : response.transcript.initiator.deviceId;
    if (sender != peer || session != response.transcript.sessionId) {
      cancel(); throw StateError('确认来自错误的设备或会话');
    }
    await _enqueue(() async {
      if (_peerConfirmed) throw StateError('对端确认已使用');
      final expected = await _proofFor(peer, _material!.confirmationKey);
      _checkLive();
      if (expected != Mac(proof)) { cancel(); throw StateError('配对确认凭据无效'); }
      _peerConfirmed = true;
    });
  }

  static Future<PairingHandshake> respond({required PairingInvitation invitation,
    required DeviceKeys keys, required String tlsFingerprint, Clock clock = const SystemClock(),
  }) async {
    try {
      final response = await PairingResponse.create(invitation: invitation, keys: keys,
          tlsFingerprint: tlsFingerprint, clock: clock);
      final material = await derivePairingSecrets(localKeys: keys, transcript: response.transcript,
          pairingSecret: invitation.pairingSecret, clock: clock);
      invitation.checkActive();
      return PairingHandshake._(invitation, response, keys.deviceId, material, clock);
    } catch (_) { invitation.cancel(); rethrow; }
  }

  static Future<PairingHandshake> acceptResponse({required PairingInvitation invitation,
    required DeviceKeys keys, required Map<String, Object?> response, Clock clock = const SystemClock(),
  }) async {
    if (keys.deviceId != invitation.initiator.deviceId) throw StateError('本机不是邀请发起方');
    invitation.claim(asInitiator: true);
    try {
      final signed = await PairingResponse.fromJson(response, invitation: invitation, clock: clock);
      final material = await derivePairingSecrets(localKeys: keys, transcript: signed.transcript,
          pairingSecret: invitation.pairingSecret, clock: clock);
      invitation.checkActive();
      return PairingHandshake._(invitation, signed, keys.deviceId, material, clock);
    } catch (_) { invitation.cancel(); rethrow; }
  }
}
