import 'dart:convert';
import 'dart:math';
import '../crypto/crypto_primitives.dart';
import '../util/clock.dart';
import 'device_keys.dart';
import 'pairing_transcript.dart';

class PairingInvitation {
  PairingInvitation._(this.vaultPublicId, this.sessionId, this.initiator,
      this.expiresAt, List<int> secret, this.isLocalInvitation, this._clock)
      : _secret = List<int>.unmodifiable(secret) {
    if ([vaultPublicId, sessionId].any((id) =>
        RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(id)?.end != id.length) || !expiresAt.isUtc) {
      throw ArgumentError('配对邀请标识或期限格式错误');
    }
  }
  final String vaultPublicId, sessionId;
  final PairingParticipant initiator;
  final DateTime expiresAt;
  final List<int> _secret;
  late final List<int> _signature;
  final bool isLocalInvitation;
  final Clock _clock;
  bool _claimed = false, _cancelled = false, _expired = false;
  bool get isCancelled => _cancelled;
  List<int> get pairingSecret { checkActive(); return _secret; }

  static Future<PairingInvitation> create({required DeviceKeys keys, required String vaultPublicId,
    required String tlsFingerprint, Clock clock = const SystemClock(),
  }) async {
    final random = Random.secure();
    List<int> fresh() => List.generate(32, (_) => random.nextInt(256));
    final result = PairingInvitation._(vaultPublicId, base64UrlEncode(fresh()).replaceAll('=', ''),
        PairingParticipant(deviceId: keys.deviceId, signingPublicKey: keys.signer.publicKey,
          exchangePublicKey: keys.exchangePublicKey, nonce: fresh(), tlsFingerprint: tlsFingerprint),
        clock.now().toUtc().add(PairingTranscript.maxLifetime), fresh(), true, clock);
    result.checkActive();
    result._signature = List<int>.unmodifiable(await keys.signer.sign(utf8.encode(jsonEncode(result._body()))));
    result.checkActive(); return result;
  }
  Map<String, Object?> _body() => {
    'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'invitation',
    'vault_id': vaultPublicId, 'session_id': sessionId, 'expires_at': expiresAt.toIso8601String(),
    'initiator': initiator.toJson(), 'secret': base64UrlEncode(_secret).replaceAll('=', ''),
  };
  static Future<PairingInvitation> fromQr(Map<String, Object?> json,
      {Clock clock = const SystemClock()}) async {
    late PairingInvitation result;
    try {
      const fields = {'purpose', 'v', 'type', 'vault_id', 'session_id',
        'expires_at', 'initiator', 'secret', 'signature'};
      final date = json['expires_at'];
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k)) ||
          json['purpose'] != CryptoSpec.infoSession || json['v'] is! int || json['v'] != 1 ||
          json['type'] != 'invitation' || date is! String || date.length > 32) {
        throw const FormatException();
      }
      final expires = DateTime.parse(date);
      if (expires.toIso8601String() != date) throw const FormatException();
      result = PairingInvitation._(json['vault_id'] as String, json['session_id'] as String,
          PairingParticipant.fromJson((json['initiator'] as Map).cast<String, Object?>()),
          expires, parsePairingBytes(json['secret'], 32), false, clock);
      result._signature = List<int>.unmodifiable(parsePairingBytes(json['signature'], 64));
    } catch (_) { throw const FormatException('配对二维码格式错误'); }
    result.checkActive();
    await result.initiator.verifySignature(utf8.encode(jsonEncode(result._body())), result._signature);
    result.checkActive();
    return result;
  }
  Map<String, Object?> toQrPayload() {
    checkActive(); return {..._body(), 'signature': base64UrlEncode(_signature).replaceAll('=', '')};
  }
  void checkActive() {
    final now = _clock.now().toUtc();
    if (!expiresAt.isAfter(now) || expiresAt.difference(now) > PairingTranscript.maxLifetime) {
      _expired = true;
    }
    if (_cancelled || _expired) {
      throw StateError('配对邀请已取消或过期');
    }
  }
  void claim({required bool asInitiator}) {
    checkActive();
    if (_claimed || isLocalInvitation != asInitiator) throw StateError('邀请已使用或来源角色不符');
    _claimed = true;
  }
  void cancel() { _cancelled = true; }
}
