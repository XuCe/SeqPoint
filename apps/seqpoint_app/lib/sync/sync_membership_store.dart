import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

final class SavedMembership {
  SavedMembership(this.membership, this.epochKey, this.localDeviceId,
      {Map<int, List<int>> epochKeys = const {}})
      : epochKeys = Map.unmodifiable({
          for (final entry in epochKeys.entries)
            entry.key: List<int>.unmodifiable(entry.value),
          if (epochKey != null) epochKey.epoch: List<int>.unmodifiable(epochKey.keyBytes),
        });
  final MembershipReducer membership;
  final VaultKey? epochKey;
  final String localDeviceId;
  final Map<int, List<int>> epochKeys;
  MembershipState get state => membership.state;
  bool get isUsable => epochKey != null && state.epoch == epochKey!.epoch &&
      membership.isMemberAuthorized(localDeviceId);
}

/// 主引擎独占；可信名单与密钥存为一条系统安全记录，不能从同步文件加载。
class SyncMembershipStore {
  SyncMembershipStore(this._secrets, {String? deviceId})
      : _storageKey = deviceId == null ? storageKey : storageKeyForDevice(deviceId);
  static const storageKey = 'seqpoint.sync.membership.v1';
  static String storageKeyForDevice(String deviceId) {
    if (RegExp(r'^[A-Za-z0-9_-]{43}$').firstMatch(deviceId)?.end != deviceId.length) throw ArgumentError('设备身份无效');
    return '$storageKey.$deviceId';
  }
  static const maxRecordChars = 1024 * 1024;
  final SecretStore _secrets;
  final String _storageKey;
  Future<void> _tail = Future<void>.value();

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<SavedMembership?> load(DeviceKeys localDevice) => _enqueue(() async {
    try { return await _load(localDevice); }
    catch (_) { throw StateError('成员安全记录加载失败，同步保持关闭'); }
  });

  VaultKey _decodeKey(int epoch, Object? value) {
    if (epoch < 1 || value is! String || value.length != 43) throw const FormatException();
    final bytes = base64Url.decode(base64Url.normalize(value));
    if (bytes.length != 32 || base64UrlEncode(bytes).replaceAll('=', '') != value) {
      throw const FormatException();
    }
    return VaultKey(epoch: epoch, keyBytes: List<int>.unmodifiable(bytes));
  }

  Future<void> _validateHistory(MembershipReducer membership,
      Map<int, List<int>> keys) async {
    final commitments = <int, Set<String>>{};
    void collect(Map control) {
      void add(Map entry) => commitments.putIfAbsent(entry['epoch'] as int, () => {})
          .add(entry['key_commitment'] as String);
      add(control['anchor'] as Map);
      for (final event in control['facts'] as List) { add(event as Map); }
      for (final isolated in control['isolated'] as List) { collect(isolated as Map); }
    }
    collect(membership.toTrustedLocalJson());
    for (final entry in keys.entries) {
      final commitment = await epochKeyCommitment(
          vaultPublicId: membership.state.vaultPublicId, keyBytes: entry.value);
      if (commitments[entry.key]?.contains(commitment) != true) {
        throw StateError('历史Epoch密钥缺少已验证承诺');
      }
    }
  }

  Future<Map<int, List<int>>> _loadKeys(Map<String, dynamic> data,
      MembershipReducer membership, VaultKey? key) async {
    final keys = <int, List<int>>{};
    if (data['v'] == 1) {
      if (key != null) keys[key.epoch] = key.keyBytes;
    } else {
      final source = data['epoch_keys'];
      if (source is! Map<String, dynamic>) throw const FormatException();
      for (final entry in source.entries) {
        final epoch = int.tryParse(entry.key);
        if (epoch == null || epoch < 1 || epoch.toString() != entry.key) throw const FormatException();
        keys[epoch] = _decodeKey(epoch, entry.value).keyBytes;
      }
      if (key != null && source[key.epoch.toString()] != data['key']) throw const FormatException();
    }
    await _validateHistory(membership, keys);
    return keys;
  }

  Future<Map<int, List<int>>> _retainedKeys(MembershipReducer membership,
      SavedMembership? previous, VaultKey? key) async {
    if (previous != null && previous.state.vaultPublicId != membership.state.vaultPublicId) {
      throw StateError('历史密钥Vault不匹配');
    }
    final keys = <int, List<int>>{...?previous?.epochKeys,
      if (key != null) key.epoch: key.keyBytes};
    await _validateHistory(membership, keys);
    return keys;
  }

  String _record(MembershipReducer membership, DeviceKeys local,
      VaultKey? key, Map<int, List<int>> keys) => jsonEncode({
    'v': 2, 'local_id': local.deviceId, 'control': membership.toTrustedLocalJson(),
    'epoch': key?.epoch, 'key': key == null ? null : base64UrlEncode(key.keyBytes).replaceAll('=', ''),
    'epoch_keys': {for (final entry in keys.entries)
      entry.key.toString(): base64UrlEncode(entry.value).replaceAll('=', '')},
  });

