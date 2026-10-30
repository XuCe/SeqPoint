import '../db/database.dart';
import '../model/activity.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import 'mappers.dart';

/// 操作留痕仓储。写入必须便宜且不抛异常，避免影响主流程。
class ActivityRepository {
  ActivityRepository(this._db, {Clock clock = const SystemClock()})
      : _clock = clock;

  final SeqDatabase _db;
  final Clock _clock;

  void log({
    required String objectType,
    required String objectId,
    required String action,
    String? oldValue,
    String? newValue,
  }) {
    _db.raw.execute(
      'INSERT INTO activities (id, object_type, object_id, action, old_value, '
      'new_value, created_at) VALUES (?,?,?,?,?,?,?)',
      [
        newId(),
        objectType,
        objectId,
        action,
        oldValue,
        newValue,
        encodeTime(_clock.now()),
      ],
    );
  }

  List<Activity> forObject(String objectType, String objectId,
          {int limit = 100}) =>
      _db.raw
          .select(
              'SELECT * FROM activities WHERE object_type = ? AND object_id = ? '
              'ORDER BY created_at DESC LIMIT ?',
              [objectType, objectId, limit])
          .map(RowMappers.activity)
          .toList();

  List<Activity> recent({int limit = 100}) => _db.raw
      .select('SELECT * FROM activities ORDER BY created_at DESC LIMIT ?',
          [limit])
      .map(RowMappers.activity)
      .toList();
}
