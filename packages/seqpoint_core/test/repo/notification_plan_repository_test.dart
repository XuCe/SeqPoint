import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('计划重试复用ID，取消持久化，退役后退出待处理列表', () {
    final db = SeqDatabase.inMemory()..migrate();
    addTearDown(db.close);
    final repo = NotificationPlanRepository(db);
    final when = DateTime.utc(2026, 10, 26, 15);
    final first = repo.ensure(key: 'i:due', itemId: 'i', fireAt: when);
    expect(db.raw.select('SELECT fire_at FROM notification_plans').single['fire_at'],
        '2026-10-26T15:00:00.000000Z');
    expect(first.state, 'pending');
    repo.setState(first.id, 'scheduled');
    final again = repo.ensure(key: 'i:due', itemId: 'i', fireAt: when);
    expect(again.id, first.id);
    expect(again.state, 'scheduled');
    repo.setState(first.id, 'cancel_pending');
    expect(NotificationPlanRepository(db).active().single.state,
        'cancel_pending');
    repo.setState(first.id, 'retired');
    expect(repo.active(), isEmpty);
    final restored = repo.ensure(key: 'i:due', itemId: 'i', fireAt: when);
    expect(restored.id, first.id);
    expect(restored.state, 'pending');
    expect(() => repo.setState(first.id, 'invalid'), throwsArgumentError);
  });
}
