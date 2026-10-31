import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/platform/syncthing_engine_host.dart';
import 'package:seqpoint_app/sync/app_sync_service.dart';
import 'package:seqpoint_app/sync/syncthing_client.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Secrets extends Fake implements SecretStore {
  final values = <String, String>{};
  bool failNasWrite = false, failReadAfterWrite = false, failNextRead = false;
  Completer<void>? writeStarted, releaseWrite;
  @override
  Future<String?> read(String key) async {
    if (failNextRead && key.startsWith('sync.syncthing.')) {
      failNextRead = false;
      throw StateError('readback unavailable');
    }
    return values[key];
  }
  @override
  Future<void> write(String key, String value) async {
    if (key.startsWith('sync.syncthing.') && writeStarted != null) {
      if (!writeStarted!.isCompleted) writeStarted!.complete();
      await releaseWrite!.future;
    }
    if (failNasWrite && key.startsWith('sync.syncthing.')) {
      throw StateError('storage unavailable');
    }
    values[key] = value;
    if (failReadAfterWrite && key.startsWith('sync.syncthing.')) failNextRead = true;
  }
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.empty();
  bool failCommit = false, failReload = false;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (failCommit && key.endsWith('.enabledRevision')) return false;
    return super.setValue(type, key, value);
  }
  @override
  Future<Map<String, Object>> getAll() async {
    if (failReload) throw StateError('preferences unavailable');
    return super.getAll();
  }
}

