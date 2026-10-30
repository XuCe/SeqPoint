import 'dart:convert';
import '../db/database.dart';
import '../util/clock.dart';
import 'operation.dart';
import 'operation_validation.dart';

/// 仅保存已验签解密的操作事实；投影/水位由上层同一事务完成后再ACK。
class SyncInbox {
  SyncInbox(this._db, {Clock clock = const SystemClock()}) : _clock = clock;
  final SeqDatabase _db;
  final Clock _clock;
  static const maxFutureSkew = Duration(minutes: 5);

  int storeVerifiedBatch({required String peerId, required List<Operation> operations}) {
    if (operations.isEmpty) return 0;
    if (operations.length > 500) throw const FormatException('同步批次过大');
    final ceiling = _clock.now().millisecondsSinceEpoch + maxFutureSkew.inMilliseconds;
    for (final op in operations) {
      validateIncomingOperation(op, expectedDeviceId: peerId);
      if (op.hlc.millis > ceiling) {
        throw const FormatException('远端操作时钟超前，已拒绝本批数据');
      }
    }
    try {
      return _db.transaction(() {
        final state = _db.raw.select('SELECT * FROM sync_local WHERE id = 1').single;
        if (state['enabled'] != 1 || state['requires_new_identity'] != 0 ||
            state['device_id'] is! String || state['device_id'] == peerId) {
          throw StateError('同步接收尚未启用');
        }
        var added = 0;
        for (final op in operations) {
          final prior = _db.raw.select('SELECT * FROM sync_operations WHERE op_id = ?', [op.opId]);
          if (prior.isNotEmpty) {
            if (!_same(prior.single, op)) throw StateError('操作身份冲突');
            continue;
          }
          _db.raw.execute('INSERT INTO sync_operations '
              '(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
              "VALUES (?,?,?,?,?,?,?,?,'remote')", [op.opId, op.deviceId,
                op.hlc.millis, op.hlc.counter, op.objectType, op.objectId, op.field, jsonEncode(op.value)]);
          added++;
        }
        _observe(operations);
        return added;
      });
    } catch (_) {
      throw StateError('无法保存同步操作，未应用本批数据');
    }
  }

  bool _same(Map<String, Object?> row, Operation op) =>
      row['device_id'] == op.deviceId && row['hlc_millis'] == op.hlc.millis &&
      row['hlc_counter'] == op.hlc.counter && row['object_type'] == op.objectType &&
      row['object_id'] == op.objectId && row['field'] == op.field &&
      row['value_json'] == jsonEncode(op.value);

  void _observe(List<Operation> operations) {
    final current = _db.raw.select('SELECT hlc_millis,hlc_counter FROM sync_local WHERE id = 1').single;
    var millis = current['hlc_millis'] as int, counter = current['hlc_counter'] as int;
    for (final op in operations) {
      if (op.hlc.millis > millis || (op.hlc.millis == millis && op.hlc.counter > counter)) {
        millis = op.hlc.millis;
        counter = op.hlc.counter;
      }
    }
    if (millis != current['hlc_millis'] || counter != current['hlc_counter']) {
      _db.raw.execute('UPDATE sync_local SET hlc_millis = ?, hlc_counter = ? WHERE id = 1',
          [millis, counter]);
    }
  }
}
