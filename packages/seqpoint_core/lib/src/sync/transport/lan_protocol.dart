import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/dart.dart';

import '../../identity/device_keys.dart';
import '../../identity/member_keys.dart';

/// Pure synchronous lookup in the current verified reducer; never performs I/O.
typedef LanAuthorization = MemberKeys? Function(
  String vaultPublicId,
  String deviceId,
);

String lanSha256(List<int> bytes) => const DartSha256()
    .hashSync(bytes)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

class LanLimits {
  LanLimits({
    this.maxFileBytes = 12 * 1024 * 1024,
    this.maxListBytes = 256 * 1024,
    this.maxFiles = 1024,
    this.timeout = const Duration(seconds: 5),
  }) {
    if (maxFileBytes < 1 ||
        maxFileBytes > 12 * 1024 * 1024 ||
        maxListBytes < 1 ||
        maxListBytes > 256 * 1024 ||
        maxFiles < 1 ||
        maxFiles > 1024 ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 30)) {
      throw ArgumentError('Invalid LAN transfer limits');
    }
  }
  final int maxFileBytes, maxListBytes, maxFiles;
  final Duration timeout;
  static const maxRequestBytes = 4096;
}

MemberKeys lanMember(LanAuthorization authorize, String vault, String device) {
  final member = authorize(vault, device);
  if (member == null || member.deviceId != device) {
    throw StateError('LAN member is not currently authorized');
  }
  final identity = base64UrlEncode(
    const DartSha256().hashSync(member.signingPublicKey).bytes,
  ).replaceAll('=', '');
  if (identity != device) throw StateError('LAN member identity changed');
  return member;
}

/// After every asynchronous check, compare all public material without yielding.
void lanCheckMembers(
  LanAuthorization authorize,
  String vault,
  Iterable<MemberKeys> expected,
) {
  for (final member in expected) {
    final current = lanMember(authorize, vault, member.deviceId);
    if (jsonEncode(current.toJson()) != jsonEncode(member.toJson())) {
      throw StateError('LAN member authorization changed');
    }
  }
}

class LanRequest {
  LanRequest(this.fields, this.signature);
  final List<Object> fields;
  final List<int> signature;
  String get sender => fields[1] as String;
  String get nonce => fields[5] as String;
  String get action => fields[6] as String;
  String get path => fields[7] as String;
  int get millis => fields[4] as int;
  List<int> get message =>
      utf8.encode(jsonEncode(['seqpoint-lan-v1', ...fields]));
  List<int> get bytes =>
      utf8.encode(jsonEncode([...fields, base64UrlEncode(signature)]));

  static Future<LanRequest> create({
    required DeviceKeys keys,
    required String vault,
    required String target,
    required String pin,
    required String action,
    required String path,
  }) async {
    final random = Random.secure();
    final fields = <Object>[
      vault,
      keys.deviceId,
      target,
      pin,
      DateTime.now().millisecondsSinceEpoch,
      base64UrlEncode(List.generate(32, (_) => random.nextInt(256))),
      action,
      path,
    ];
    final request = LanRequest(fields, const []);
    return LanRequest(fields, await keys.signer.sign(request.message));
  }

  static LanRequest decode(List<int> bytes) {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! List ||
        value.length != 9 ||
        value[4] is! int ||
        [0, 1, 2, 3, 5, 6, 7, 8].any((i) => value[i] is! String) ||
        (value[5] as String).length != 44 ||
        base64Url.decode(value[5] as String).length != 32) {
      throw const FormatException('Invalid LAN request');
    }
    return LanRequest(
      List<Object>.from(value.take(8)),
      base64Url.decode(value[8] as String),
    );
  }
}

bool lanOwnedPath(String path, String owner, {bool directory = false}) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(owner) || path.length > 256) {
    return false;
  }
  if (directory) {
    return {'ops/$owner', 'members', 'acks', 'snapshots','checkpoints/$owner','content/$owner'}.contains(path);
  }
  if(RegExp('^checkpoints/$owner/[A-Za-z0-9_-]{43}\\.json\$').hasMatch(path) ||
      RegExp('^content/$owner/[a-f0-9]{64}\\.(bin|json)\$').hasMatch(path)) { return true; }
  if (path == 'members/$owner.json' || path == 'acks/$owner.json') return true;
  if (path.startsWith('ops/$owner/')) {
    return RegExp(r'^[0-9]{4}(0[1-9]|1[0-2])-[0-9]{4,}\.log$')
            .firstMatch(path.substring(48))
            ?.end ==
        path.length - 48;
  }
  return RegExp('^snapshots/$owner-[1-9][0-9]*\\.snap\$')
          .firstMatch(path)
          ?.end ==
      path.length;
}

List<int> lanResponseMessage(List<int> request, List<int> response) =>
    utf8.encode(
      jsonEncode([
        'seqpoint-lan-response-v1',
        lanSha256(request),
        lanSha256(response),
      ]),
    );

Future<List<int>> lanReadBounded(
  Stream<List<int>> stream,
  int limit,
  Duration timeout,
) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(timeout)) {
    if (bytes.length + chunk.length > limit) {
      throw StateError('LAN body too large');
    }
    bytes.addAll(chunk);
  }
  return bytes;
}
