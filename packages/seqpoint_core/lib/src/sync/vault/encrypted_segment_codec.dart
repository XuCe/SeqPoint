import 'dart:convert';
import 'dart:isolate';
import '../sync_blob_codec.dart';
import '../../crypto/xchacha20_aead.dart';
import '../../identity/device_keys.dart';
import '../operation.dart';
import '../operation_validation.dart';
import 'segment.dart';

/// 仅信任调用方已验证的成员表；段文件不能自行提供可信公钥。
class EncryptedSegmentCodec implements SegmentCodec {
  EncryptedSegmentCodec({required this.vaultPublicId, required DeviceKeys deviceKeys,
    required Map<int, List<int>> epochKeys,
    required Map<String, List<int>> trustedSigners,
  }) : _deviceKeys = deviceKeys,
       _epochKeys = Map.unmodifiable(epochKeys.map((k, v) => MapEntry(k, List<int>.unmodifiable(v)))),
       _trustedSigners = Map.unmodifiable(trustedSigners.map((k, v) => MapEntry(k, List<int>.unmodifiable(v)))) {
    if (vaultPublicId.isEmpty || vaultPublicId.length > 128 ||
        _epochKeys.entries.any((e) => e.key < 1 || e.value.length != 32 ||
            e.value.any((b) => b < 0 || b > 255))) {
      throw ArgumentError('同步加密配置格式错误');
    }
  }

  final String vaultPublicId;
  final DeviceKeys _deviceKeys;
  final Map<int, List<int>> _epochKeys;
  final Map<String, List<int>> _trustedSigners;
  final _aead = XChaCha20Aead();
  static const maxPlaintextBytes = 8 * 1024 * 1024;

  @override
  Future<Segment> encode(Segment header, List<Operation> ops) async {
    _checkOperations(header, ops);
    final key = _epochKeys[header.keyEpoch];
    if (key == null || header.deviceId != _deviceKeys.deviceId ||
        !_trustedSigners.containsKey(header.deviceId)) {
      throw StateError('同步段作者或密钥无效');
    }
    final plaintext = utf8.encode(jsonEncode(ops.map((o) => o.toJson()).toList()));
    if (plaintext.length > maxPlaintextBytes) throw StateError('同步段过大');
    final aad = header.authenticatedHeader(vaultPublicId);
    final packed=await Isolate.run(()=>compressSyncPayload(plaintext));
    final payload = await _aead.seal(packed, key, aad: aad);
    final signature = await _deviceKeys.signer.sign([...aad, ...payload]);
    return header.withPayload(payload, signature: signature);
  }

  @override
  Future<List<Operation>> decode(Segment segment) async {
    try {
      final key = _epochKeys[segment.keyEpoch];
      final publicKey = _trustedSigners[segment.deviceId];
      if (key == null || publicKey == null || segment.signature.length != 64 ||
          segment.payload.length > maxPlaintextBytes + 40) {
        throw StateError('同步段身份、密钥或大小无效');
      }
      final aad = segment.authenticatedHeader(vaultPublicId);
      if (!await _deviceKeys.signer.verify([...aad, ...segment.payload],
          segment.signature, publicKey)) {
        throw StateError('签名无效');
      }
      final packed = await _aead.open(segment.payload, key, aad: aad);
      final plaintext=await Isolate.run(()=>expandSyncPayload(packed,maxPlaintextBytes));
      final decoded = jsonDecode(utf8.decode(plaintext)) as List;
      const fields = {'op_id', 'device_id', 'hlc', 'object_type',
        'object_id', 'field', 'value'};
      final ops = decoded.map((entry) {
        if (entry is! Map || entry.length != fields.length ||
            entry.keys.any((key) => !fields.contains(key))) {
          throw const FormatException('操作字段格式错误');
        }
        return Operation.fromJson(entry.cast<String, Object?>());
      }).toList();
      _checkOperations(segment, ops);
      return ops;
    } catch (_) {
      throw StateError('同步段认证或内容校验失败');
    }
  }

  void _checkOperations(Segment header, List<Operation> ops) {
    if (header.seq < 1 || header.keyEpoch < 1 || !header.createdAt.isUtc ||
        ops.isEmpty || ops.length > Segment.maxOpsPerSegment ||
        header.opCount != ops.length ||
        ops.any((op) => op.deviceId != header.deviceId ||
            op.hlc.deviceId != header.deviceId)) {
      throw StateError('同步段内容与作者不一致');
    }
    final ids = <String>{};
    for (final op in ops) {
      if (!ids.add(op.opId)) {
        throw StateError('同步操作格式错误');
      }
      try {
        validateIncomingOperation(op, expectedDeviceId: header.deviceId);
      } on FormatException {
        throw StateError('同步操作格式错误');
      }
    }
  }
}
