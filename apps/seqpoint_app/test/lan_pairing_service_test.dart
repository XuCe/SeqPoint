import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/lan_pairing_link.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('Storage unavailable');
    values[key] = value;
  }
}

Future<AppSyncService> _node(String name) async {
  final db = SeqDatabase.inMemory()..migrate();
  final root = await Directory.systemTemp.createTemp('lan-pairing-');
  final service = AppSyncService(db: db, root: root, secrets: _Secrets());
  addTearDown(() async {
    await service.stop();
    service.dispose();
    db.close();
    await root.delete(recursive: true);
  });
  await service.prepare(name);
  return service;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'QR can reach the other interface when the first address is unavailable',
    () async {
      final a = await _node('a'), b = await _node('b');
      await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
      final original = a.lanPairing.link!;
      final link = LanPairingLink(
        addresses: [
          LanPairingAddress.parse('127.0.0.2:${a.lanPairing.port}'),
          ...original.addresses,
        ],
        invitation: original.invitation,
      );
      await b.lanPairing.connect(link);
      expect(b.lanPairing.connectedPeer, a.identity!.deviceId);
    },
  );
  test('cancel during QR verification cannot reopen a connection', () async {
    final a = await _node('a'), b = await _node('b');
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    final connecting = b.lanPairing.connect(a.lanPairing.link!);
    final outcome = connecting.then<void>((_) {}, onError: (Object _) {});
    await b.lanPairing.close();
    await outcome;
    expect(b.lanPairing.connectedPeer, isNull);
    expect(b.hasVault, isFalse);
    expect(a.hasVault, isFalse);
  });
  test('cancel during listen cannot resurrect a listener', () async {
    final a = await _node('a');
    final listening = a.lanPairing.listen(
      address: InternetAddress.loopbackIPv4,
    );
    final outcome = listening.then<void>((_) {}, onError: (Object _) {});
    await a.lanPairing.close();
    await outcome;
    expect(a.lanPairing.port, isNull);
    expect(a.lanPairing.link, isNull);
  });

  test(
    'new listener survives cancellation of an older outgoing connection',
    () async {
      final a = await _node('a'), b = await _node('b');
      await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
      final failure = expectLater(
        b.lanPairing.connectAddress(a.lanPairing.addresses.single),
        throwsA(anything),
      );
      await _until(() => a.lanPairing.awaitingApproval);
      await b.lanPairing.listen(address: InternetAddress.loopbackIPv4);
      await failure;
      expect(b.lanPairing.port, isNotNull);
      expect(b.lanPairing.link, isNotNull);
    },
  );
  test(
    'restart restores authenticated peers and the stable listening port',
    () async {
      final a = await _node('a'), b = await _node('b');
      await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
      await b.lanPairing.connect(a.lanPairing.link!);
      final port = a.listeningPort;
      await a.stop();
      final restored = AppSyncService(
        db: a.db,
        root: a.root,
        secrets: a.secrets,
      );
      addTearDown(() async {
        await restored.stop();
        restored.dispose();
      });
      await restored.startAutomatic();
      await _until(() => restored.listeningPort != null);
      expect(restored.listeningPort, port);
      expect(restored.lanPeers.single.deviceId, b.identity!.deviceId);
      await restored.pause();
      expect(restored.listeningPort, isNull);
      await expectLater(
        restored.startServer(automatic: true),
        throwsStateError,
      );
      final peer = restored.lanPeers.single;
      await expectLater(
        restored.syncOnce(
          peerDeviceId: peer.deviceId,
          host: peer.host,
          port: peer.port,
          automatic: true,
        ),
        throwsStateError,
      );
      await restored.resumeAutomatic();
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(restored.listeningPort, isNull);
      await restored.setLanEnabled(true);
      expect(restored.listeningPort, port);
    },
  );
  test('pairing automatically synchronizes edits in both directions', () async {
    final a = await _node('a'), b = await _node('b');
    final ar = ItemRepository(a.db), br = ItemRepository(b.db);
    ar.insert(
      Item(
        id: 'shared',
        title: 'from A',
        status: ItemStatus.todo,
        priority: Priority.p4,
        source: ItemSource.manual,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    await b.lanPairing.connect(a.lanPairing.link!);
    await _until(() => br.byId('shared') != null);
    expect(br.byId('shared')!.title, 'from A');
    br.update(br.byId('shared')!.copyWith(title: 'from B'));
    await _until(() => ar.byId('shared')?.title == 'from B');
    expect(a.lanEnabled, isTrue);
    expect(b.lanEnabled, isTrue);
    expect(a.lanPeers.single.deviceId, b.identity!.deviceId);
    expect(b.lanPeers.single.deviceId, a.identity!.deviceId);
  });
  test('different vaults are rejected without changing either vault', () async {
    final a = await _node('a'), b = await _node('b');
    await a.newVault();
    await b.newVault();
    final av = a.relayVaultId, bv = b.relayVaultId;
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    await expectLater(
      b.lanPairing.connect(a.lanPairing.link!),
      throwsStateError,
    );
    expect(a.relayVaultId, av);
    expect(b.relayVaultId, bv);
    expect(a.verifiedPeers, isEmpty);
    expect(b.verifiedPeers, isEmpty);
  });

  test('rejecting a manual request never grants membership', () async {
    final a = await _node('a'), b = await _node('b');
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    final failed = expectLater(
      b.lanPairing.connectAddress(a.lanPairing.addresses.single),
      throwsA(anything),
    );
    await _until(() => a.lanPairing.awaitingApproval);
    await a.lanPairing.reject();
    await failed;
    expect(a.verifiedPeers, isEmpty);
    expect(a.hasVault, isFalse);
    expect(b.hasVault, isFalse);
    expect(a.lanPairing.connectedPeer, isNull);
  });

  test('failed guest storage cannot report connected', () async {
    final a = await _node('a'), b = await _node('b');
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    (b.secrets as _Secrets).failWrites = true;
    await expectLater(
      b.lanPairing.connect(a.lanPairing.link!),
      throwsStateError,
    );
    expect(a.lanPairing.connectedPeer, isNull);
    expect(b.lanPairing.connectedPeer, isNull);
  });
  test('phone approval gates manual pairing with existing PC vault', () async {
    final pc = await _node('pc'), phone = await _node('phone');
    await pc.newVault();
    final vault = pc.relayVaultId;
    await phone.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    final connecting = pc.lanPairing.connectAddress(
      LanPairingAddress.parse('127.0.0.1:${phone.lanPairing.port}'),
    );
    await _until(
      () =>
          phone.lanPairing.awaitingApproval && pc.lanPairing.shortCode != null,
    );
    expect(phone.hasVault, isFalse);
    expect(pc.verifiedPeers, isEmpty);
    expect(phone.lanPairing.connectedPeer, isNull);
    expect(phone.lanPairing.shortCode, pc.lanPairing.shortCode);
    await phone.lanPairing.allow(pc.lanPairing.shortCode!);
    await connecting;
    expect(phone.relayVaultId, vault);
    expect(phone.lanPairing.connectedPeer, pc.identity!.deviceId);
  });

  test('QR reconnect preserves existing membership and vault', () async {
    final a = await _node('a'), b = await _node('b');
    await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    await b.lanPairing.connect(a.lanPairing.link!);
    final vault = a.relayVaultId;
    await b.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    await a.lanPairing.connect(b.lanPairing.link!);
    expect(a.relayVaultId, vault);
    expect(b.relayVaultId, vault);
    expect(a.verifiedPeers.length, 1);
    expect(b.verifiedPeers.length, 1);
  });
  test('QR pairs two fresh devices and saves both memberships', () async {
    final pc = await _node('pc'), phone = await _node('phone');
    await pc.lanPairing.listen(address: InternetAddress.loopbackIPv4);
    await phone.lanPairing.connect(pc.lanPairing.link!);
    expect(pc.lanPairing.connectedPeer, phone.identity!.deviceId);
    expect(phone.lanPairing.connectedPeer, pc.identity!.deviceId);
    expect(phone.relayVaultId, pc.relayVaultId);
    expect(pc.verifiedPeers.single.deviceId, phone.identity!.deviceId);
    expect(phone.verifiedPeers.single.deviceId, pc.identity!.deviceId);
  });
}

Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Pairing did not advance');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
