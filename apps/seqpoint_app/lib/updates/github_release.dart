import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

final class FullRelease {
  FullRelease._(
    this.version,
    this.notes,
    this.releaseUrl,
    this.downloadUrl,
    this.sha256,
    this.appcastUrl,
  );
  final Version version;
  final String notes;
  final Uri releaseUrl;
  final Uri? downloadUrl;
  final String? sha256;
  final Uri? appcastUrl;

  bool isNewerThan(String installed) =>
      version > Version.parse(installed.split('+').first);

  factory FullRelease.fromJson(Map<String, dynamic> json, Abi abi) {
    final tag = json['tag_name'];
    if (json['draft'] != false ||
        json['prerelease'] != false ||
        tag is! String ||
        !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag) ||
        json['assets'] is! List ||
        (json['body'] != null && json['body'] is! String)) {
      throw const FormatException('Invalid stable release');
    }
    final version = Version.parse(tag.substring(1));
    final page = Uri.https('github.com', '/XuCe/SeqPoint/releases/tag/$tag');
    final suffix = {
      Abi.androidArm: 'android.apk',
      Abi.androidArm64: 'android.apk',
      Abi.macosArm64: 'macos-arm64.dmg',
      Abi.windowsX64: 'windows-x64-setup.exe',
    }[abi];
    final name = 'seqpoint-$tag-$suffix';
    final expected = Uri.https(
      'github.com',
      '/XuCe/SeqPoint/releases/download/$tag/$name',
    );
    final matches = (json['assets'] as List).where(
      (asset) =>
          asset is Map &&
          asset['name'] == name &&
          asset['state'] == 'uploaded' &&
          asset['size'] is int &&
          (asset['size'] as int) > 0 &&
          asset['browser_download_url'] == expected.toString(),
    );
    final digest = matches.length == 1
        ? (matches.single as Map)['digest']
        : null;
    final sha =
        digest is String && RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(digest)
        ? digest.substring(7)
        : null;
    final feedSuffix = {
      Abi.macosArm64: 'appcast-macos.xml',
      Abi.windowsX64: 'appcast-windows.xml',
    }[abi];
    final feedName = 'seqpoint-$tag-$feedSuffix';
    final feed = Uri.https(
      'github.com',
      '/XuCe/SeqPoint/releases/download/$tag/$feedName',
    );
    final feeds = (json['assets'] as List).where(
      (asset) =>
          asset is Map &&
          asset['name'] == feedName &&
          asset['state'] == 'uploaded' &&
          asset['size'] is int &&
          (asset['size'] as int) > 0 &&
          asset['browser_download_url'] == feed.toString(),
    );
    final appcast = feedSuffix != null && feeds.length == 1 ? feed : null;
    return FullRelease._(
      version,
      json['body'] as String? ?? '',
      page,
      suffix != null && sha != null && (feedSuffix == null || appcast != null)
          ? expected
          : null,
      sha,
      appcast,
    );
  }
}

Future<FullRelease> fetchLatestRelease({HttpClient? client, Abi? abi}) async {
  final http = client ?? HttpClient();
  Future<FullRelease> read() async {
    final request = await http.getUrl(
      Uri.https('api.github.com', '/repos/XuCe/SeqPoint/releases/latest'),
    );
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'SeqPoint');
    request.headers.set('X-GitHub-Api-Version', '2026-03-10');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('GitHub HTTP ${response.statusCode}');
    }
    const limit = 512 * 1024;
    if (response.contentLength > limit) {
      throw const FormatException('Release response too large');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > limit) {
        throw const FormatException('Release response too large');
      }
      bytes.addAll(chunk);
    }
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Invalid release response');
    }
    return FullRelease.fromJson(json, abi ?? Abi.current());
  }

  try {
    return await read().timeout(const Duration(seconds: 15));
  } finally {
    http.close(force: true);
  }
}
