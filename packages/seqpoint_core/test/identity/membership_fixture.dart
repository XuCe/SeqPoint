import 'package:seqpoint_core/seqpoint_core.dart' hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';

MemberKeys memberIdentity(DeviceKeys device, String tls) => MemberKeys(
  deviceId: device.deviceId, signingPublicKey: device.signer.publicKey,
  exchangePublicKey: device.exchangePublicKey, tlsFingerprint: tls * 64);

Future<({DeviceKeys founder, DeviceKeys guest, VaultKey key,
  MembershipState initial, MembershipEvent add, MembershipReducer reducer})> membershipFixture() async {
  final founder = await DeviceKeys.fromSeeds(List.filled(32, 5), List.filled(32, 6));
  final guest = await DeviceKeys.fromSeeds(List.filled(32, 8), List.filled(32, 9));
  final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 7));
  final initial = await MembershipState.createVault(founder: founder,
      vaultPublicId: 'v1', epochKey: key, tlsFingerprint: 'a' * 64);
  final add = await MembershipEvent.create(parent: initial, issuer: founder,
      type: MembershipEventType.add, subject: memberIdentity(guest, 'b'), epochKey: key);
  final reducer = MembershipReducer(trustedAnchor: initial);
  await reducer.ingest(add, issuerFileDeviceId: founder.deviceId);
  return (founder: founder, guest: guest, key: key, initial: initial, add: add, reducer: reducer);
}
