import 'dart:convert';

/// 小工具：数据库里以 JSON 文本存放的结构字段。
String? encodeJsonMap(Map<String, Object?>? m) =>
    m == null ? null : jsonEncode(m);

Map<String, Object?>? decodeJsonMap(String? s) {
  if (s == null || s.isEmpty) return null;
  final decoded = jsonDecode(s);
  return decoded is Map<String, Object?> ? decoded : null;
}
