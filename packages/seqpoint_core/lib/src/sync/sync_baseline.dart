import '../db/database.dart';
import '../util/clock.dart';
import 'operation.dart';
import 'sync_outbox.dart';
import 'sync_projector.dart';

/// 首次存量基线与启用原子提交；不承担重新配对或清理旧历史。
class SyncBaseline {
  SyncBaseline(this._db, {Clock clock = const SystemClock()}) : _clock = clock;
  final SeqDatabase _db;
  final Clock _clock;

  int initialize(String deviceId) => _initialize(deviceId);

  /// 调用方须先安全保存新身份和已确认配对；previous只能来自旧安全记录。
  int initializeRestored(String newDeviceId, {required String previousDeviceId}) {
    if (RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(previousDeviceId)?.end != previousDeviceId.length ||
        previousDeviceId == newDeviceId) {
      throw StateError('恢复后必须使用不同的安全设备身份');
    }
    return _initialize(newDeviceId, previousDeviceId: previousDeviceId);
  }

  int _initialize(String deviceId, {String? previousDeviceId}) {
    if (!_db.raw.autocommit || RegExp(r'^[A-Za-z0-9_-]{1,128}$').firstMatch(deviceId)?.end != deviceId.length) {
      throw StateError('基线身份或事务状态无效');
    }
    try {
      return _db.transaction<int>(() {
        _db.raw.execute('UPDATE sync_local SET id=id WHERE id=1'); // 先取得写锁再冻结业务行。
        final state = _db.raw.select('SELECT * FROM sync_local WHERE id=1').single;
        if (previousDeviceId != null) {
          if (state['requires_new_identity'] != 1 || state['enabled'] != 0 ||
              state['baseline_ready'] != 0 ||
              (state['device_id'] != null && state['device_id'] != previousDeviceId)) {
            throw StateError('不是可提交新身份的恢复状态');
          }
        } else if (state['requires_new_identity'] != 0 || (state['device_id'] != null && state['device_id'] != deviceId)) {
          throw StateError('需要先完成新身份配置');
        }
        if (state['baseline_ready'] == 1 && state['enabled'] == 1) return 0;
        if (state['baseline_ready'] != 0 || state['enabled'] != 0) throw StateError('不能静默重新建立基线');
        for (final table in ['sync_operations', 'sync_publications', 'sync_received_segments', 'sync_checkpoints', 'sync_checkpoint_staging']) {
          if (_db.raw.select('SELECT 1 FROM $table LIMIT 1').isNotEmpty) throw StateError('已有同步历史');
        }
        if (_db.raw.select('SELECT 1 FROM sync_state WHERE applied_seq>0 LIMIT 1').isNotEmpty) throw StateError('已有同步水位');
        _db.raw.execute('UPDATE sync_local SET device_id=?,enabled=1,requires_new_identity=0 WHERE id=1', [deviceId]);
        final outbox = SyncOutbox(_db, clock: _clock); var count = 0;
        for (final entry in Operation.syncFields.entries) {
          final type = entry.key;
          final columns = entry.value.map((f) => type == 'tag' && f == 'name' ? 'COALESCE(logical_name,name) AS name' : f).join(',');
          final table = const {'note': 'notes', 'item': 'items', 'tag': 'tags', 'attachment': 'attachments'}[type];
          final filter = type == 'attachment' ? " WHERE sync<>'local_only'" : '';
          final rows = _db.raw.select(type == 'item_tag' ? 'SELECT item_id,tag_id FROM item_tags ORDER BY item_id,tag_id'
              : 'SELECT id,$columns FROM $table$filter ORDER BY id');
          for (final row in rows) {
            final id = type == 'item_tag' ? Operation.itemTagId(row['item_id'] as String, row['tag_id'] as String) : row['id'] as String;
            count += outbox.recordInitialSnapshot(type, id, type == 'item_tag' ? {...row, 'present': true} : row);
          }
        }
        if (SyncProjector(_db).project() != 0) throw StateError('存量基线不完整');
        _db.raw.execute('UPDATE sync_local SET baseline_ready=1 WHERE id=1');
        return count;
      });
    } catch (_) { throw StateError('无法建立同步基线，启用未提交'); }
  }
}
