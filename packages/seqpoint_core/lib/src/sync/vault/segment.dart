import 'dart:convert';

import '../../crypto/crypto_primitives.dart';
import '../operation.dart';

/// 一个操作段：本设备写入的一批操作。
///
/// 段头是明文的（设备 id、epoch、序号、条数），对端不解密也能判断"我缺哪些段"；
/// 段体是密文。单写者原则保证只有 [deviceId] 那台设备会写它。
class Segment {
  const Segment({
    required this.deviceId,
    required this.keyEpoch,
    required this.seq,
    required this.opCount,
    required this.createdAt,
    required this.payload,
    this.sealed = false,
    this.signature = const [],
  });

  final String deviceId;
  final int keyEpoch;
  final int seq;
  final int opCount;
  final DateTime createdAt;
  final bool sealed;

  /// 段体。加密后为密文；未接加密时是明文 JSON 的 UTF-8 字节。
  final List<int> payload;

  /// 设备签名，覆盖规范化段头与密文。
  final List<int> signature;

  /// 满段或显式跨月封口后，写入方必须另起新段。
  bool get isSealed => sealed || opCount >= maxOpsPerSegment;

  static const maxOpsPerSegment = 500;

  /// 规范化认证头；Vault上下文阻止相同密钥下的跨Vault重放。
  List<int> authenticatedHeader(String vaultPublicId) => utf8.encode(jsonEncode({
    'purpose': CryptoSpec.infoSegment,
    'v': 1,
    'vault_id': vaultPublicId,
    'device_id': deviceId,
    'key_epoch': keyEpoch,
    'seq': seq,
    'op_count': opCount,
    'created_at': createdAt.toUtc().toIso8601String(),
    'sealed': sealed,
  }));

  Segment withPayload(List<int> bytes, {List<int> signature = const []}) => Segment(
    deviceId: deviceId, keyEpoch: keyEpoch, seq: seq, opCount: opCount,
    createdAt: createdAt, sealed: sealed, payload: bytes, signature: signature,
  );

  /// 段文件格式：一行明文 JSON 段头 + 换行 + base64 段体。
  ///
  /// 选这个格式是为了让对端只读第一行就能取到段头，不必载入整个段体。
  List<int> encode() {
    final header = jsonEncode({
      'v': 1,
      'device_id': deviceId,
      'key_epoch': keyEpoch,
      'seq': seq,
      'op_count': opCount,
      'created_at': createdAt.toIso8601String(),
      'sealed': sealed,
      'signature': base64Encode(signature),
    });
    return utf8.encode('$header\n${base64Encode(payload)}');
  }

  static Segment decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    final split = text.indexOf('\n');
    if (split < 0) throw const FormatException('段文件缺少段头');
    final header = _parseHeader(text.substring(0, split));
    return Segment(
      deviceId: header['device_id'] as String,
      keyEpoch: header['key_epoch'] as int,
      seq: header['seq'] as int,
      opCount: header['op_count'] as int,
      createdAt: DateTime.parse(header['created_at'] as String),
      sealed: header['sealed'] as bool,
      payload: base64Decode(text.substring(split + 1)),
      signature: base64Decode((header['signature'] as String?) ?? ''),
    );
  }

  /// 只解析段头，不解码段体。用于扫描远端目录时快速判断缺口。
  static Segment decodeHeader(String firstLine) {
    final header = _parseHeader(firstLine);
    return Segment(
      deviceId: header['device_id'] as String,
      keyEpoch: header['key_epoch'] as int,
      seq: header['seq'] as int,
      opCount: header['op_count'] as int,
      createdAt: DateTime.parse(header['created_at'] as String),
      sealed: header['sealed'] as bool,
      payload: const [],
      signature: const [],
    );
  }

  static Map<String, Object?> _parseHeader(String text) {
    final header = jsonDecode(text) as Map<String, Object?>;
    if (header.length != 8 || header['v'] != 1 || header['sealed'] is! bool ||
        header['device_id'] is! String || header['key_epoch'] is! int ||
        header['seq'] is! int || header['op_count'] is! int ||
        header['created_at'] is! String || header['signature'] is! String) {
      throw const FormatException('段头格式错误');
    }
    return header;
  }
}

/// 段体的编解码：明文操作 ⇄ 字节。
///
/// 加密与验签在实现类里完成，上层只见明文 [Operation]。
abstract interface class SegmentCodec {
  Future<Segment> encode(Segment header, List<Operation> ops);

  /// 验签失败或解密失败必须抛异常，绝不静默接受。
  Future<List<Operation>> decode(Segment segment);
}

/// 明文编解码。用于本地测试与尚未接入加密的阶段。
///
/// 正式同步必须换成加密实现——这个类不提供任何保密性。
class PlainSegmentCodec implements SegmentCodec {
  const PlainSegmentCodec();

  @override
  Future<Segment> encode(Segment header, List<Operation> ops) async =>
      header.withPayload(await encodePayload(ops));

  @override
  Future<List<Operation>> decode(Segment segment) => decodePayload(segment.payload);

  Future<List<int>> encodePayload(List<Operation> ops) async =>
      utf8.encode(jsonEncode(ops.map((o) => o.toJson()).toList()));

  Future<List<Operation>> decodePayload(List<int> payload) async {
    final decoded = jsonDecode(utf8.decode(payload)) as List;
    return decoded
        .map((e) => Operation.fromJson((e as Map).cast<String, Object?>()))
        .toList();
  }
}
