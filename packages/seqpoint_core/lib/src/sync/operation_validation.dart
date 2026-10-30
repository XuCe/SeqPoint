import 'operation.dart';
import 'hlc.dart';

const _invalid = FormatException('同步操作格式错误');
final _deviceSyntax = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// 仅接收已认证writer的四类业务操作，不接受本机状态字段。
void validateIncomingOperation(Operation op, {required String expectedDeviceId}) {
  final fields = Operation.syncFields[op.objectType];
  final marker = op.isTombstone || op.field == Operation.restoreField;
  if (fields == null || (!marker && !fields.contains(op.field)) ||
      _deviceSyntax.firstMatch(expectedDeviceId)?.end != expectedDeviceId.length ||
      op.deviceId != expectedDeviceId || op.hlc.deviceId != expectedDeviceId ||
      op.hlc.millis < 0 || op.hlc.millis > Hlc.maxMillis || op.hlc.counter < 0 ||
      !Operation.validId(op.opId) || !Operation.validId(op.objectId)) {
    throw _invalid;
  }
  if (op.objectType == 'item_tag') {
    final pair = Operation.itemTagIds(op.objectId);
    if ((op.field == 'item_id' && op.value != pair.itemId) ||
        (op.field == 'tag_id' && op.value != pair.tagId)) {
      throw _invalid;
    }
  }
  if (op.objectType == 'attachment' &&
      !RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(op.objectId)) {
    throw _invalid;
  }
  if (marker) {
    if (op.value != true) throw _invalid;
    return;
  }
  if (!_validValue(op.objectType, op.field, op.value)) throw _invalid;
}

bool _validValue(String type, String field, Object? value) => switch ((type, field)) {
  ('attachment', 'media') => const {'image', 'audio'}.contains(value),
  ('attachment', 'note_id' || 'item_id') => value == null || (value is String && Operation.validId(value)),
  ('attachment', 'file_name' || 'mime') => value == null || (value is String && value.length <= 1024),
  ('attachment', 'byte_size') => value is int && value > 0 && value <= 50 * 1024 * 1024,
  ('attachment', 'sha256') => value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value),
  ('attachment', 'manifest_hash') => value == null || (value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value)),
  ('attachment', 'content_owner') => value == null || (value is String && RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)),
  ('note', 'kind') => const {'text', 'meeting'}.contains(value),
  ('note', 'status') => const {'active', 'closed'}.contains(value),
  ('item', 'status') => const {'todo', 'done', 'canceled'}.contains(value),
  ('item', 'priority') => const {'p0', 'p1', 'p2', 'p3', 'p4'}.contains(value),
  ('item', 'source') => const {'manual', 'ai'}.contains(value),
  ('tag', 'kind') => const {'project', 'type', 'custom'}.contains(value),
  (_, 'pinned' || 'builtin') => value is int && (value == 0 || value == 1),
  ('note', 'title' || 'color') || ('tag', 'color') => value == null || value is String,
  ('note', 'raw_content') || ('item', 'title') || ('tag', 'name') => value is String,
  (_, 'created_at' || 'updated_at') => _utcDate(value),
  (_, 'closed_at' || 'deleted_at' || 'due_at' || 'completed_at') => value == null || _utcDate(value),
  ('item', 'note_id') => value == null || (value is String && Operation.validId(value)),
  ('item', 'line_index') => value == null || (value is int && value >= 0),
  ('tag', 'sort') => value is int,
  ('item_tag', 'item_id' || 'tag_id') => value is String && Operation.validId(value),
  ('item_tag', 'present') => value == true,
  _ => false,
};

bool _utcDate(Object? value) {
  if (value is! String || value.length > 32) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null && parsed.isUtc && value == parsed.toIso8601String();
}
