import 'dart:convert';
import 'dart:math';
import '../crypto/crypto_primitives.dart';
import '../util/clock.dart';
import 'device_keys.dart';
import 'pairing_invitation.dart';
import 'pairing_transcript.dart';

class PairingResponse {
  PairingResponse._(this.transcript);
  final PairingTranscript transcript;
  late final List<int> _signature;
  Map<String, Object?> _body() => {
    'purpose': CryptoSpec.infoSession, 'v': 1, 'type': 'response', 'transcript': transcript.toJson(),
  };
  Map<String, Object?> toJson() => {..._body(), 'signature': base64UrlEncode(_signature).replaceAll('=', '')};

  static Future<PairingResponse> create({required PairingInvitation invitation,
    required DeviceKeys keys, required String tlsFingerprint, Clock clock = const SystemClock(),
  }) async {
    invitation.claim(asInitiator: false);
    try {
      final random = Random.secure();
      final result = PairingResponse._(PairingTranscript(vaultPublicId: invitation.vaultPublicId,
          sessionId: invitation.sessionId, initiator: invitation.initiator, expiresAt: invitation.expiresAt,
          responder: PairingParticipant(deviceId: keys.deviceId, signingPublicKey: keys.signer.publicKey,
            exchangePublicKey: keys.exchangePublicKey, nonce: List.generate(32, (_) => random.nextInt(256)),
            tlsFingerprint: tlsFingerprint)));
      result._signature = List<int>.unmodifiable(await keys.signer.sign(utf8.encode(jsonEncode(result._body()))));
      await result._verify(invitation, clock);
      return result;
    } catch (_) { invitation.cancel(); rethrow; }
  }

  Future<void> _verify(PairingInvitation invitation, Clock clock) async {
    invitation.checkActive();
    if (transcript.vaultPublicId != invitation.vaultPublicId || transcript.sessionId != invitation.sessionId ||
        transcript.expiresAt != invitation.expiresAt ||
        jsonEncode(transcript.initiator.toJson()) != jsonEncode(invitation.initiator.toJson())) {
      throw StateError('应答与原邀请不一致');
    }
    await transcript.verify(clock: clock);
    await transcript.responder.verifySignature(utf8.encode(jsonEncode(_body())), _signature);
    await transcript.verify(clock: clock);
    invitation.checkActive();
  }

  static Future<PairingResponse> fromJson(Map<String, Object?> json,
      {required PairingInvitation invitation, Clock clock = const SystemClock()}) async {
    late PairingResponse result;
    try {
      const fields = {'purpose', 'v', 'type', 'transcript', 'signature'};
      if (json.length != fields.length || json.keys.any((k) => !fields.contains(k)) ||
          json['purpose'] != CryptoSpec.infoSession || json['v'] is! int ||
          json['v'] != 1 || json['type'] != 'response') {
        throw const FormatException();
      }
      result = PairingResponse._(PairingTranscript.fromJson((json['transcript'] as Map).cast<String, Object?>()));
      result._signature = List<int>.unmodifiable(parsePairingBytes(json['signature'], 64));
    } catch (_) { throw const FormatException('配对应答格式错误'); }
    await result._verify(invitation, clock);
    return result;
  }
}
