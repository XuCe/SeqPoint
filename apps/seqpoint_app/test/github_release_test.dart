import 'dart:ffi';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/updates/github_release.dart';

Map<String, dynamic> release({String tag = 'v0.2.0'}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': false,
  'body': '新增同步功能',
  'assets': [
    for (final suffix in [
      'android.apk',
      'macos-arm64.dmg',
      'windows-x64-setup.exe',
      'appcast-macos.xml',
      'appcast-windows.xml',
      'ios-unsigned.xcarchive.zip',
    ])
      {
        'name': 'seqpoint-$tag-$suffix',
        'state': 'uploaded',
        'size': 100,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url':
            'https://github.com/XuCe/SeqPoint/releases/download/$tag/seqpoint-$tag-$suffix',
      },
  ],
};

class TestClient extends Fake implements HttpClient {
  TestClient(this.address);
  final Uri address;
  final inner = HttpClient();
  bool closed = false;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    expect(
      url.toString(),
      'https://api.github.com/repos/XuCe/SeqPoint/releases/latest',
    );
    return inner.getUrl(address);
  }

  @override
  void close({bool force = false}) {
    closed = true;
    inner.close(force: force);
  }
}

void main() {
  test('rejects previews, drafts and malformed releases', () {
    for (final json in [
      {...release(), 'draft': true},
      {...release(), 'prerelease': true},
      release(tag: 'v0.2.0-preview'),
      release(tag: '../../bad'),
      {...release(), 'assets': null},
      {...release(), 'body': []},
    ]) {
      expect(
        () => FullRelease.fromJson(json, Abi.windowsX64),
        throwsFormatException,
      );
    }
  });
  test(
    'never offers missing, duplicate, incomplete or off-repo installers',
    () {
      final original = (release()['assets'] as List)[2] as Map;
      for (final assets in [
        [],
        [original, original],
        [
          {...original, 'state': 'new'},
        ],
        [
          {...original, 'size': 0},
        ],
        [
          {...original, 'browser_download_url': 'https://example.com/app.zip'},
        ],
        [
          {...original, 'browser_download_url': 'file:///tmp/app.zip'},
        ],
        [
          {
            ...original,
            'browser_download_url':
                '${original['browser_download_url']}?token=abc',
          },
        ],
      ]) {
        expect(
          FullRelease.fromJson({
            ...release(),
            'assets': assets,
          }, Abi.windowsX64).downloadUrl,
          isNull,
        );
      }
    },
  );
  for (final code in [302, 403, 404, 429, 500, 200]) {
    test(
      'invalid HTTP response $code fails without reporting latest',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.statusCode = code;
          request.response.write('not-json');
          await request.response.close();
        });
        final client = TestClient(Uri.parse('http://127.0.0.1:${server.port}'));
        await expectLater(fetchLatestRelease(client: client), throwsException);
        expect(client.closed, isTrue);
      },
    );
  }

  test(
    'fetches the public stable release and closes its HTTP client',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        expect(request.headers.value('Authorization'), isNull);
        request.response.write(jsonEncode(release()));
        await request.response.close();
      });
      final client = TestClient(Uri.parse('http://127.0.0.1:${server.port}'));
      final result = await fetchLatestRelease(
        client: client,
        abi: Abi.windowsX64,
      );
      expect(result.version.toString(), '0.2.0');
      expect(client.closed, isTrue);
    },
  );
  test('compares semantic versions without mistaking patches for releases', () {
    final update = FullRelease.fromJson(
      release(tag: 'v0.10.0'),
      Abi.windowsX64,
    );
    expect(update.isNewerThan('0.9.0+99'), isTrue);
    expect(update.isNewerThan('0.10.0+1'), isFalse);
    expect(update.isNewerThan('0.11.0'), isFalse);
    expect(update.isNewerThan('0.10.0-beta.1'), isTrue);
    expect(update.notes, '新增同步功能');
    expect(update.sha256, 'a' * 64);
    expect(update.appcastUrl.toString(), endsWith('-appcast-windows.xml'));
  });
  test('selects only the current architecture installer; iOS has none', () {
    for (final pair in {
      Abi.androidArm64: 'android.apk',
      Abi.androidArm: 'android.apk',
      Abi.macosArm64: 'macos-arm64.dmg',
      Abi.windowsX64: 'windows-x64-setup.exe',
    }.entries) {
      expect(
        FullRelease.fromJson(release(), pair.key).downloadUrl.toString(),
        endsWith(pair.value),
      );
    }
    for (final abi in [
      Abi.iosArm64,
      Abi.macosX64,
      Abi.androidX64,
      Abi.linuxX64,
      Abi.linuxArm64,
    ]) {
      expect(FullRelease.fromJson(release(), abi).downloadUrl, isNull);
    }
  });
}
