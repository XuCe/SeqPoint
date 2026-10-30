import 'dart:convert';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Segment header(DeviceKeys keys) => Segment(
  deviceId: keys.deviceId, keyEpoch: 1, seq: 1, opCount: 1,
  createdAt: DateTime.utc(2026, 10, 25), payload: const [],
);
Operation operation(DeviceKeys keys) => Operation(
  opId: 'op1', deviceId: keys.deviceId,
  hlc: Hlc(millis: 1, counter: 0, deviceId: keys.deviceId),
  objectType: 'note', objectId: 'n1', field: 'raw_content', value: '私密便签',
);

void main() {
  late DeviceKeys a, b;
  late EncryptedSegmentCodec sender, receiver;
  late Map<String, List<int>> members;
  final epochKey = List.filled(32, 7);
  setUp(() async {
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    members = {a.deviceId: a.signer.publicKey, b.deviceId: b.signer.publicKey};
    sender = EncryptedSegmentCodec(vaultPublicId: 'vault1', deviceKeys: a,
        epochKeys: {1: epochKey}, trustedSigners: members);
    receiver = EncryptedSegmentCodec(vaultPublicId: 'vault1', deviceKeys: b,
        epochKeys: {1: epochKey}, trustedSigners: members);
  });
  test('仅传密文，双端编码文件往返，签名固定64字节', () async {
    final sealed = await sender.encode(header(a), [operation(a)]);
    expect(sealed.signature, hasLength(64));
    expect(utf8.decode(sealed.encode()), isNot(contains('私密便签')));
    final opened = await receiver.decode(Segment.decode(sealed.encode()));
    expect(opened.single.toJson(), operation(a).toJson());
  });
  test('不同vault和未知成员均不可打开', () async {
    final sealed = await sender.encode(header(a), [operation(a)]);
    for (final codec in [
      EncryptedSegmentCodec(vaultPublicId: 'other', deviceKeys: b,
          epochKeys: {1: epochKey}, trustedSigners: members),
      EncryptedSegmentCodec(vaultPublicId: 'vault1', deviceKeys: b,
          epochKeys: {1: epochKey}, trustedSigners: {b.deviceId: b.signer.publicKey}),
    ]) {
      await expectLater(codec.decode(sealed), throwsStateError);
    }
  });
  test('全部段头字段、密文与签名篡改均拒绝', () async {
    final sealed = await sender.encode(header(a), [operation(a)]);
    final lines = utf8.decode(sealed.encode()).split('\n');
    final fields = jsonDecode(lines.first) as Map<String, dynamic>;
    for (final change in {
      'v': 2, 'device_id': b.deviceId, 'key_epoch': 2, 'sealed': true,
      'seq': 2, 'op_count': 2, 'created_at': '2026-10-26T00:00:00.000Z',
      'signature': base64Encode(List.filled(64, 0)),
    }.entries) {
      final encoded = utf8.encode('${jsonEncode({...fields, change.key: change.value})}\n${lines.last}');
      await expectLater(Future.sync(() => Segment.decode(encoded)).then(receiver.decode),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())));
    }
    final badPayload = List<int>.of(sealed.payload)..[24] ^= 1;
    await expectLater(receiver.decode(sealed.withPayload(badPayload,
        signature: sealed.signature)), throwsStateError);
    await expectLater(receiver.decode(sealed.withPayload(sealed.payload)),
        throwsStateError);
  });
  test('错误Epoch密钥与不可用Epoch拒绝，不能伪装其他作者', () async {
    final sealed = await sender.encode(header(a), [operation(a)]);
    for (final keys in <Map<int, List<int>>>[
      {1: List.filled(32, 9)}, {2: epochKey},
    ]) {
      final codec = EncryptedSegmentCodec(vaultPublicId: 'vault1', deviceKeys: b,
          epochKeys: keys, trustedSigners: members);
      await expectLater(codec.decode(sealed), throwsStateError);
    }
    await expectLater(sender.encode(header(b), [operation(b)]), throwsStateError);
    await expectLater(sender.encode(header(a), [operation(b)]), throwsStateError);
    await expectLater(sender.encode(header(a), []), throwsStateError);
  });
  test('合法签名也不能导入重复、非法时钟或超范围对象', () async {
    final original = operation(a).toJson();
    final invalid = <List<Map<String, Object?>>>[
      [original, original],
      [{...original, 'hlc': '-1:0:${a.deviceId}'}],
      [{...original, 'hlc': '1:-1:${a.deviceId}'}],
      [{...original, 'object_type': 'secret'}],
      [{...original, 'op_id': ''}],
      [{...original, 'object_id': ''}],
      [{...original, 'field': ''}],
      [{...original, 'extension': 'unknown'}],
    ];
    for (final ops in invalid) {
      final h = Segment(deviceId: a.deviceId, keyEpoch: 1, seq: 1,
          opCount: ops.length, createdAt: DateTime.utc(2026, 10, 25), payload: []);
      final aad = h.authenticatedHeader('vault1');
      final ciphertext = await XChaCha20Aead().seal(
          utf8.encode(jsonEncode(ops)), epochKey, aad: aad);
      final signature = await a.signer.sign([...aad, ...ciphertext]);
      await expectLater(receiver.decode(h.withPayload(ciphertext,
          signature: signature)), throwsStateError);
    }
  });
  test('过大段在加密前拒绝', () async {
    final op = Operation.fromJson({...operation(a).toJson(),
      'value': 'x' * EncryptedSegmentCodec.maxPlaintextBytes});
    await expectLater(sender.encode(header(a), [op]), throwsStateError);
  });
}
