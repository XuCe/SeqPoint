/// 可注入的时钟，便于测试中固定时间。
abstract interface class Clock {
  DateTime now();
}

class SystemClock implements Clock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now();
}

/// 测试用：时间可手动推进。
class FakeClock implements Clock {
  FakeClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
  void set(DateTime t) => _now = t;
}

/// 数据库时间统一UTC与六位小数，使文本排序等同瞬间排序。
String encodeTime(DateTime t) {
  final utc = t.toUtc();
  final iso = utc.toIso8601String();
  return utc.microsecond == 0 ? '${iso.substring(0, iso.length - 1)}000Z' : iso;
}

DateTime? decodeTime(String? s) => s == null ? null : DateTime.parse(s);
