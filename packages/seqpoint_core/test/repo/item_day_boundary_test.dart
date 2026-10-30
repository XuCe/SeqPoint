import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Item _insert(ItemRepository items, DateTime at, bool completed) => items.insert(
  Item(id: '', title: '$at', status: completed ? ItemStatus.done : ItemStatus.todo,
    priority: Priority.p4, source: ItemSource.manual, dueAt: at,
    completedAt: completed ? at : null, createdAt: at, updatedAt: at));

void main() {
  late SeqDatabase db;
  late ItemRepository items;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    items = ItemRepository(db);
  });
  tearDown(() => db.close());

  for (final completed in [false, true]) {
    test('回拨日${completed ? '已完成' : '待办'}包含最后一小时且不混入相邻日期', () {
      final day = DateTime(2026, 11, 1, 12);
      final start = DateTime(2026, 11, 1);
      final end = DateTime(2026, 11, 2);
      if (Platform.environment['TZ'] == 'America/Los_Angeles') {
        expect(end.difference(start).inHours, 25);
        expect(start.add(const Duration(minutes: 90)).hour, 1);
        expect(start.add(const Duration(minutes: 150)).hour, 1);
      } else if (Platform.environment['TZ'] == 'UTC') {
        expect(end.difference(start).inHours, 24);
      }
      final expected = [start, start.add(const Duration(minutes: 90)),
        start.add(const Duration(minutes: 150)), DateTime(2026, 11, 1, 23),
        DateTime(2026, 11, 1, 23, 30), end.subtract(const Duration(microseconds: 1))]
        .map((at) => _insert(items, at, completed).id).toList();
      for (final at in [start.subtract(const Duration(microseconds: 1)),
        end, DateTime(2026, 11, 2, 0, 30)]) {
        _insert(items, at, completed);
      }
      final actual = completed ? items.completedOn(day) : items.dueOn(day);
      expect(actual.map((item) => item.id), unorderedEquals(expected));
    });

    test('前拨日${completed ? '已完成' : '待办'}不计入次日零点后的一小时', () {
      final day = DateTime(2026, 3, 8, 12);
      final start = DateTime(2026, 3, 8);
      final end = DateTime(2026, 3, 9);
      if (Platform.environment['TZ'] == 'America/Los_Angeles') {
        expect(end.difference(start).inHours, 23);
      } else if (Platform.environment['TZ'] == 'UTC') {
        expect(end.difference(start).inHours, 24);
      }
      final expected = [start, DateTime(2026, 3, 8, 1, 59, 59, 999, 999),
        DateTime(2026, 3, 8, 3), end.subtract(const Duration(microseconds: 1))]
        .map((at) => _insert(items, at, completed).id).toList();
      final outside = [start.subtract(const Duration(microseconds: 1)),
        end, DateTime(2026, 3, 9, 0, 30), DateTime(2026, 3, 9, 1)]
        .map((at) => _insert(items, at, completed).id).toList();
      List<Item> query(DateTime date) =>
        completed ? items.completedOn(date) : items.dueOn(date);
      expect(query(day).map((item) => item.id), unorderedEquals(expected));
      expect(query(DateTime(2026, 3, 7, 12)).map((item) => item.id), [outside.first]);
      expect(query(DateTime(2026, 3, 9, 12)).map((item) => item.id),
        unorderedEquals(outside.skip(1)));
    });

    for (final day in [DateTime(2026, 2, 28, 12), DateTime(2026, 12, 31, 12)]) {
      test('普通日期$day${completed ? '已完成' : '待办'}在月底跨年仍按本地日期隔离', () {
        final start = DateTime(day.year, day.month, day.day);
        final end = DateTime(day.year, day.month, day.day + 1);
        final expected = [start, day, end.subtract(const Duration(microseconds: 1))]
          .map((at) => _insert(items, at, completed).id).toList();
        final outside = [start.subtract(const Duration(microseconds: 1)),
          end, end.add(const Duration(minutes: 30))]
          .map((at) => _insert(items, at, completed).id).toList();
        List<Item> query(DateTime date) =>
          completed ? items.completedOn(date) : items.dueOn(date);
        expect(query(day).map((item) => item.id), unorderedEquals(expected));
        expect(query(start).map((item) => item.id), unorderedEquals(expected));
        expect(query(end.subtract(const Duration(microseconds: 1))).map((item) => item.id),
          unorderedEquals(expected));
        expect(query(DateTime(day.year, day.month, day.day - 1, 12)).map((item) => item.id),
          [outside.first]);
        expect(query(DateTime(day.year, day.month, day.day + 1, 12)).map((item) => item.id),
          unorderedEquals(outside.skip(1)));
      });
    }
  }
}