void main() {
  final executable = Platform.environment['SEQPOINT_SYNCTHING_BIN'];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SharedPreferencesStorePlatform.instance = _Preferences();
  });
  test(
    'paired apps exchange through NAS with LAN disabled and respect pause',
    () async {
      final root = await Directory.systemTemp.createTemp('seqpoint-nas-app-');
      final nas = SyncthingEngineHost(
        home: Directory('${root.path}/nas'),
        secrets: _Secrets(),
        executable: executable,
      );
      final nodes = <AppSyncService>[];
      try {
        for (final name in ['a', 'b']) {
          final secrets = _Secrets();
          final host = SyncthingEngineHost(
            home: Directory('${root.path}/$name/engine'),
            secrets: secrets,
            executable: executable,
          );
          final db = SeqDatabase.inMemory()..migrate();
          final service = AppSyncService(
            db: db,
            root: Directory('${root.path}/$name/sync-vault'),
            secrets: secrets,
            engineHost: host,
          );
          nodes.add(service);
          await service.prepare(name);
        }
        await _exercise(root, nas, nodes[0], nodes[1]);
      } finally {
        for (final node in nodes) {
          await node.stop();
          node.dispose();
          node.db.close();
        }
        await nas.stop();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: executable == null
        ? 'Set SEQPOINT_SYNCTHING_BIN for real NAS test'
        : false,
  );
}

Future<void> _exercise(
  Directory root,
  SyncthingEngineHost nas,
  AppSyncService a,
  AppSyncService b,
) async {
  final endpoint = await nas.start();
  final api = SyncthingClient(endpoint);
  await api.request('PATCH', 'config/defaults/folder', {
    'path': '${root.path}/nas-files',
  });
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final address = 'tcp://127.0.0.1:${socket.port}';
  await socket.close();
  await api.request('PATCH', 'config/options', {
    'listenAddresses': [address],
    'globalAnnounceEnabled': false,
    'localAnnounceEnabled': false,
    'relaysEnabled': false,
    'natEnabled': false,
  });
  var listenerReady = false;
  for (var retry = 0; retry < 50; retry++) {
    final status = await api.request('GET', 'system/status') as Map;
    if ((status['connectionServiceStatus'] as Map).containsKey(address)) {
      listenerReady = true;
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (const bool.fromEnvironment('SEQPOINT_DIAGNOSTICS')) {
    stdout.writeln('NAS listener ready: $listenerReady');
  }
  await expectLater(
    a.saveSyncthing(address: endpoint.baseUrl, apiKey: endpoint.apiKey),
    throwsStateError,
  );
  await a.lanPairing.listen(address: InternetAddress.loopbackIPv4);
  await b.lanPairing.connect(a.lanPairing.link!);
  await a.setLanEnabled(false);
  await b.setLanEnabled(false);
  final storage = a.secrets as _Secrets;
  storage.failNasWrite = true;
  await expectLater(
    a.saveSyncthing(address: endpoint.baseUrl, apiKey: endpoint.apiKey),
    throwsStateError,
  );
  expect(a.syncthingEnabled, isFalse);
  expect(await a.loadSyncthingAddress(), isEmpty);
  storage.failNasWrite = false;
  for (final node in [a, b]) {
    await node.saveSyncthing(
      address: endpoint.baseUrl,
      apiKey: endpoint.apiKey,
    );
    expect(node.syncthingEnabled, isTrue);
    expect(await node.loadSyncthingAddress(), endpoint.baseUrl);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getKeys().map((k) => preferences.get(k).toString()).join(),
      isNot(contains(endpoint.apiKey)),
    );
  }
  final folders = await api.request('GET', 'config/folders') as List;
  await expectLater(
    a.saveSyncthing(address: 'https://different.invalid', apiKey: ''),
    throwsStateError,
  );
  expect(await a.loadSyncthingAddress(), endpoint.baseUrl);
  expect(folders, hasLength(1));
  expect(folders.single['devices'], hasLength(3));
  if (const bool.fromEnvironment('SEQPOINT_DIAGNOSTICS')) {
    final nasId = await nas.localDeviceId();
    for (final node in [a, b]) {
      final client = SyncthingClient(await node.engineHost!.start());
      final device = await client.request('GET', 'config/devices/$nasId') as Map;
      stdout.writeln('NAS direct address configured: ${(device['addresses'] as List).contains(address)}');
    }
  }
  await _switchNas(root, a, endpoint);
  await _pauseDuringSave(a, endpoint);
  await _storageOutage(a);
  final localId = await a.engineHost!.localDeviceId();
  final current =
      (await api.request('GET', 'config/folders') as List).single as Map;
  await api.request('PATCH', 'config/folders/${current['id']}', {
    'devices': (current['devices'] as List)
        .where((d) => d['deviceID'] != localId)
        .toList(),
  });
  await _roundTrip(a, b);
  final restored =
      (await api.request('GET', 'config/folders') as List).single as Map;
  expect(
    (restored['devices'] as List).map((d) => d['deviceID']),
    contains(localId),
  );
}

Future<void> _roundTrip(AppSyncService a, AppSyncService b) async {
  await a.startAutomatic();
  await b.startAutomatic();
  final now = DateTime.now().toUtc();
  NoteRepository(a.db).insert(
    Note(
      id: 'nas-note',
      kind: NoteKind.text,
      status: NoteStatus.active,
      rawContent: 'from-a-through-nas',
      createdAt: now,
      updatedAt: now,
    ),
  );
  await _waitNote(b, 'from-a-through-nas');
  final repo = NoteRepository(b.db);
  repo.update(
    repo
        .byId('nas-note')!
        .copyWith(
          rawContent: 'edited-on-b',
          updatedAt: now.add(const Duration(seconds: 1)),
        ),
  );
  await _waitNote(a, 'edited-on-b');
  final endpoint = await a.engineHost!.start();
  await a.pause();
  await a.resumeAutomatic();
  await expectLater(a.syncSyncthing(automatic: true), throwsStateError);
  final uri = Uri.parse(endpoint.baseUrl);
  await expectLater(
    Socket.connect(uri.host, uri.port, timeout: const Duration(seconds: 2)),
    throwsA(isA<SocketException>()),
  );
}

Future<void> _waitNote(AppSyncService service, String content) async {
  final until = DateTime.now().add(const Duration(seconds: 50));
  while (DateTime.now().isBefore(until)) {
    if (NoteRepository(service.db).byId('nas-note')?.rawContent == content) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('NAS note not received; ${service.error}; ${service.syncthingMessage}');
}

Future<void> _pauseDuringSave(
  AppSyncService service,
  EngineEndpoint nas,
) async {
  final storage = service.secrets as _Secrets;
  storage.writeStarted = Completer<void>();
  storage.releaseWrite = Completer<void>();
  final saving = service.saveSyncthing(address: nas.baseUrl, apiKey: '');
  await storage.writeStarted!.future;
  final pausing = service.pause();
  storage.releaseWrite!.complete();
  await saving;
  await pausing;
  storage.writeStarted = null;
  storage.releaseWrite = null;
  await service.resumeAutomatic();
  expect(
    (await SharedPreferences.getInstance()).getBool('sync.user.paused'),
    isTrue,
  );
  await expectLater(service.syncSyncthing(automatic: true), throwsStateError);
  await service.syncSyncthing();
}

Future<void> _switchNas(
  Directory root,
  AppSyncService service,
  EngineEndpoint original,
) async {
  final replacement = SyncthingEngineHost(
    home: Directory('${root.path}/replacement'),
    secrets: _Secrets(),
    executable: Platform.environment['SEQPOINT_SYNCTHING_BIN'],
  );
  final storage = service.secrets as _Secrets;
  try {
    final next = await replacement.start();
    await SyncthingClient(next).request('PATCH', 'config/defaults/folder', {
      'path': '${root.path}/replacement-files',
    });
    final oldId = (await SyncthingClient(
      original,
    ).request('GET', 'system/status') as Map)['myID'];
    final nextId = await replacement.localDeviceId();
    storage.failNasWrite = true;
    await expectLater(
      service.saveSyncthing(address: next.baseUrl, apiKey: next.apiKey),
      throwsStateError,
    );
    storage.failNasWrite = false;
    expect(await service.loadSyncthingAddress(), original.baseUrl);
    var local = SyncthingClient(await service.engineHost!.start());
    var folders = await local.request('GET', 'config/folders') as List;
    expect(folders.single['paused'], isTrue);
    await service.syncSyncthing();
    folders = await local.request('GET', 'config/folders') as List;
    var ids = (folders.single['devices'] as List).map((d) => d['deviceID']);
    expect(ids, contains(oldId));
    expect(ids, isNot(contains(nextId)));
    storage.failReadAfterWrite = true;
    await expectLater(service.saveSyncthing(address: next.baseUrl, apiKey: next.apiKey), throwsStateError);
    storage.failReadAfterWrite = false;
    await expectLater(service.syncSyncthing(), throwsStateError);
    expect(service.syncthingEnabled, isFalse);
    final prefs = SharedPreferencesStorePlatform.instance as _Preferences;
    prefs.failCommit = true;
    prefs.failReload = true;
    await expectLater(service.saveSyncthing(address: next.baseUrl, apiKey: next.apiKey), throwsStateError);
    expect(service.syncthingEnabled, isFalse);
    await expectLater(service.syncSyncthing(), throwsStateError);
    prefs.failReload = false;
    await expectLater(service.syncSyncthing(), throwsStateError);
    expect(service.syncthingEnabled, isFalse);
    prefs.failCommit = false;
    await service.saveSyncthing(address: next.baseUrl, apiKey: next.apiKey);
    local = SyncthingClient(await service.engineHost!.start());
    folders = await local.request('GET', 'config/folders') as List;
    ids = (folders.single['devices'] as List).map((d) => d['deviceID']);
    expect(ids, contains(nextId));
    expect(ids, isNot(contains(oldId)));
    await service.saveSyncthing(
      address: original.baseUrl,
      apiKey: original.apiKey,
    );
  } finally {
    storage.failNasWrite = false;
    await replacement.stop();
  }
}

Future<void> _storageOutage(AppSyncService service) async {
  final storage = service.secrets as _Secrets;
  final endpoint = await service.engineHost!.start();
  storage.failNextRead = true;
  await expectLater(service.syncSyncthing(), throwsStateError);
  final uri = Uri.parse(endpoint.baseUrl);
  await expectLater(Socket.connect(uri.host, uri.port,
    timeout: const Duration(seconds: 2)), throwsA(isA<SocketException>()));
  await service.syncSyncthing();
  final resumed = Uri.parse((await service.engineHost!.start()).baseUrl);
  storage.failNextRead = true;
  await service.setSyncthingEnabled(false);
  expect(storage.failNextRead, isTrue);
  storage.failNextRead = false;
  expect(service.syncthingEnabled, isFalse);
  await expectLater(Socket.connect(resumed.host, resumed.port,
    timeout: const Duration(seconds: 2)), throwsA(isA<SocketException>()));
  await expectLater(service.syncSyncthing(), throwsStateError);
  await service.setSyncthingEnabled(true);
}