  Future<SavedMembership?> _load(DeviceKeys localDevice) async {
    final raw = await _secrets.read(_storageKey);
    if (raw == null) return null;
    if (raw.length > maxRecordChars) throw const FormatException();
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> || data['v'] is! int || !{1, 2}.contains(data['v'])) {
      throw const FormatException();
    }
    final fields = {'v', 'local_id', 'control', 'epoch', 'key', if (data['v'] == 2) 'epoch_keys'};
    if (data.length != fields.length || !data.keys.toSet().containsAll(fields) ||
        data['local_id'] != localDevice.deviceId ||
        data['control'] is! Map<String, dynamic> ||
        (data['epoch'] != null && (data['epoch'] is! int || (data['epoch'] as int) < 1))) {
      throw const FormatException();
    }
    final membership = await MembershipReducer.restoreTrustedLocal(
        Map<String, Object?>.from(data['control'] as Map));
    if ((data['epoch'] == null) != (data['key'] == null)) throw const FormatException();
    final key = data['epoch'] == null ? null : _decodeKey(data['epoch'] as int, data['key']);
    await _validate(membership, localDevice, key);
    return SavedMembership(membership, key, localDevice.deviceId,
        epochKeys: await _loadKeys(data, membership, key));
  }

  Future<void> _validate(MembershipReducer membership, DeviceKeys local, VaultKey? key) async {
    final member = membership.knownMemberKeys(local.deviceId), state = membership.state;
    if (member == null ||
        base64UrlEncode(member.signingPublicKey) != base64UrlEncode(local.signer.publicKey) ||
        base64UrlEncode(member.exchangePublicKey) != base64UrlEncode(local.exchangePublicKey)) {
      throw StateError('成员身份或Epoch不匹配');
    }
    if (key != null && (membership.isConflicted || !membership.isMemberAuthorized(local.deviceId) ||
        state.epoch != key.epoch || await epochKeyCommitment(
            vaultPublicId: state.vaultPublicId, keyBytes: key.keyBytes) != state.keyCommitment)) {
      throw StateError('成员身份或Epoch不匹配');
    }
  }

  Future<SavedMembership> save({required MembershipReducer membership,
      required DeviceKeys localDevice, VaultKey? epochKey}) {
    final control = membership.toTrustedLocalJson();
    final supplied = epochKey == null ? null : VaultKey(
        epoch: epochKey.epoch, keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _enqueue(() async {
      try {
        final snapshot = await MembershipReducer.restoreTrustedLocal(control);
        final key = snapshot.isConflicted || !snapshot.isMemberAuthorized(localDevice.deviceId)
            ? null : supplied;
        await _validate(snapshot, localDevice, key);
        final previous = await _load(localDevice);
        if (previous != null) {
          final old = previous.membership.toTrustedLocalJson();
          final fresh = snapshot.toTrustedLocalJson();
          final knownFacts = (fresh['facts'] as List).map(jsonEncode).toSet();
          final isolated = (fresh['isolated'] as List).map(jsonEncode).toSet();
          if (old['anchor_hash'] != fresh['anchor_hash'] ||
              (previous.membership.isConflicted && !snapshot.isConflicted) ||
              !(old['facts'] as List).every((fact) => knownFacts.contains(jsonEncode(fact))) ||
              !(old['isolated'] as List).every((record) => isolated.contains(jsonEncode(record)))) {
            throw StateError('拒绝过期或跨授权域覆盖');
          }
        }
        final keys = await _retainedKeys(snapshot, previous, key);
        final record = _record(snapshot, localDevice, key, keys);
        if (record.length > maxRecordChars) throw StateError('安全记录已达容量上限');
        await _secrets.write(_storageKey, record);
        if (await _secrets.read(_storageKey) != record) throw StateError('安全记录回读不一致');
        return SavedMembership(snapshot, key, localDevice.deviceId, epochKeys: keys);
      } catch (_) { throw StateError('成员与Epoch保存失败，同步保持关闭'); }
    });
  }

  /// 用户完成新配对后显式恢复冲突；普通save不能更换可信锚或清除证据。
  Future<SavedMembership> recoverFromPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint, required DeviceKeys localDevice,
      required VaultKey epochKey}) => _recover(session, checkpoint, localDevice, epochKey, false);

  Future<SavedMembership> recoverFromHostedPairing({required PairingHandshake session,
      required Map<String, Object?> checkpoint, required DeviceKeys localDevice,
      required VaultKey epochKey}) => _recover(session, checkpoint, localDevice, epochKey, true);

  Future<SavedMembership> _recover(PairingHandshake session, Map<String, Object?> checkpoint,
      DeviceKeys localDevice, VaultKey epochKey, bool hosted) {
    final frozen = Map<String, Object?>.from(jsonDecode(jsonEncode(checkpoint)) as Map);
    final key = VaultKey(epoch: epochKey.epoch, keyBytes: List<int>.unmodifiable(epochKey.keyBytes));
    return _enqueue(() async {
      try {
        if (session.localDeviceId != localDevice.deviceId) throw StateError('配对身份不匹配');
        final previous = await _load(localDevice);
        if (previous == null) throw StateError('缺少待恢复的控制状态');
        final recovered = hosted
            ? await MembershipReducer.recoverFromHostedPairing(
                previous: previous.membership, session: session, checkpoint: frozen)
            : await MembershipReducer.recoverFromConfirmedPairing(
                previous: previous.membership, session: session, checkpoint: frozen);
        await _validate(recovered, localDevice, key);
        final keys = await _retainedKeys(recovered, previous, key);
        final record = _record(recovered, localDevice, key, keys);
        if (record.length > maxRecordChars) throw StateError('安全记录已达容量上限');
        await _secrets.write(_storageKey, record);
        if (await _secrets.read(_storageKey) != record) throw StateError('安全记录回读不一致');
        return SavedMembership(recovered, key, localDevice.deviceId, epochKeys: keys);
      } catch (_) { throw StateError('成员恢复保存失败，同步保持关闭'); }
    });
  }
}
