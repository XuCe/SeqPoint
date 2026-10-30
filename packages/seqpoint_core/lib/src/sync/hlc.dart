/// 混合逻辑时钟：`millis:counter:deviceId`。
///
/// 全序可比较，用于字段级合并决胜。同毫秒时先比 counter，再比 deviceId，
/// 保证任意两台设备对"谁胜出"得到相同结论，且与操作应用顺序无关。
class Hlc implements Comparable<Hlc> {
  const Hlc({
    required this.millis,
    required this.counter,
    required this.deviceId,
  });

  final int millis;
  final int counter;
  final String deviceId;
  static const maxMillis = 8640000000000000;
  static const maxCounter = 0x7fffffffffffffff;

  /// 生成下一个时钟值。[last] 为本设备上一次的值。
  factory Hlc.now(String deviceId, {Hlc? last, DateTime? at}) {
    final wall = (at ?? DateTime.now()).millisecondsSinceEpoch;
    if (wall < 0 || (last != null && (last.millis < 0 ||
        last.millis > maxMillis || last.counter < 0))) {
      throw ArgumentError('逻辑时钟参数无效');
    }
    if (last == null || wall > last.millis) {
      return Hlc(millis: wall, counter: 0, deviceId: deviceId);
    }
    if (last.counter == maxCounter) {
      if (last.millis == maxMillis) throw StateError('逻辑时钟已耗尽');
      return Hlc(millis: last.millis + 1, counter: 0, deviceId: deviceId);
    }
    return Hlc(
      millis: last.millis,
      counter: last.counter + 1,
      deviceId: deviceId,
    );
  }

  static Hlc parse(String s) {
    final parts = s.split(':');
    if (parts.length < 3) throw FormatException('非法 HLC: $s');
    return Hlc(
      millis: int.parse(parts[0]),
      counter: int.parse(parts[1]),
      deviceId: parts.sublist(2).join(':'),
    );
  }

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return deviceId.compareTo(other.deviceId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  String toString() => '$millis:$counter:$deviceId';

  @override
  bool operator ==(Object other) => other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, deviceId);
}
