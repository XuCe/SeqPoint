import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('同一设备连续生成单调递增', () {
    final a = Hlc.now('dev-a');
    final b = Hlc.now('dev-a', last: a);
    expect(b.compareTo(a), greaterThan(0));
  });

  test('同毫秒先比 counter，再比 deviceId', () {
    const x = Hlc(millis: 100, counter: 0, deviceId: 'dev-a');
    const y = Hlc(millis: 100, counter: 1, deviceId: 'dev-a');
    const z = Hlc(millis: 100, counter: 1, deviceId: 'dev-b');
    expect(y > x, isTrue);
    expect(z > y, isTrue);
  });

  test('字符串往返', () {
    const h = Hlc(millis: 1788000000000, counter: 3, deviceId: 'dev-a');
    expect(Hlc.parse(h.toString()), equals(h));
  });
  test('计数器上限进位，不产生负数；物理时钟前进时直接采用新时间', () {
    const last = Hlc(millis: 200, counter: 0x7fffffffffffffff, deviceId: 'peer');
    final carried = Hlc.now('local', last: last, at: DateTime.fromMillisecondsSinceEpoch(100));
    expect(carried.millis, 201); expect(carried.counter, 0);
    expect(carried > last, isTrue);
    final wall = Hlc.now('local', last: last, at: DateTime.fromMillisecondsSinceEpoch(300));
    expect(wall.millis, 300); expect(wall.counter, 0);
  });
  test('绝对时间与计数器同时耗尽时显式失败，不能回绕', () {
    const last = Hlc(millis: 8640000000000000,
        counter: 0x7fffffffffffffff, deviceId: 'peer');
    expect(() => Hlc.now('local', last: last, at: DateTime.fromMillisecondsSinceEpoch(100)),
        throwsStateError);
  });
}
