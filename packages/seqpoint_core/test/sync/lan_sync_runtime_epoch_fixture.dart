import 'package:seqpoint_core/seqpoint_core.dart'
    hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';

import 'lan_sync_runtime_fixture.dart';

Future<void> rotateRuntimePair(RuntimeFixture f) async {
  final key = VaultKey(epoch: 2, keyBytes: List.filled(32, 61));
  final event = await MembershipEvent.create(
    parent: f.a.membership.state,
    issuer: f.a.keys,
    type: MembershipEventType.rotate,
    epochKey: key,
  );
  final path = 'members/${f.a.keys.deviceId}.json';
  final previous = MembershipFile.decode(
    f.a.controls[path]!,
    issuerFileDeviceId: f.a.keys.deviceId,
    expectedVaultPublicId: f.a.membership.state.vaultPublicId,
    expectedAuthorityId: f.a.membership.state.authorityId,
  );
  final file = MembershipFile(
    vaultPublicId: previous.vaultPublicId,
    authorityId: previous.authorityId,
    issuerDeviceId: f.a.keys.deviceId,
    events: [...previous.events, event],
  );
  f.a.controls[path] = file.encode();
  for (final node in [f.a, f.b]) {
    node.historicalKeys[node.epochKey.epoch] = node.epochKey.keyBytes;
    await node.ingest(path, file.encode());
    node.epochKey = key;
  }
}
