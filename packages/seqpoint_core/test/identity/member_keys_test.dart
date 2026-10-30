import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late DeviceKeys keys;
  MemberKeys material({String? id, String? tls}) => MemberKeys(deviceId: id ?? keys.deviceId,
      signingPublicKey: keys.signer.publicKey, exchangePublicKey: keys.exchangePublicKey,
      tlsFingerprint: tls ?? 'a' * 64);
  setUp(() async { keys = await DeviceKeys.fromSeeds(List.filled(32, 5), List.filled(32, 6)); });
  test('成员公开材料复制/不可变、身份与规范wire往返，不包含私钥或角色授权', () async {
    final signing = [...keys.signer.publicKey], exchange = [...keys.exchangePublicKey];
    final member = MemberKeys(deviceId: keys.deviceId, signingPublicKey: signing,
        exchangePublicKey: exchange, tlsFingerprint: 'a' * 64);
    final before = member.toJson(); signing[0] ^= 1; exchange[0] ^= 1;
    await member.verifyIdentity(); expect(member.toJson(), before);
    expect(before.keys, unorderedEquals(['device_id', 'signing_pub', 'exchange_pub', 'tls_sha256']));
    final input = member.toJson(), parsed = MemberKeys.fromJson(input); input['device_id'] = 'changed';
    expect(parsed.toJson(), member.toJson());
    expect(() => member.signingPublicKey.clear(), throwsUnsupportedError);
    expect(() => member.exchangePublicKey.clear(), throwsUnsupportedError);
  });
  test('用已核对的公开身份验签，错误身份/消息/签名不通过且不回显输入', () async {
    final member = material(), message = [1, 2, 3], proof = await keys.signer.sign([1, 2, 3]);
    final verifying = member.verifySignature(message, proof); message[0] = 9; proof[0] ^= 1;
    await verifying;
    await expectLater(member.verifySignature([9], await keys.signer.sign([1])), throwsStateError);
    await expectLater(member.verifySignature([1], []), throwsStateError);
    await expectLater(material(id: 'z' * 43).verifyIdentity(), throwsStateError);
    await expectLater(material(id: 'z' * 43).verifySignature([1], await keys.signer.sign([1])), throwsStateError);
  });
  test('严格wire拒绝额外字段、错误长度/类型及非规范编码', () {
    for (final change in <void Function(Map<String, Object?>)>[
      (m) => m['role'] = 'owner', (m) => m['device_id'] = '${keys.deviceId}\n',
      (m) => m['signing_pub'] = 'a' * 44, (m) => m['exchange_pub'] = '${'a' * 42}_',
      (m) => m['tls_sha256'] = 'g' * 64, (m) => m['tls_sha256'] = 1,
    ]) {
      final json = material().toJson(); change(json);
      expect(() => MemberKeys.fromJson(json), throwsFormatException);
    }
    expect(() => material(tls: 'a' * 63), throwsArgumentError);
  });
}
