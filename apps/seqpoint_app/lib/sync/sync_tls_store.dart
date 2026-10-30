import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

/// 主引擎专用；证书和私钥只以一条系统安全记录持久化。
class SyncTlsStore {
  SyncTlsStore(this._secrets, {Clock clock = const SystemClock()}) : _clock = clock;
  static const storageKey = 'seqpoint.sync.tls.v1';
  static final _inFlight = Expando<Future<LanTlsIdentity>>();
  final SecretStore _secrets;
  final Clock _clock;
  Future<LanTlsIdentity>? _loading;

  Future<LanTlsIdentity> loadOrCreate() async {
    final pending = _loading ??= _inFlight[_secrets] ??= _load();
    try {
      final identity = await pending;
      final now = _clock.now().toUtc();
      if (identity.notBefore.isAfter(now) || !identity.notAfter.isAfter(now)) {
        throw StateError('TLS 证书不在有效期内');
      }
      return identity;
    } catch (_) {
      if (identical(_loading, pending)) _loading = null;
      throw StateError('本机 TLS 身份加载失败，请检查系统安全存储');
    } finally {
      if (identical(_inFlight[_secrets], pending)) _inFlight[_secrets] = null;
    }
  }

  Future<LanTlsIdentity> _load() async {
    final existing = await _secrets.read(storageKey);
    if (existing != null) return _decode(existing);
    final identity = await LanTlsIdentity.generate(now: _clock.now());
    final record = jsonEncode({
      'v': 1, 'certificate_pem': identity.certificatePem,
      'private_key_pem': identity.privateKeyPem, 'fingerprint': identity.fingerprint,
    });
    await _secrets.write(storageKey, record);
    if (await _secrets.read(storageKey) != record) throw StateError('TLS 保存失败');
    return identity;
  }

  Future<LanTlsIdentity> _decode(String record) async {
    if (record.length > 32768) throw const FormatException('TLS 记录过长');
    final data = jsonDecode(record);
    if (data is! Map<String, dynamic> || data.length != 4 ||
        data['v'] is! int || data['v'] != 1 ||
        data['certificate_pem'] is! String || data['private_key_pem'] is! String ||
        data['fingerprint'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(data['fingerprint'] as String)) {
      throw const FormatException('TLS 记录格式错误');
    }
    final identity = await LanTlsIdentity.fromPem(
      certificatePem: data['certificate_pem'] as String,
      privateKeyPem: data['private_key_pem'] as String,
      now: _clock.now(),
    );
    if (identity.fingerprint != data['fingerprint']) {
      throw const FormatException('TLS 指纹不匹配');
    }
    return identity;
  }
}
