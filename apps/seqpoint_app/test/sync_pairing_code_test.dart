import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/sync/sync_pairing_code.dart';

void main() {
  test('配对码严格绑定用途并保留嵌套数据', () {
    final payload = <String, Object?>{'z': 1, 'a': {'b': '设备'}, 'empty': {}};
    final code = encodePairingCode(PairingCodeKind.invitation, payload);
    expect(decodePairingCode(code, PairingCodeKind.invitation), payload);
    expect(() => decodePairingCode(code, PairingCodeKind.response),
        throwsFormatException);
    expect(code, isNot(contains('设备')));
  });
  test('非规范、过长和格式损坏的配对码被拒绝', () {
    String wrap(String value) => 'seqpoint-pair-v1:invitation:'
        '${base64UrlEncode(utf8.encode(value)).replaceAll('=', '')}';
    for (final code in [wrap('{ "a":1}'), wrap('{"b":2,"a":1}'),
      wrap('{"a":1,"a":2}'), wrap('[]'), wrap('{"a":1.0}'),
      'seqpoint-pair-v1:invitation:***', 'x' * 131073]) {
      expect(() => decodePairingCode(code, PairingCodeKind.invitation),
          throwsFormatException);
    }
  });
  test('限制嵌套深度，拒绝递归耗尽', () {
    final nested = '${'[' * 80}0${']' * 80}';
    final body = base64UrlEncode(utf8.encode('{"a":$nested}')).replaceAll('=', '');
    expect(() => decodePairingCode('seqpoint-pair-v1:grant:$body', PairingCodeKind.grant),
      throwsFormatException);
  });
}
