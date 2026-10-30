import 'operation.dart';

/// 按设备维护序号的操作日志。
///
/// `summary` 是 {deviceId: 已知条数}，用于与对端交换"我缺什么"。
/// 这是"单写者"原则的内存视图：本设备只往自己名下追加。
class OpLog {
  final List<Operation> _ops = [];
  final Map<String, List<Operation>> _byDevice = {};
  final Set<String> _seenIds = {};

  List<Operation> get all => List.unmodifiable(_ops);

  Map<String, int> get summary =>
      {for (final e in _byDevice.entries) e.key: e.value.length};

  /// 幂等追加：同一 opId 只记一次，重复传输不产生重复业务变更。
  bool append(Operation op) {
    if (!_seenIds.add(op.opId)) return false;
    _ops.add(op);
    _byDevice.putIfAbsent(op.deviceId, () => []).add(op);
    return true;
  }

  void appendAll(Iterable<Operation> ops) {
    for (final op in ops) {
      append(op);
    }
  }

  /// 对端摘要之外的操作，即"对端缺的部分"。
  List<Operation> since(Map<String, int> peerSummary) => [
        for (final e in _byDevice.entries) ...e.value.skip(peerSummary[e.key] ?? 0),
      ];

  List<Operation> ofDevice(String deviceId) =>
      List.unmodifiable(_byDevice[deviceId] ?? const []);

  int get length => _ops.length;
}
