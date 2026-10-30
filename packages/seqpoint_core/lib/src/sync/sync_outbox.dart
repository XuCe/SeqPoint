import 'dart:convert';
import '../db/database.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import 'hlc.dart';
import 'operation.dart';
import 'operation_validation.dart';

/// 仓储调用时按对象读前后值；业务与操作日志共享同一SAVEPOINT。
class SyncOutbox {
  SyncOutbox(this._db, {Clock clock = const SystemClock()}) : _clock = clock;
  final SeqDatabase _db;
  final Clock _clock;

  T capture<T>(String objectType, String objectId, {
    required Map<String, Object?>? Function() read,
    required T Function() write,
  }) => _db.transaction(() {
    if (_db.syncCaptureSuppressed) return write();
    final state = _db.raw.select('SELECT * FROM sync_local WHERE id = 1').single;
    if (state['enabled'] == 0) return write();
    if (!Operation.syncFields.containsKey(objectType) || !Operation.validId(objectId) ||
        state['device_id'] is! String || state['requires_new_identity'] != 0) {
      throw StateError('同步写入状态无效');
    }
    final before = read();
    final result = write();
    _recordChanges(objectType, objectId, before, read(), state, _clock.now());
    return result;
  });

  /// 由首次基线事务调用；不伪造业务写回调，不在已完成基线后重复造创建。
  int recordInitialSnapshot(String type, String id, Map<String, Object?> row) {
    final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
    if (_db.raw.autocommit || state['enabled'] != 1 || state['baseline_ready'] != 0 ||
        state['requires_new_identity'] != 0 || state['device_id'] is! String ||
        !Operation.validId(id) || !Operation.syncFields.containsKey(type) ||
        !Operation.syncFields[type]!.every(row.containsKey)) {
      throw StateError('初始快照状态或对象无效');
    }
    final ops = _recordChanges(type, id, null, row, state, _clock.now());
    for (final op in ops) { validateIncomingOperation(op, expectedDeviceId: state['device_id'] as String); }
    return ops.length;
  }

  List<Operation> _recordChanges(String type, String id, Map<String, Object?>? before,
      Map<String, Object?>? after, Map<String, Object?> state, DateTime now) {
    if (before == null && after == null) return const [];
    final changes = <String, Object?>{};
    if (after == null) {
      changes[Operation.tombstoneField] = true;
    } else {
      if (after['deleted_at'] == null &&
          (before == null || before['deleted_at'] != null)) {
        changes[Operation.restoreField] = true;
      }
      for (final field in Operation.syncFields[type]!) {
        final value = after[field];
        if (before != null && before[field] == value) continue;
        changes[field] = field.endsWith('_at') && value is String
            ? DateTime.parse(value).toUtc().toIso8601String() : value;
      }
      if (after['deleted_at'] != null && before?['deleted_at'] == null) {
        changes[Operation.tombstoneField] = true;
      }
    }
    return changes.isNotEmpty ? _append(type, id, changes, state, now) : const [];
  }

  List<Operation> _append(String type, String id, Map<String, Object?> changes,
      Map<String, Object?> state, DateTime now) {
    final current = _db.raw.select('SELECT * FROM sync_local WHERE id = 1').single;
    if (current['device_id'] != state['device_id'] || current['enabled'] != 1 ||
        current['requires_new_identity'] != 0) {
      throw StateError('事务中的同步写入身份已变化');
    }
    var last = Hlc(millis: current['hlc_millis'] as int,
        counter: current['hlc_counter'] as int, deviceId: current['device_id'] as String);
    final result = <Operation>[];
    for (final change in changes.entries) {
      last = Hlc.now(last.deviceId, last: last, at: now);
      final op = Operation(opId: newId(), deviceId: last.deviceId, hlc: last,
          objectType: type, objectId: id, field: change.key, value: change.value);
      result.add(op);
      _db.raw.execute('INSERT INTO sync_operations '
          '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
          "VALUES (?,?,?,?,?,?,?,?,'local')", [op.opId, state['device_id'],
            last.millis, last.counter, type, id, change.key, jsonEncode(change.value)]);
    }
    _db.raw.execute('UPDATE sync_local SET hlc_millis = ?, hlc_counter = ? WHERE id = 1',
        [last.millis, last.counter]);
    return result;
  }
}
