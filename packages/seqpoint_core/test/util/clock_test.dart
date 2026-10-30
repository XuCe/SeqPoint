import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('数据库时间统一UTC固定六位，微秒文本排序与时间排序一致', () {
    final base = DateTime.utc(2026, 11, 1, 9, 30);
    final later = base.add(const Duration(microseconds: 1));
    expect(encodeTime(base.toLocal()), '2026-11-01T09:30:00.000000Z');
    expect(encodeTime(later), '2026-11-01T09:30:00.000001Z');
    expect(encodeTime(base).compareTo(encodeTime(later)), lessThan(0));
    expect(decodeTime(encodeTime(base.toLocal()))!.isAtSameMomentAs(base), isTrue);
  });

  test('DST重复的本地钟面不丢失各自UTC瞬间', () {
    for (final hour in [8, 9]) {
      final instant = DateTime.utc(2026, 11, 1, hour, 30);
      final local = instant.toLocal();
      expect(decodeTime(encodeTime(local))!.toUtc(), instant);
    }
  });
}
