import 'dart:io';

import '../db/database.dart';
import 'snapshot_service.dart';

/// 离线恢复：调用方须先关闭目标库的全部连接，提交前保留保护副本。
class RestoreSession {
  RestoreSession._(String path) : target = File(path).absolute;
  final File target;
  File get candidate => File('${target.path}.restore-candidate.db');
  File get protection => File('${target.path}.restore-original.db');
  File get marker => File('${target.path}.restore-pending');
  File get _rollbackFile => File('${target.path}.restore-rollback.db');

  static Future<RestoreSession> prepare(File snapshot,
      {required String targetPath}) async {
    final session = RestoreSession._(targetPath);
    if (session.marker.existsSync()) throw StateError('存在未完成的恢复');
    _requireQuiescent(snapshot.path);
    _requireQuiescent(session.target.path);
    SnapshotService.validate(snapshot);
    SnapshotService.validate(session.target);
    final workFiles = [session.candidate, session.protection, session._rollbackFile];
    for (final file in [session.target, ...workFiles]) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final existing = File('${file.path}$suffix');
        if (existing.existsSync() && FileSystemEntity.identicalSync(snapshot.path,
            existing.path)) {
          throw ArgumentError('不能使用当前库或恢复工作文件作为源');
        }
      }
    }
    for (final file in workFiles) {
      await _removeSidecars(file.path);
      if (file.existsSync()) await file.delete();
    }
    await session.target.copy(session.protection.path);
    SnapshotService.validate(session.protection);
    await snapshot.copy(session.candidate.path);
    final staged = SeqDatabase.open(session.candidate.path);
    try {
      staged.migrate();
      staged.disconnectSyncForRestore();
    } finally { staged.close(); }
    SnapshotService.validate(session.candidate);
    return session;
  }

  /// 全部连接关闭后调用；替换失败仍保留标记和保护副本。
  Future<void> apply() async {
    if (marker.existsSync()) throw StateError('存在未完成的恢复');
    for (final file in [target, candidate, protection]) {
      _requireQuiescent(file.path);
    }
    SnapshotService.validate(candidate);
    SnapshotService.validate(protection);
    await marker.writeAsString('pending', flush: true);
    await candidate.rename(target.path);
  }

  /// 调用方重开并核验业务数据后提交，不删除唯一旧副本。
  Future<void> commit() async {
    if (!marker.existsSync() || candidate.existsSync()) {
      throw StateError('恢复尚未完成替换');
    }
    SnapshotService.validate(target);
    await marker.delete();
  }

  /// 仅在全部连接关闭时回滚；失败不清除标记或保护副本。
  Future<void> rollback() async {
    if (!marker.existsSync()) return;
    _requireQuiescent(protection.path);
    SnapshotService.validate(protection);
    await _removeSidecars(_rollbackFile.path);
    await protection.copy(_rollbackFile.path);
    SnapshotService.validate(_rollbackFile);
    await _removeSidecars(target.path);
    await _rollbackFile.rename(target.path);
    await marker.delete();
  }

  /// 应用启动时，在打开目标数据库之前恢复未完成的替换。
  static Future<bool> recover(String targetPath) async {
    final session = RestoreSession._(targetPath);
    if (!session.marker.existsSync()) return false;
    await session.rollback();
    return true;
  }

  static Future<void> _removeSidecars(String path) async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await file.delete();
      }
    }
  }

  static void _requireQuiescent(String path) {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      if (File('$path$suffix').existsSync()) {
        throw StateError('数据库仍有事务辅助文件，请先关闭相关窗口');
      }
    }
  }
}
