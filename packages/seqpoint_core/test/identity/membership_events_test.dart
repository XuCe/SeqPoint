import 'package:seqpoint_core/seqpoint_core.dart' hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:test/test.dart';

void main() {
  test('签名添加成员、幂等与独立公开授权', () async {
    final founder = await DeviceKeys.fromSeeds(List.filled(32, 5), List.filled(32, 6));
    final guest = await DeviceKeys.fromSeeds(List.filled(32, 8), List.filled(32, 9));
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 7));
    final initial = await MembershipState.createVault(founder: founder,
        vaultPublicId: 'v1', epochKey: key, tlsFingerprint: 'a' * 64);
    final member = MemberKeys(deviceId: guest.deviceId,
        signingPublicKey: guest.signer.publicKey,
        exchangePublicKey: guest.exchangePublicKey, tlsFingerprint: 'b' * 64);
    final event = await MembershipEvent.create(parent: initial, issuer: founder,
        type: MembershipEventType.add, subject: member, epochKey: key);
    final reducer = MembershipReducer(trustedAnchor: initial);
    expect(await reducer.ingest(event, issuerFileDeviceId: founder.deviceId),
        MembershipApplyResult.applied);
    expect(reducer.state.members.keys, contains(guest.deviceId));
    expect(await reducer.ingest(MembershipEvent.fromJson(event.toJson()),
        issuerFileDeviceId: founder.deviceId), MembershipApplyResult.duplicate);
    expect((await reducer.openCurrentEpoch(localDevice: guest))!.keyBytes, key.keyBytes);
    expect(() => reducer.state.members.clear(), throwsUnsupportedError);
  });
}
