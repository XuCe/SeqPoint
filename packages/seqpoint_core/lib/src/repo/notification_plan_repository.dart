import '../db/database.dart';
import '../util/clock.dart';

typedef NotificationPlan = ({
  int id, String key, String itemId, DateTime fireAt, String state,
});

/// 仅本机使用；保留退役记录，平台ID不会被其他计划复用。
class NotificationPlanRepository {
  NotificationPlanRepository(this._db);
  final SeqDatabase _db;

  NotificationPlan _read(Map<String, Object?> r) => (
    id: r['notification_id'] as int,
    key: r['plan_key'] as String,
    itemId: r['item_id'] as String,
    fireAt: DateTime.parse(r['fire_at'] as String),
    state: r['state'] as String,
  );

  List<NotificationPlan> active() => _db.raw.select(
    "SELECT * FROM notification_plans WHERE state != 'retired'",
  ).map(_read).toList();

  NotificationPlan ensure({
    required String key, required String itemId, required DateTime fireAt,
    bool reactivate = true,
  }) {
    _db.raw.execute(
      'INSERT INTO notification_plans (plan_key,item_id,fire_at,state) '
      "VALUES (?,?,?,'pending') ON CONFLICT(plan_key) DO UPDATE SET "
      "state=CASE WHEN state='retired' AND ? THEN 'pending' ELSE state END",
      [key, itemId, encodeTime(fireAt), reactivate ? 1 : 0],
    );
    return _read(_db.raw.select(
      'SELECT * FROM notification_plans WHERE plan_key=?', [key],
    ).single);
  }

  void setState(int id, String state) {
    if (!const {'pending', 'scheduled', 'cancel_pending', 'retired'}
        .contains(state)) {
      throw ArgumentError.value(state, 'state');
    }
    _db.raw.execute(
      'UPDATE notification_plans SET state=? WHERE notification_id=?',
      [state, id],
    );
  }
}
