import 'dart:convert';

enum PairingCodeKind { invitation, response, confirmation, grant }

const _maxCodeLength = 131072;

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 32) throw const FormatException('配对码嵌套过深');
  if (value == null || value is String || value is bool || value is int) {
    return value;
  }
  if (value is List) return value.map((item) => _canonical(item, depth + 1)).toList();
  if (value is Map && value.keys.every((key) => key is String)) {
    final object = Map<String, Object?>.from(value);
    return {for (final key in object.keys.toList()..sort())
      key: _canonical(object[key], depth + 1)};
  }
  throw const FormatException('配对码格式不正确');
}

String encodePairingCode(PairingCodeKind kind, Map<String, Object?> payload) {
  final body = base64UrlEncode(utf8.encode(jsonEncode(_canonical(payload))))
      .replaceAll('=', '');
  final result = 'seqpoint-pair-v1:${kind.name}:$body';
  if (result.length > _maxCodeLength) {
    throw const FormatException('配对码过长');
  }
  return result;
}

Map<String, Object?> decodePairingCode(String code, PairingCodeKind kind) {
  final value = code.trim(), prefix = 'seqpoint-pair-v1:${kind.name}:';
  if (code.length > _maxCodeLength || !value.startsWith(prefix)) {
    throw const FormatException('配对码用途不符或过长');
  }
  final body = value.substring(prefix.length);
  if (body.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(body)) {
    throw const FormatException('配对码格式不正确');
  }
  final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(body))));
  if (decoded is! Map<String, Object?> || encodePairingCode(kind, decoded) != value) {
    throw const FormatException('配对码格式不正确');
  }
  return decoded;
}
