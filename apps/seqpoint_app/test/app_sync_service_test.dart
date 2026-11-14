import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/sync_identity_store.dart';
import 'package:seqpoint_app/sync/sync_membership_store.dart';
import 'package:seqpoint_app/sync/sync_tls_store.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async { values.remove(key); }
  int reads = 0, writes = 0, membershipWrites = 0;
  bool failMembership = false, corruptReadback = false, _badRead = false;
  Completer<void>? gate;
  Completer<void>? entered;
  @override
  Future<String?> read(String key) async {
    reads++;
    if (_badRead && key == SyncMembershipStore.storageKey) {
      _badRead = false; return '{}';
    }
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    writes++;
    if (key == SyncMembershipStore.storageKey) {
      membershipWrites++; entered?.complete(); await gate?.future;
      if (failMembership) throw StateError('fake-save-failure');
      _badRead = corruptReadback;
    }
    values[key] = value;
  }
}

typedef _Node = ({AppSyncService service, SeqDatabase db, _Secrets secrets, Directory root});

class _StopRetryService extends AppSyncService {
  _StopRetryService({required super.db, required super.root, required super.secrets});
  int cancellations = 0;
  @override
  void cancelPairing() {
    if (++cancellations == 1) throw StateError('fake first cleanup failure');
    super.cancelPairing();
  }
}

Future<({PairingHandshake host, PairingHandshake guest})> _pair(
    AppSyncService host, AppSyncService guest, {bool confirm = true}) async {
  final invitation = await host.createInvitation();
  final responder = await guest.respondToInvitation(invitation.toQrPayload());
  final initiator = await host.acceptResponse(responder.response.toJson());
  if (confirm) {
    final hp = await initiator.confirmShortCode(initiator.shortCode);
    final gp = await responder.confirmShortCode(responder.shortCode);
    await initiator.acceptConfirmation(gp);
    await responder.acceptConfirmation(hp);
  }
  return (host: initiator, guest: responder);
}

