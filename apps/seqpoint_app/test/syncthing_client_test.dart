import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/syncthing_client.dart';
import 'package:seqpoint_platform/seqpoint_platform.dart';

void main() {
  test(
    'a later authorization check repairs an interleaved folder overwrite',
    () async {
      final fixture = _NasApi()..racing = true;
      final client = await fixture.start();
      final second = List.filled(8, 'CCCCCCC').join('-');
      Future<void> reconcile() async {
        await Future.wait([
          for (final id in [fixture.peerId, second])
            client.shareVault(localDeviceId: id, folderId: fixture.folderId),
        ]);
      }

      try {
        await reconcile();
        expect(fixture.folders.last['devices'], hasLength(2));
        await reconcile();
        expect(
          (fixture.folders.last['devices'] as List)
              .map((d) => d['deviceID'])
              .toSet(),
          {fixture.nasId, fixture.peerId, second},
        );
      } finally {
        await fixture.server.close(force: true);
      }
    },
  );
  test(
    'NAS provisioning is scoped, idempotent and checks pinned identity',
    () async {
      final fixture = _NasApi();
      final client = await fixture.start();
      try {
        final result = await client.shareVault(
          localDeviceId: fixture.peerId,
          folderId: fixture.folderId,
        );
        expect(result.deviceId, fixture.nasId);
        expect(fixture.devices.single['deviceID'], fixture.peerId);
        expect(fixture.devices.single['autoAcceptFolders'], isFalse);
        final folder = fixture.folders.last;
        expect(folder['path'], '/data/SeqPoint/${fixture.folderId}');
        expect(
          (folder['devices'] as List).map((d) => d['deviceID']),
          contains(fixture.peerId),
        );
        expect(fixture.folders.first, {
          'id': 'unrelated',
          'path': '/private',
          'devices': [],
          'paused': true,
        });
        final writes = fixture.writes;
        await client.shareVault(
          localDeviceId: fixture.peerId,
          folderId: fixture.folderId,
          expectedNasId: fixture.nasId,
        );
        expect(fixture.writes, writes);
        final otherId = List.filled(8, 'CCCCCCC').join('-');
        fixture.folders.last['rescanIntervalS'] = 321;
        await client.shareVault(
          localDeviceId: otherId,
          folderId: fixture.folderId,
          expectedNasId: fixture.nasId,
        );
        expect(
          (fixture.folders.last['devices'] as List)
              .map((d) => d['deviceID'])
              .toSet(),
          {fixture.nasId, fixture.peerId, otherId},
        );
        expect(fixture.folders.last['rescanIntervalS'], 321);
        await expectLater(
          client.shareVault(
            localDeviceId: fixture.peerId,
            folderId: fixture.folderId,
            expectedNasId: fixture.peerId,
          ),
          throwsStateError,
        );
        expect(fixture.writes, writes + 2);
      } finally {
        await fixture.server.close(force: true);
      }
    },
  );
  test('NAS address defaults to HTTPS and refuses exposed cleartext keys', () {
    expect(
      SyncthingClient.parseAddress('http://[::1]:8384'),
      'http://[::1]:8384',
    );
    expect(
      SyncthingClient.parseAddress('http://[fd00::1]:8384'),
      'http://[fd00::1]:8384',
    );
    expect(
      SyncthingClient.parseAddress('nas.catorg.cc:8384'),
      'https://nas.catorg.cc:8384',
    );
    expect(
      SyncthingClient.parseAddress('http://192.168.1.2:8384/'),
      'http://192.168.1.2:8384',
    );
    for (final input in [
      'http://nas.catorg.cc:8384',
      'http://8.8.8.8:8384',
      'https://user:key@nas.catorg.cc',
      'https://nas.catorg.cc/rest',
      'https://nas.catorg.cc/?key=secret',
      'ftp://nas.catorg.cc',
      'nas.catorg.cc:99999',
    ]) {
      expect(() => SyncthingClient.parseAddress(input), throwsFormatException);
    }
  });
  test(
    'HTTP errors do not reveal keys and redirects never forward them',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      var status = HttpStatus.temporaryRedirect;
      server.listen((request) async {
        requests++;
        request.response.statusCode = status;
        request.response.headers.set('location', '/stolen');
        request.response.write('private-key-value');
        await request.response.close();
      });
      try {
        final client = SyncthingClient(
          EngineEndpoint(
            baseUrl: 'http://127.0.0.1:${server.port}',
            apiKey: 'private-key-value',
          ),
        );
        await expectLater(
          client.request('GET', 'system/status'),
          throwsA(
            predicate(
              (e) => e is StateError && !'$e'.contains('private-key-value'),
            ),
          ),
        );
        expect(requests, 1);
        status = HttpStatus.ok;
        await expectLater(
          client.request('GET', 'system/status'),
          throwsA(
            predicate(
              (e) => e is StateError && !'$e'.contains('private-key-value'),
            ),
          ),
        );
      } finally {
        await server.close(force: true);
      }
    },
  );
}

class _NasApi {
  final nasId = List.filled(8, 'AAAAAAA').join('-');
  final peerId = List.filled(8, 'BBBBBBB').join('-');
  final folderId = 'seqpoint-${'a' * 64}';
  final folders = <Map<String, dynamic>>[
    {'id': 'unrelated', 'path': '/private', 'devices': [], 'paused': true},
  ];
  final devices = <Map<String, dynamic>>[];
  late HttpServer server;
  int writes = 0;
  bool racing = false;
  int folderReads = 0;
  final _bothRead = Completer<void>();
  Future<SyncthingClient> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_serve);
    return SyncthingClient(
      EngineEndpoint(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'test-nas-key',
      ),
    );
  }

  Future<void> _serve(HttpRequest request) async {
    if (request.headers.value('X-API-Key') != 'test-nas-key') {
      request.response.statusCode = 403;
    } else {
      final path = request.uri.path.substring('/rest/'.length);
      final bytes = await utf8.decoder.bind(request).join();
      final body = bytes.isEmpty
          ? null
          : jsonDecode(bytes) as Map<String, dynamic>;
      var response = _route(request.method, path, body);
      if (racing && request.method == 'GET' && path == 'config/folders') {
        response = jsonDecode(jsonEncode(response));
        if (++folderReads == 2) {
          racing = false;
          _bothRead.complete();
        }
        await _bothRead.future;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
    }
    await request.response.close();
  }

  dynamic _route(String method, String path, Map<String, dynamic>? body) {
    if (method == 'GET') {
      return switch (path) {
        'system/status' => {
          'myID': nasId,
          'tilde': '/data',
          'pathSeparator': '/',
          'connectionServiceStatus': <String, dynamic>{},
        },
        'config/devices' => devices,
        'config/folders' => folders,
        'config/defaults/device' => {
          'addresses': ['dynamic'],
          'autoAcceptFolders': false,
        },
        'config/defaults/folder' => {
          'path': '/data',
          'devices': [],
          'rescanIntervalS': 60,
        },
        _ => throw StateError('Unexpected test route $path'),
      };
    }
    writes++;
    final list = path.startsWith('config/devices/') ? devices : folders;
    final field = path.startsWith('config/devices/') ? 'deviceID' : 'id';
    final id = path.split('/').last;
    final index = list.indexWhere((v) => v[field] == id);
    if (index < 0) {
      list.add({...body!, field: id});
    } else {
      list[index] = method == 'PATCH' ? {...list[index], ...body!} : body!;
    }
    return null;
  }
}
