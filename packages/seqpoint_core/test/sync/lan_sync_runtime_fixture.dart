import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart'
    hide MembershipEvent, MembershipEventType;
import 'package:seqpoint_core/src/identity/membership_state.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';

class RuntimeNode {
  RuntimeNode(this.directory, this.keys, this.membership, this.epochKey);
  final Directory directory;
  final DeviceKeys keys;
  VaultKey epochKey;
  MembershipReducer membership;
  Object version = Object();
  bool ready = true;
  bool keyAvailable = true;
  final Map<int, List<int>> historicalKeys = {};
  late SeqDatabase db;
  late LanSyncRuntime runtime;
  final Map<String, List<int>> controls = {};
  int ingested = 0, reconciled = 0;
  Future<void> Function()? beforeSave;
  Future<void> Function()? afterCommit;
  Future<void> Function(File, List<int>)? segmentWriter, ackWriter;

  LanSyncMembership? snapshot() => !ready
      ? null
      : LanSyncMembership(
          version: version,
          policy: MembershipSyncPolicy(
            membership: membership,
            localDeviceId: keys.deviceId,
            hasEpochKey: (epoch) =>
                (keyAvailable && epoch == epochKey.epoch) ||
                historicalKeys.containsKey(epoch),
          ),
          epochKeys: {
            ...historicalKeys,
            if (keyAvailable) epochKey.epoch: epochKey.keyBytes,
          },
        );
  MemberKeys? authorize(String vault, String id) =>
      ready &&
          vault == membership.state.vaultPublicId &&
          membership.isMemberAuthorized(id)
      ? membership.state.members[id]
      : null;

  Future<void> open() async {
    await directory.create(recursive: true);
    db = SeqDatabase.open('${directory.path}/data.sqlite')..migrate();
    SyncBaseline(db).initialize(keys.deviceId);
    runtime = LanSyncRuntime(
      db: db,
      root: Directory('${directory.path}/vault'),
      localDevice: keys,
      currentMembership: snapshot,
      authorize: authorize,
      controlFiles: () => controls,
      ingestControl: ingest,
      writeSegmentBytes: (file, bytes) async {
        if (segmentWriter != null) {
          await segmentWriter!(file, bytes);
        } else {
          await file.writeAsBytes(bytes, flush: true);
        }
      },
      writeAckBytes: (file, bytes) async {
        if (ackWriter != null) {
          await ackWriter!(file, bytes);
        } else {
          await file.writeAsBytes(bytes, flush: true);
        }
      },
      onCommittedChange: () async {
        reconciled++;
        await afterCommit?.call();
      },
    );
  }

  Future<void> ingest(String path, List<int> bytes) async {
    ready = false;
    version = Object();
    final issuer = path.substring(
      'members/'.length,
      path.length - '.json'.length,
    );
    final file = MembershipFile.decode(
      bytes,
      issuerFileDeviceId: issuer,
      expectedVaultPublicId: membership.state.vaultPublicId,
      expectedAuthorityId: membership.state.authorityId,
    );
    final candidate = await MembershipReducer.restoreTrustedLocal(
      membership.toTrustedLocalJson(),
    );
    await file.ingestInto(candidate);
    await beforeSave?.call();
    await File('${directory.path}/control-$issuer.json')
        .writeAsBytes(bytes, flush: true);
    membership = candidate;
    ingested++;
    version = Object();
    ready = true;
  }

  void addOperations(int count, {int start = 0}) {
    for (var i = start; i < start + count; i++) {
      db.raw.execute(
        'INSERT INTO sync_operations '
        '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
        "VALUES (?,?,1,?,'note','n1','raw_content',?,'local')",
        ['${keys.deviceId}:$i', keys.deviceId, i, jsonEncode('value:$i')],
      );
    }
  }

  Future<void> close() async {
    await runtime.stop();
    db.close();
  }
}

SecurityContext runtimeTlsContext() => SecurityContext()
  ..useCertificateChain('test/sync/transport/fixtures/localhost_cert.pem')
  ..usePrivateKey('test/sync/transport/fixtures/localhost_key.pem');

class RuntimeFixture {
  late Directory root;
  late RuntimeNode a, b;
  late String pin;
  final Map<String, int> ports = {};

  Future<void> init({String vaultId = 'runtime-vault'}) async {
    root = await Directory.systemTemp.createTemp('seqpoint-runtime-');
    final pem = await File('test/sync/transport/fixtures/localhost_cert.pem')
        .readAsLines();
    pin = lanSha256(
      base64Decode(pem.where((line) => !line.startsWith('---')).join()),
    );
    final ka = await DeviceKeys.fromSeeds(
      List.filled(32, 21),
      List.filled(32, 22),
    );
    final kb = await DeviceKeys.fromSeeds(
      List.filled(32, 23),
      List.filled(32, 24),
    );
    final key = VaultKey(epoch: 1, keyBytes: List.filled(32, 25));
    final anchor = await MembershipState.createVault(
      founder: ka,
      vaultPublicId: vaultId,
      epochKey: key,
      tlsFingerprint: pin,
    );
    final add = await MembershipEvent.create(
      parent: anchor,
      issuer: ka,
      type: MembershipEventType.add,
      epochKey: key,
      subject: MemberKeys(
        deviceId: kb.deviceId,
        signingPublicKey: kb.signer.publicKey,
        exchangePublicKey: kb.exchangePublicKey,
        tlsFingerprint: pin,
      ),
    );
    final reducer = MembershipReducer(trustedAnchor: anchor);
    await reducer.ingest(add, issuerFileDeviceId: ka.deviceId);
    a = RuntimeNode(Directory('${root.path}/a'), ka, reducer, key);
    b = RuntimeNode(
      Directory('${root.path}/b'),
      kb,
      await MembershipReducer.restoreTrustedLocal(reducer.toTrustedLocalJson()),
      key,
    );
    for (final node in [a, b]) {
      await node.open();
      final file = MembershipFile(
        vaultPublicId: anchor.vaultPublicId,
        authorityId: anchor.authorityId,
        issuerDeviceId: node.keys.deviceId,
        events: node == a ? [add] : [],
      );
      node.controls[file.path] = file.encode();
    }
  }

  LanPeer peer(RuntimeNode node) => LanPeer(
    deviceId: node.keys.deviceId,
    host: '127.0.0.1',
    port: ports[node.keys.deviceId]!,
    tlsFingerprint: pin,
  );

  Future<void> start() async {
    for (final node in [a, b]) {
      ports[node.keys.deviceId] = await node.runtime.startServer(
        securityContext: runtimeTlsContext(),
        tlsFingerprint: pin,
      );
    }
  }

  Future<void> dispose() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  }
}
