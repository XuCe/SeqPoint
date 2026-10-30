import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:seqpoint_core/src/identity/device_keys.dart';
import 'package:test/test.dart';

void main() {
  test('身份由签名公钥完整SHA256指纹派生，种子重开一致', () async {
    final first = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final again = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final fingerprint = await Sha256().hash(first.signer.publicKey);
    expect(first.deviceId, base64UrlEncode(fingerprint.bytes).replaceAll('=', ''));
    expect(again.deviceId, first.deviceId);
    expect(again.exchangePublicKey, first.exchangePublicKey);
    final changed = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 2));
    expect(changed.deviceId, isNot(first.deviceId));
    expect(() => first.exchangePublicKey[0] = 1, throwsUnsupportedError);
  });
  test('双端X25519共享密钥一致，错误公钥拒绝', () async {
    final a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    final b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    final shared = await a.sharedSecret(b.exchangePublicKey);
    expect(shared, hasLength(32));
    expect(shared, await b.sharedSecret(a.exchangePublicKey));
    await expectLater(a.sharedSecret([]), throwsArgumentError);
    await expectLater(a.sharedSecret(List.filled(32, 256)), throwsArgumentError);
    await expectLater(a.sharedSecret(List.filled(32, 0)), throwsStateError);
  });
  test('非法协商种子拒绝', () async {
    await expectLater(DeviceKeys.fromSeeds(List.filled(32, 1), []),
        throwsArgumentError);
    await expectLater(DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, -1)),
        throwsArgumentError);
  });
}
