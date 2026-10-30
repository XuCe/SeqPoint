import 'dart:convert';
import 'dart:math';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class LocalDeviceIdentity {
  const LocalDeviceIdentity(this.identity, this.keys, {this.isRecoveryIdentity = false});
  final DeviceIdentity identity;
  final DeviceKeys keys;
  final bool isRecoveryIdentity;
}

/// 只由主引擎创建；双私钥与身份元数据作为一条系统安全记录保存。
class SyncIdentityStore {
  SyncIdentityStore(this._secrets, {Clock clock = const SystemClock()})
      : _clock = clock;
  static const storageKey = 'seqpoint.sync.identity.v1';
  static const maxIdentities = 64, maxRecordChars = 64 * 1024;
  final SecretStore _secrets;
  final Clock _clock;
  Future<LocalDeviceIdentity>? _loading;

  Future<List<LocalDeviceIdentity>> _identities(String record) async {
    if (record.length > maxRecordChars) throw const FormatException('身份历史已达容量上限');
    final json = jsonDecode(record);
    if (json is! Map<String, dynamic> || json['v'] is! int) throw const FormatException();
    final records = json['v'] == 1 ? [json] : json['identities'];
    if (json['v'] != 1 && (json['v'] != 2 || json.length != 2)) throw const FormatException();
    if (records is! List || records.isEmpty || records.length > maxIdentities) throw const FormatException();
    final result = <LocalDeviceIdentity>[], ids = <String>{};
    for (final value in records) {
      if (value is! Map<String, dynamic>) throw const FormatException();
      final identity = await _decodeSingle(value);
      if (!ids.add(identity.keys.deviceId)) throw const FormatException('重复设备身份');
      result.add(LocalDeviceIdentity(identity.identity, identity.keys,
          isRecoveryIdentity: result.isNotEmpty));
    }
    return result;
  }

  Future<LocalDeviceIdentity> _decode(String record) async => (await _identities(record)).last;

  Future<LocalDeviceIdentity> loadForDevice(String deviceId) async {
    try {
      final record = await _secrets.read(storageKey);
      if (record == null) throw StateError('缺少设备安全身份');
      return (await _identities(record)).firstWhere((entry) => entry.keys.deviceId == deviceId);
    } catch (_) { throw StateError('指定设备身份不可用，同步保持关闭'); }
  }

  Future<LocalDeviceIdentity> createRecoveryIdentity(String name) async {
    try {
      final previous = await _secrets.read(storageKey);
      if (previous == null) throw StateError('请先准备原身份');
      final known = await _identities(previous);
      if (known.length >= maxIdentities) throw StateError('身份历史已达容量上限');
      final random = Random.secure();
      final fresh = {'v': 1, 'name': name, 'added_at': _clock.now().toUtc().toIso8601String(),
        'signing_seed': base64Encode(List.generate(32, (_) => random.nextInt(256))),
        'exchange_seed': base64Encode(List.generate(32, (_) => random.nextInt(256)))};
      final old = jsonDecode(previous) as Map;
      final record = jsonEncode({'v': 2,
        'identities': [...(old['v'] == 1 ? [old] : old['identities'] as List), fresh]});
      final result = await _decode(record);
      await _secrets.write(storageKey, record);
      if (await _secrets.read(storageKey) != record) throw StateError('身份保存失败');
      _loading = Future.value(result);
      return result;
    } catch (_) { throw StateError('新身份保存失败，同步保持关闭'); }
  }

  Future<LocalDeviceIdentity> loadOrCreate(String name) async {
    final pending = _loading ??= _load(name);
    try {
      return await pending;
    } catch (_) {
      if (identical(_loading, pending)) _loading = null;
      throw StateError('设备身份加载失败，请检查系统安全存储');
    }
  }

  Future<LocalDeviceIdentity> _load(String name) async {
    final existing = await _secrets.read(storageKey);
    if (existing != null) return _decode(existing);
    final random = Random.secure();
    final record = jsonEncode({
      'v': 1, 'name': name, 'added_at': _clock.now().toUtc().toIso8601String(),
      'signing_seed': base64Encode(List.generate(32, (_) => random.nextInt(256))),
      'exchange_seed': base64Encode(List.generate(32, (_) => random.nextInt(256))),
    });
    final identity = await _decode(record);
    await _secrets.write(storageKey, record);
    if (await _secrets.read(storageKey) != record) throw StateError('身份保存失败');
    return identity;
  }

  Future<LocalDeviceIdentity> _decodeSingle(Map<String, dynamic> data) async {
    if (data['v'] is! int || data['v'] != 1 || data.length != 5 ||
        data['name'] is! String || data['added_at'] is! String ||
        data['signing_seed'] is! String || data['exchange_seed'] is! String) {
      throw const FormatException('身份记录格式错误');
    }
    final name = data['name'] as String;
    if (name.trim().isEmpty || name.length > 80 || name.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('设备名称格式错误');
    }
    final addedAt = DateTime.parse(data['added_at'] as String);
    if (!addedAt.isUtc) throw const FormatException('身份时间格式错误');
    final keys = await DeviceKeys.fromSeeds(
        base64Decode(data['signing_seed'] as String),
        base64Decode(data['exchange_seed'] as String));
    return LocalDeviceIdentity(DeviceIdentity(
      deviceId: keys.deviceId,
      name: name,
      signingPublicKey: base64Encode(keys.signer.publicKey),
      exchangePublicKey: base64Encode(keys.exchangePublicKey),
      isSelf: true,
      addedAt: addedAt,
    ), keys);
  }
}
