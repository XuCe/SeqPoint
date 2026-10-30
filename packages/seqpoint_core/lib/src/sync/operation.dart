import 'dart:convert';
import 'hlc.dart';

typedef SyncObjectKey = ({String type, String id});

/// 一次字段写入。同步的最小单位。
///
/// 正式版本在此基础上加设备签名与应用层加密（见 vault/segment.dart），
/// 字段名保持不变。
class Operation {
  const Operation({
    required this.opId,
    required this.deviceId,
    required this.hlc,
    required this.objectType,
    required this.objectId,
    required this.field,
    required this.value,
  });

  final String opId;
  final String deviceId;
  final Hlc hlc;

  /// 'note' | 'item' | 'tag' | 'item_tag' | 'reminder' | 'secret'
  final String objectType;
  final String objectId;
  SyncObjectKey get objectKey => (type: objectType, id: objectId);

  /// 字段名。特殊值 '__tombstone__' 表示删除整个对象。
  final String field;
  final Object? value;

  bool get isTombstone => field == tombstoneField;
  static const tombstoneField = '__tombstone__';
  static const restoreField = '__restore__';
  static const Map<String, Set<String>> syncFields = {
    'note': {'kind', 'title', 'raw_content', 'status', 'color', 'pinned',
      'created_at', 'updated_at', 'closed_at', 'deleted_at'},
    'item': {'note_id', 'line_index', 'title', 'status', 'priority', 'source',
      'due_at', 'completed_at', 'created_at', 'updated_at', 'deleted_at'},
    'tag': {'name', 'kind', 'builtin', 'color', 'sort'},
    'item_tag': {'item_id', 'tag_id', 'present'},
    'attachment': {'note_id', 'item_id', 'media', 'file_name', 'mime',
      'byte_size', 'sha256', 'created_at', 'deleted_at', 'content_owner', 'manifest_hash'},
  };

  /// 无分隔符歧义的关联对象键；删除先到时也能还原双方业务ID。
  static String itemTagId(String itemId, String tagId) =>
      base64UrlEncode(utf8.encode(jsonEncode([itemId, tagId]))).replaceAll('=', '');

  static final _idSyntax = RegExp(r'^[A-Za-z0-9_:-]{1,256}$');
  static bool validId(String value) => _idSyntax.firstMatch(value)?.end == value.length;

  static ({String itemId, String tagId}) itemTagIds(String id) {
    try {
      if (id.length > 256) throw const FormatException();
      final pair = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(id))));
      if (pair is! List || pair.length != 2 || pair[0] is! String || pair[1] is! String) {
        throw const FormatException();
      }
      final itemId = pair[0] as String, tagId = pair[1] as String;
      if (!validId(itemId) || !validId(tagId) || itemTagId(itemId, tagId) != id) {
        throw const FormatException();
      }
      return (itemId: itemId, tagId: tagId);
    } catch (_) {
      throw const FormatException('同步关联标识格式错误');
    }
  }

  Map<String, Object?> toJson() => {
        'op_id': opId,
        'device_id': deviceId,
        'hlc': hlc.toString(),
        'object_type': objectType,
        'object_id': objectId,
        'field': field,
        'value': value,
      };

  factory Operation.fromJson(Map<String, Object?> j) => Operation(
        opId: j['op_id'] as String,
        deviceId: j['device_id'] as String,
        hlc: Hlc.parse(j['hlc'] as String),
        objectType: j['object_type'] as String,
        objectId: j['object_id'] as String,
        field: j['field'] as String,
        value: j['value'],
      );
}
