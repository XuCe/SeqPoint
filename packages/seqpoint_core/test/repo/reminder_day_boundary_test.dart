import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  for (final day in [DateTime(2026, 3, 8), DateTime(2026, 11, 1)]) {
    test('智能提醒每日上限使用本地日历日：$day', () {
      final db = SeqDatabase.inMemory()..migrate();
      addTearDown(db.close);
      final item = ItemRepository(db).insert(Item(id: '', title: '日界',
          status: ItemStatus.todo, priority: Priority.p4,
          source: ItemSource.manual, createdAt: day, updatedAt: day));
      final repo = ReminderRepository(db);
      final end = DateTime(day.year, day.month, day.day + 1);
      final times = [day.subtract(const Duration(microseconds: 1)), day,
        end.subtract(const Duration(microseconds: 1)), end,
        end.add(const Duration(minutes: 30))];
      for (var i = 0; i < times.length; i++) {
        repo.insert(Reminder(id: 'r$i', itemId: item.id, mode: ReminderMode.smart,
            lastFiredAt: times[i].toUtc()));
      }
      expect(repo.smartFiredCountToday(item.id, day), 2);
      expect(repo.smartFiredCountToday(item.id, end), 2);
    });
  }
}