void main() {
  late LanTlsIdentity tls;
  setUpAll(() async { tls = await LanTlsIdentity.generate(); });
  Future<_Node> node(int seed) async {
    final secrets = _Secrets();
    secrets.values[SyncIdentityStore.storageKey] = jsonEncode({'v': 1,
      'name': 'fake-$seed', 'added_at': '2026-10-26T00:00:00.000Z',
      'signing_seed': base64Encode(List.filled(32, seed)),
      'exchange_seed': base64Encode(List.filled(32, seed + 20))});
    secrets.values[SyncTlsStore.storageKey] = jsonEncode({'v': 1,
      'certificate_pem': tls.certificatePem, 'private_key_pem': tls.privateKeyPem,
      'fingerprint': tls.fingerprint});
    final db = SeqDatabase.inMemory()..migrate();
    final root = await Directory.systemTemp.createTemp('app-sync-fake-');
    final service = AppSyncService(db: db, root: root, secrets: secrets);
    addTearDown(() async {
      await service.stop(); service.dispose(); db.close(); await root.delete(recursive: true);
    });
    return (service: service, db: db, secrets: secrets, root: root);
  }

  Future<AppSyncService> rotate(_Node n, {required bool sealed}) async {
    await n.service.stop();
    final local = await SyncIdentityStore(n.secrets).loadOrCreate('fake');
    final store = SyncMembershipStore(n.secrets), saved = (await SyncMembershipStore(n.secrets).load(local.keys))!;
    if (sealed) {
      final codec = EncryptedSegmentCodec(vaultPublicId: saved.state.vaultPublicId,
          deviceKeys: local.keys, epochKeys: saved.epochKeys,
          trustedSigners: saved.state.members.map((id, member) => MapEntry(id, member.signingPublicKey)));
      final publisher = SyncPublisher(n.db, deviceId: local.keys.deviceId,
          clock: FakeClock(DateTime.utc(2030, 1)));
      await publisher.publishNext(store: VaultStore(root: n.root,
          deviceId: local.keys.deviceId, codec: codec), keyEpoch: 1);
      await publisher.stop();
    }
    final key = VaultKey(epoch: 2, keyBytes: List.filled(32, 88));
    final event = await MembershipEvent.create(parent: saved.state, issuer: local.keys,
        type: MembershipEventType.rotate, epochKey: key);
    await saved.membership.ingest(event, issuerFileDeviceId: local.keys.deviceId);
    await store.save(membership: saved.membership, localDevice: local.keys, epochKey: key);
    final reopened = AppSyncService(db: n.db, root: n.root, secrets: n.secrets);
    addTearDown(() async { await reopened.stop(); reopened.dispose(); });
    await reopened.prepare('fake');
    return reopened;
  }

  final gatewayLink = Platform.environment['SEQPOINT_TEST_GATEWAY_LINK'];
  test('gateway invitation enrolls without Syncthing and delivers an existing offline note', () async {
    final link = gatewayLink!;
    final expected = Uri.parse(link);
    final pem = await File(Platform.environment['SEQPOINT_TEST_GATEWAY_PEM']!).readAsString();
    final original = HttpOverrides.current;
    HttpOverrides.global = _TestGatewayTrust(expected, pem.trim());
    addTearDown(() => HttpOverrides.global = original);
    SharedPreferences.setMockInitialValues({});
    final a = await node(3), b = await node(4);
    ItemRepository(a.db).insert(Item(id:'before-invite',title:'首台设备的已有事项',
      status:ItemStatus.todo,priority:Priority.p4,source:ItemSource.manual,
      createdAt:DateTime.now().toUtc(),updatedAt:DateTime.now().toUtc()));
    await expectLater(a.service.enableHosted('${expected.origin}/invite#gw.${'0' * 64}'), throwsFormatException);
    expect(a.service.hasVault,isFalse);
    await a.service.enableHosted(link);
    expect(await a.service.gatewayOrigin(),expected.origin);
    await a.service.syncRelay();
    await b.service.prepare('second');
    final pair=await _pair(a.service,b.service);
    await b.service.finishGuest(pair.guest,await a.service.finishHost(pair.host));
    expect(await b.service.gatewayOrigin(),expected.origin);
    await a.service.syncRelay();
    final local = await SyncIdentityStore(a.secrets).loadOrCreate('first');
    final writer = RelayTransport(endpoint:expected.origin,vaultPublicId:a.service.relayVaultId!,keys:local.keys);
    addTearDown(writer.close);
    final used = (await writer.usedBytes() as Ok<int>).value;
    final block = List<int>.filled((1<<20)-used,7);
    expect(await writer.put('blobs/${local.keys.deviceId}/${lanSha256(block)}.bin',block),isA<Ok<void>>());
    Future<void> quota(int mib) async {
      final http=HttpClient();
      try {
        final request=await http.postUrl(Uri.parse(Platform.environment['SEQPOINT_TEST_GATEWAY_ADMIN']!));
        final password=Platform.environment['SEQPOINT_TEST_GATEWAY_PASSWORD']!;
        request.headers.set('Authorization','Basic ${base64Encode(utf8.encode('admin:$password'))}');
        request.headers.contentType=ContentType('application','x-www-form-urlencoded');
        request.write('action=update&vault=${a.service.relayVaultId}&quota=$mib');
        final response=await request.close();await response.drain<void>();expect(response.statusCode,200);
      }finally{http.close(force:true);}
    }
    await quota(1);
    ItemRepository(b.db).insert(Item(id:'guest-offline',title:'第二台离线编辑',status:ItemStatus.todo,
      priority:Priority.p4,source:ItemSource.manual,createdAt:DateTime.now().toUtc(),updatedAt:DateTime.now().toUtc()));
    await a.service.pause();
    await b.service.syncRelay();
    expect(ItemRepository(b.db).byId('before-invite')?.title,'首台设备的已有事项');
    expect(b.service.relayMessage,contains('等待上传'));
    await quota(1024);
    await b.service.syncRelay();
    await a.service.syncRelay();
    expect(ItemRepository(a.db).byId('guest-offline')?.title,'第二台离线编辑');
    await a.service.revokePeer(a.service.verifiedPeers.single,expectedVersion: a.service.membershipVersion!);
    await a.service.syncRelay();
    await expectLater(b.service.syncRelay(),throwsStateError);
  },skip:gatewayLink==null?'requires disposable HTTPS gateway':false);

  final gatewayAdmin = Platform.environment['SEQPOINT_TEST_GATEWAY_ADMIN'];
  test('gateway join link adds a second device through the mailbox and syncs both ways', () async {
    final admin = gatewayAdmin!, password = Platform.environment['SEQPOINT_TEST_GATEWAY_PASSWORD']!;
    final pemPath = Platform.environment['SEQPOINT_TEST_GATEWAY_PEM'];
    final http = HttpClient();
    late String invite;
    try {
      final request = await http.postUrl(Uri.parse(admin));
      request.headers.set('Authorization', 'Basic ${base64Encode(utf8.encode('admin:$password'))}');
      request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      request.write('action=invite');
      final page = await (await request.close()).transform(utf8.decoder).join();
      invite = RegExp(r'https?://[^"<\s]+/invite#gw\.[0-9a-f]{64}').firstMatch(page)!.group(0)!;
    } finally { http.close(force: true); }
    final origin = Uri.parse(invite).origin;
    if (pemPath != null && origin.startsWith('https://')) {
      final original = HttpOverrides.current;
      HttpOverrides.global = _TestGatewayTrust(Uri.parse(origin), (await File(pemPath).readAsString()).trim());
      addTearDown(() => HttpOverrides.global = original);
    }
    SharedPreferences.setMockInitialValues({});
    final a = await node(11), b = await node(12), c = await node(13);
    final d = await node(14), e = await node(15);
    Item item(String id, String title) => Item(id: id, title: title, status: ItemStatus.todo,
        priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.now().toUtc(), updatedAt: DateTime.now().toUtc());
    ItemRepository(a.db).insert(item('host-before', '首台设备已有事项'));
    ItemRepository(b.db).insert(item('guest-before', '新设备加入前的事项'));
    // 新设备以前自建过单机同步空间（没有其他成员、没连过服务器）：加入时自动退出，数据保留。
    await b.service.prepare('second');
    await b.service.newVault();
    final soloVault = b.service.relayVaultId;
    expect(soloVault, isNotNull);

    await expectLater(a.service.connectWithLink('https://example.test/somewhere'), throwsFormatException);
    await a.service.connectWithLink(invite);
    expect(await a.service.gatewayOrigin(), origin);
    await a.service.syncRelay();

    final adding = a.service.startAddDevice();
    addTearDown(adding.cancel);
    for (var i = 0; adding.stage == AddDeviceStage.preparing && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(adding.stage, AddDeviceStage.waiting, reason: adding.error);
    final join = adding.link.toString();
    expect(join, startsWith('$origin/join#'));
    expect(join.length, lessThan(origin.length + 60));

    final steps = <String>[];
    await b.service.connectWithLink(join, onProgress: steps.add);
    expect(steps, containsAllInOrder(['正在退出本机原有的同步空间', '等待已连接设备确认', '正在连接同步服务器']));
    expect(b.service.relayVaultId, isNot(soloVault));
    expect(await b.service.gatewayOrigin(), origin);
    expect(b.service.relayVaultId, a.service.relayVaultId);
    for (var i = 0; adding.stage != AddDeviceStage.done && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(adding.stage, AddDeviceStage.done, reason: adding.error);
    expect(adding.joinedDevice, b.service.identity!.deviceId);
    expect(a.service.verifiedPeers.single.deviceId, b.service.identity!.deviceId);
    expect(b.service.verifiedPeers.single.deviceId, a.service.identity!.deviceId);

    await a.service.syncRelay();
    await b.service.syncRelay();
    expect(ItemRepository(b.db).byId('host-before')?.title, '首台设备已有事项');
    ItemRepository(b.db).insert(item('guest-after', '新设备加入后的事项'));
    await b.service.syncRelay();
    await a.service.syncRelay();
    expect(ItemRepository(a.db).byId('guest-before')?.title, '新设备加入前的事项');
    expect(ItemRepository(a.db).byId('guest-after')?.title, '新设备加入后的事项');

    // 链接只能用一次；第三台设备不会被误加入。
    await expectLater(c.service.connectWithLink(join), throwsFormatException);
    expect(c.service.hasVault, isFalse);
    expect(await c.service.gatewayOrigin(), isNull);

    // 已和其他设备组成空间的设备不会被静默拆散。
    await d.service.prepare('D'); await e.service.prepare('E');
    await d.service.newVault();
    final pair = await _pair(d.service, e.service);
    await e.service.finishGuest(pair.guest, await d.service.finishHost(pair.host));
    final shared = d.service.relayVaultId;
    final again = a.service.startAddDevice();
    addTearDown(again.cancel);
    for (var i = 0; again.stage == AddDeviceStage.preparing && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    ItemRepository(d.db).insert(item('switch-before', '切换空间前的事项'));
    await expectLater(d.service.connectWithLink(again.link.toString()), throwsA(isA<VaultSwitchRequired>()
        .having((error) => error.reasons.join(), 'reasons', contains('1 台其他设备'))));
    expect(d.service.relayVaultId, shared);
    expect(d.service.verifiedPeers.single.deviceId, e.service.identity!.deviceId);
    // 用户确认后：退出原空间再加入，本机数据保留并同步到新空间。
    await d.service.connectWithLink(again.link.toString(), leaveCurrentVault: true);
    expect(d.service.relayVaultId, a.service.relayVaultId);
    expect(await d.service.gatewayOrigin(), origin);
    expect(e.service.relayVaultId, shared);
    await d.service.syncRelay();
    await a.service.syncRelay();
    expect(ItemRepository(a.db).byId('switch-before')?.title, '切换空间前的事项');
  }, timeout: const Timeout(Duration(minutes: 3)),
      skip: gatewayAdmin == null ? 'requires disposable gateway (scripts/sync_acceptance/verify_gateway.py)' : false);

  test('leaving a shared vault keeps local data and an interrupted leave finishes on restart', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await node(21), b = await node(22);
    await a.service.prepare('A'); await b.service.prepare('B');
    await a.service.newVault();
    final pair = await _pair(a.service, b.service);
    await b.service.finishGuest(pair.guest, await a.service.finishHost(pair.host));
    ItemRepository(b.db).insert(Item(id: 'kept', title: '退出后仍保留', status: ItemStatus.todo,
        priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.now().toUtc(), updatedAt: DateTime.now().toUtc()));
    final device = b.service.identity!.deviceId;
    await b.service.leaveVault();
    expect(b.service.hasVault, isFalse);
    expect(b.service.identity!.deviceId, device);
    expect(ItemRepository(b.db).byId('kept')?.title, '退出后仍保留');
    expect(b.secrets.values.containsKey(SyncMembershipStore.storageKey), isFalse);
    expect(b.db.raw.select('SELECT 1 FROM sync_operations'), isEmpty);
    expect(a.service.verifiedPeers.single.deviceId, device);
    // 退出后可以重新建立空间，基线重新发布本机数据。
    await b.service.newVault();
    expect(b.service.canSync, isTrue);
    expect(b.db.raw.select('SELECT 1 FROM sync_operations'), isNotEmpty);

    // 模拟退出中途被杀：只写了"正在退出"标记。下次启动自动完成退出，而不是卡住。
    await (await SharedPreferences.getInstance()).setBool('sync.leavingVault', true);
    await b.service.stop();
    final reopened = AppSyncService(db: b.db, root: b.root, secrets: b.secrets);
    addTearDown(() async { await reopened.stop(); reopened.dispose(); });
    await reopened.prepare('B');
    expect(reopened.hasVault, isFalse);
    expect(reopened.identity!.deviceId, device);
    expect((await SharedPreferences.getInstance()).getBool('sync.leavingVault'), isNull);
    expect(ItemRepository(b.db).byId('kept')?.title, '退出后仍保留');
  });

  test('relay address persists per vault and invalid origins are rejected', () async {
    SharedPreferences.setMockInitialValues({});
    final a = await node(1), b = await node(2);
    await a.service.prepare('A'); await b.service.prepare('B');
    expect(() => a.service.relayNodeConfiguration, throwsStateError);
    await a.service.newVault(); await b.service.newVault();
    await a.service.saveRelayEndpoint(' https://sync.example.com ');
    expect(await a.service.loadRelayEndpoint(), 'https://sync.example.com');
    expect(await b.service.loadRelayEndpoint(), '');
    await a.service.prepare('A');
    expect(await a.service.loadRelayEndpoint(), 'https://sync.example.com');
    await expectLater(a.service.saveRelayEndpoint('ftp://sync.example.com'), throwsArgumentError);
    expect(await a.service.loadRelayEndpoint(), 'https://sync.example.com');
    await a.service.saveRelayEndpoint('http://sync.example.com');
    await a.service.prepare('A');
    expect(await a.service.loadRelayEndpoint(), 'http://sync.example.com');
    await a.service.saveRelayEndpoint('');
    await expectLater(a.service.syncRelay(), throwsStateError);
    expect(a.service.relayMessage, contains('请先连接同步服务器'));
  });

  test('relay configuration exports current paired public keys only', () async {
    final a = await node(1), b = await node(2);
    await a.service.prepare('A'); await b.service.prepare('B');
    await a.service.newVault();
    final sessions = await _pair(a.service, b.service);
    final packet = await a.service.finishHost(sessions.host);
    await b.service.finishGuest(sessions.guest, packet);
    final config = jsonDecode(a.service.relayNodeConfiguration) as Map;
    expect((config['devices'] as Map).keys.toSet(),
      {a.service.identity!.deviceId, b.service.identity!.deviceId});
    expect(config.keys.toSet(), {'vaultId', 'devices', 'quotaBytes'});
    expect(config['vaultId'], a.service.relayVaultId);
  });

  test('construction is inert and prepare leaves vault and writer disabled', () async {
    final n = await node(1);
    expect(n.secrets.reads, 0); expect(n.secrets.writes, 0);
    expect(n.service.prepared, isFalse);
    expect(n.service.canSync, isFalse);
    await n.service.prepare('fake');
    expect(n.service.prepared, isTrue);
    expect(n.service.status, '未配对');
    expect(n.secrets.values.containsKey(SyncMembershipStore.storageKey), isFalse);
    expect(n.db.raw.select('SELECT enabled FROM sync_local').single['enabled'], 0);
    expect(n.service.listeningPort, isNull);
    await expectLater(n.service.startServer(address: InternetAddress.loopbackIPv4), throwsStateError);
  });

  test('explicit vault persists before baseline and survives a new service', () async {
    final n = await node(2);
    await n.service.prepare('fake'); await n.service.newVault();
    expect(n.secrets.membershipWrites, 1);
    expect(n.service.canSync, isTrue);
    expect(n.service.verifiedPeers, isEmpty);
    final writer = n.db.raw.select('SELECT * FROM sync_local').single;
    expect(writer['device_id'], n.service.identity!.deviceId);
    expect(writer['baseline_ready'], 1);
    await n.service.stop();
    final reload = AppSyncService(db: n.db, root: n.root, secrets: n.secrets);
    try {
      await reload.prepare('ignored'); expect(reload.canSync, isTrue);
      expect(reload.identity!.deviceId, n.service.identity!.deviceId);
    } finally { await reload.stop(); reload.dispose(); }
  });

  test('unconfirmed pairing cannot publish member facts or a key packet', () async {
    final h = await node(3), g = await node(4);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service, confirm: false);
    await expectLater(h.service.finishHost(p.host), throwsStateError);
    expect(h.secrets.membershipWrites, 1);
    expect(h.service.verifiedPeers, isEmpty);
    expect(g.service.canSync, isFalse);
  });

  test('SAS pairing persists both identities then pulls encrypted data over loopback', () async {
    final h = await node(5), g = await node(6);
    ItemRepository(h.db).insert(Item(id: 'shared', title: 'from-host',
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026, 10, 26), updatedAt: DateTime.utc(2026, 10, 26)));
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    final packet = await h.service.finishHost(p.host);
    await g.service.finishGuest(p.guest, packet);
    expect(h.service.verifiedPeers.single.deviceId, g.service.identity!.deviceId);
    expect(g.service.verifiedPeers.single.deviceId, h.service.identity!.deviceId);
    expect(g.service.canSync, isTrue);
    final port = await h.service.startServer(address: InternetAddress.loopbackIPv4);
    expect(h.service.status, '已监听端口 $port');
    final guestPort = await g.service.startServer(address: InternetAddress.loopbackIPv4);
    final published = await h.service.syncOnce(peerDeviceId: g.service.identity!.deviceId,
        host: '127.0.0.1', port: guestPort);
    expect(published.pushed, greaterThan(0));
    expect(published.pulled, 0);
    final round = await g.service.syncOnce(peerDeviceId: h.service.identity!.deviceId,
        host: '127.0.0.1', port: port);
    expect(round.pulled, greaterThan(0));
    expect(g.service.lastRound, same(round));
    expect(ItemRepository(g.db).byId('shared')!.title, 'from-host');
    await h.service.pause(); expect(h.service.listeningPort, isNull);
    expect(h.service.status, '同步已暂停');
    expect(await h.service.startServer(address: InternetAddress.loopbackIPv4), greaterThan(0));
  });

  test('failed member save emits no packet and a fresh pairing can retry', () async {
    final h = await node(7), g = await node(8);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final first = await _pair(h.service, g.service);
    h.secrets.failMembership = true;
    await expectLater(h.service.finishHost(first.host), throwsStateError);
    expect(first.host.state, PairingHandshakeState.ready);
    expect(g.service.canSync, isFalse);
    expect(h.service.canSync, isFalse);
    h.secrets.failMembership = false;
    await h.service.prepare('h');
    final retry = await _pair(h.service, g.service);
    await g.service.finishGuest(retry.guest, await h.service.finishHost(retry.host));
    expect(g.service.canSync, isTrue);
  });

  test('readback failure releases no key and an already active guest can retry delivery', () async {
    final h = await node(9), g = await node(10);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final first = await _pair(h.service, g.service);
    h.secrets.corruptReadback = true;
    await expectLater(h.service.finishHost(first.host), throwsStateError);
    expect(first.host.state, PairingHandshakeState.ready);
    expect(g.service.canSync, isFalse);
    h.secrets.corruptReadback = false; await h.service.prepare('h');
    expect(h.service.verifiedPeers, hasLength(1));
    final writes = h.secrets.membershipWrites;
    final retry = await _pair(h.service, g.service);
    final packet = await h.service.finishHost(retry.host);
    expect(h.secrets.membershipWrites, writes);
    await g.service.finishGuest(retry.guest, packet);
    expect(g.service.canSync, isTrue);
  });

  test('lost delivery retries the same active full identity without another add', () async {
    final h = await node(11), g = await node(12);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final lost = await _pair(h.service, g.service);
    await h.service.finishHost(lost.host);
    final writes = h.secrets.membershipWrites;
    final retry = await _pair(h.service, g.service);
    await g.service.finishGuest(retry.guest, await h.service.finishHost(retry.host));
    expect(h.secrets.membershipWrites, writes);
    expect(h.service.verifiedPeers, hasLength(1));
  });

  test('stop remains one shared drain when a listener reenters stop', () async {
    final n = await node(13);
    Future<void>? nested;
    var reentered = false;
    n.service.addListener(() {
      if (!reentered) { reentered = true; nested = n.service.stop(); }
    });
    final stopped = n.service.stop();
    expect(stopped, same(nested));
    await stopped;
  });

  test('failed stop keeps admission closed but permits one real cleanup retry', () async {
    final n = await node(25);
    final service = _StopRetryService(db: n.db, root: n.root, secrets: n.secrets);
    addTearDown(() async { await service.stop(); service.dispose(); });
    await service.prepare('fake');
    final first = service.stop();
    expect(service.stop(), same(first));
    await expectLater(first, throwsStateError);
    expect(service.cancellations, 1);
    await expectLater(service.prepare('refused'), throwsStateError);
    Future<void>? nested;
    var reentered = false;
    service.addListener(() {
      if (!reentered) { reentered = true; nested = service.stop(); }
    });
    final retry = service.stop();
    expect(retry, isNot(same(first)));
    expect(retry, same(nested));
    expect(service.stop(), same(retry));
    await retry;
    expect(service.cancellations, 2);
    expect(service.membershipState?.name, 'stopped');
    expect(service.stop(), same(retry));
    await expectLater(service.prepare('still refused'), throwsStateError);
  });

  test('stop drains an accepted membership save before the database may close', () async {
    final h = await node(14), g = await node(15);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    h.secrets.gate = Completer<void>(); h.secrets.entered = Completer<void>();
    final saving = h.service.finishHost(p.host);
    await h.secrets.entered!.future;
    var drained = false;
    final stopped = h.service.stop().then((_) { drained = true; });
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(h.service.prepare('rejected'), throwsStateError);
    h.secrets.gate!.complete();
    await saving; await stopped;
    expect(drained, isTrue);
    expect(h.db.raw.select('SELECT enabled FROM sync_local').single['enabled'], 1);
  });

  test('restored database requiring identity replacement never reuses its writer', () async {
    final n = await node(16);
    n.db.raw.execute('UPDATE sync_local SET requires_new_identity=1');
    await n.service.prepare('fake');
    await expectLater(n.service.newVault(), throwsStateError);
    expect(n.service.canSync, isFalse);
    expect(n.service.error, isNotNull);
    final writer = n.db.raw.select('SELECT * FROM sync_local').single;
    expect(writer['enabled'], 0); expect(writer['requires_new_identity'], 1);
    expect(writer['device_id'], isNull);
    expect(n.db.raw.select('SELECT * FROM sync_operations'), isEmpty);
  });

  test('guest rejects a changed final checkpoint before writing membership or baseline', () async {
    final h = await node(17), g = await node(18);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    final packet = await h.service.finishHost(p.host);
    final altered = Map<String, Object?>.from(packet['checkpoint']! as Map);
    altered['epoch'] = 100;
    await expectLater(g.service.finishGuest(p.guest,
        {'checkpoint': altered, 'epoch_envelope': packet['epoch_envelope']}), throwsStateError);
    expect(g.secrets.membershipWrites, 0);
    expect(g.service.canSync, isFalse);
    expect(g.db.raw.select('SELECT enabled FROM sync_local').single['enabled'], 0);
  });

  test('reopened existing writer without epoch key can serve and pull control only', () async {
    final h = await node(19), g = await node(20);
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    await g.service.finishGuest(p.guest, await h.service.finishHost(p.host));
    await g.service.stop();
    final record = jsonDecode(g.secrets.values[SyncMembershipStore.storageKey]!) as Map;
    record['epoch'] = null; record['key'] = null;
    g.secrets.values[SyncMembershipStore.storageKey] = jsonEncode(record);
    final reopened = AppSyncService(db: g.db, root: g.root, secrets: g.secrets);
    try {
      await reopened.prepare('g');
      expect(reopened.canSync, isTrue);
      expect(reopened.status, '等待有效成员密钥');
      expect(await reopened.startServer(address: InternetAddress.loopbackIPv4), greaterThan(0));
      final port = await h.service.startServer(address: InternetAddress.loopbackIPv4);
      final round = await reopened.syncOnce(peerDeviceId: h.service.identity!.deviceId,
          host: '127.0.0.1', port: port);
      expect(round.pushed, 0);
      expect(round.waitingPeers, contains(h.service.identity!.deviceId));
    } finally { await reopened.stop(); reopened.dispose(); }
  });

  for (final sealed in [false, true]) {
    test('rotation authenticates an old ${sealed ? 'sealed' : 'open'} own head and publishes epoch two', () async {
      final h = await node(21), g = await node(22);
      void insert(String id) => ItemRepository(h.db).insert(Item(id: id, title: id,
          status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
          createdAt: DateTime.utc(2026, 10, 26), updatedAt: DateTime.utc(2026, 10, 26)));
      insert('epoch-one');
      await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
      final p = await _pair(h.service, g.service);
      await g.service.finishGuest(p.guest, await h.service.finishHost(p.host));
      final port = await g.service.startServer(address: InternetAddress.loopbackIPv4);
      await h.service.syncOnce(peerDeviceId: g.service.identity!.deviceId, host: '127.0.0.1', port: port);
      expect(h.db.raw.select('SELECT sealed FROM sync_publications').single['sealed'], 0);
      final reopened = await rotate(h, sealed: sealed);
      expect(h.db.raw.select('SELECT sealed FROM sync_publications').single['sealed'], sealed ? 1 : 0);
      insert('epoch-two');
      final round = await reopened.syncOnce(peerDeviceId: g.service.identity!.deviceId,
          host: '127.0.0.1', port: port);
      expect(round.pushed, greaterThan(0));
      final publications = h.db.raw.select('SELECT key_epoch,sealed FROM sync_publications ORDER BY seq');
      expect(publications.map((row) => row['key_epoch']), [1, 2]);
      expect(publications.first['sealed'], 1);
      expect(h.db.raw.select('SELECT * FROM sync_operations WHERE publication_seq IS NULL'), isEmpty);
    });
  }

  test('retained keys still reject a tampered old own head and retain pending new operations', () async {
    final h = await node(23), g = await node(24);
    void insert(String id) => ItemRepository(h.db).insert(Item(id: id, title: id,
        status: ItemStatus.todo, priority: Priority.p4, source: ItemSource.manual,
        createdAt: DateTime.utc(2026, 10, 26), updatedAt: DateTime.utc(2026, 10, 26)));
    insert('epoch-one');
    await h.service.prepare('h'); await g.service.prepare('g'); await h.service.newVault();
    final p = await _pair(h.service, g.service);
    await g.service.finishGuest(p.guest, await h.service.finishHost(p.host));
    final port = await g.service.startServer(address: InternetAddress.loopbackIPv4);
    await h.service.syncOnce(peerDeviceId: g.service.identity!.deviceId, host: '127.0.0.1', port: port);
    final reopened = await rotate(h, sealed: false);
    final row = h.db.raw.select('SELECT * FROM sync_publications').single;
    final segment = Segment.decode(List<int>.from(row['segment_bytes'] as List));
    final bad = List<int>.from(segment.signature)..[0] ^= 1;
    final bytes = segment.withPayload(segment.payload, signature: bad).encode();
    h.db.raw.execute('UPDATE sync_publications SET segment_bytes=? WHERE seq=?', [bytes, row['seq']]);
    await File('${h.root.path}/ops/${h.service.identity!.deviceId}/${row['file_name']}').writeAsBytes(bytes);
    insert('epoch-two');
    await expectLater(reopened.syncOnce(peerDeviceId: g.service.identity!.deviceId,
        host: '127.0.0.1', port: port), throwsStateError);
    expect(h.db.raw.select('SELECT * FROM sync_operations WHERE publication_seq IS NULL'), isNotEmpty);
    expect(h.db.raw.select('SELECT * FROM sync_publications WHERE key_epoch=2'), isEmpty);
  });
}

class _TestGatewayTrust extends HttpOverrides {
  _TestGatewayTrust(this.origin,this.pem);
  final Uri origin;
  final String pem;
  @override
  HttpClient createHttpClient(SecurityContext? context) => super.createHttpClient(context)
    ..badCertificateCallback = (cert, host, port) =>
        host == origin.host && port == origin.port && cert.pem.trim() == pem;
}
