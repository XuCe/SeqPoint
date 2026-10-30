import 'package:flutter/foundation.dart';

import '../app/reminder_coordinator.dart';

/// 仅由主引擎在远端事务提交后调用；实例与当前数据库同寿命。
class SyncReconciliation {
  SyncReconciliation({this.reminders, required this.onChanged});

  final ReminderCoordinator? reminders;
  final VoidCallback onChanged;
  Future<void> _tail = Future.value();
  bool _paused = false;

  Future<void> afterRemoteChange() {
    if (_paused) return Future.value();
    final result = _tail.then((_) async {
      if (_paused) return;
      await reminders?.reconcile();
      if (!_paused) onChanged();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// 旧库关闭前永久停用并排空；恢复后由新容器重新创建实例。
  Future<void> pause() async {
    _paused = true;
    await _tail;
  }
}
