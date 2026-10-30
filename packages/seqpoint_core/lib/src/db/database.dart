import 'package:sqlite3/sqlite3.dart';

import '../search/search_service.dart';
import 'migrations.dart';
import 'time_migration.dart';

/// SQLite 封装：打开、按版本迁移、提供原始句柄。
///
/// 加密（SQLCipher）通过替换 native 库接入，本类接口不变。
class SeqDatabase {
  SeqDatabase._(this.raw);

  final Database raw;
  int _transactionSequence = 0;
  int _syncCaptureSuppression = 0;

  bool get syncCaptureSuppressed => _syncCaptureSuppression > 0;

  /// 仅当前连接的同步导入使用，不影响其他引擎的本地写入。
  T withoutSyncCapture<T>(T Function() body) {
    _syncCaptureSuppression++;
    try {
      return body();
    } finally {
      _syncCaptureSuppression--;
    }
  }

  static SeqDatabase inMemory() => SeqDatabase._(sqlite3.openInMemory());

  static SeqDatabase open(String path) => SeqDatabase._(sqlite3.open(path));

  int get schemaVersion =>
      raw.select('PRAGMA user_version').first.columnAt(0) as int;

  /// 逐版本执行迁移，幂等：已是最新版则什么都不做。
  void migrate() {
    raw.execute('PRAGMA foreign_keys = ON');
    var current = schemaVersion;
    if (current >= latestSchemaVersion) return;

    while (current < latestSchemaVersion) {
      final next = current + 1;
      final statements = migrations[next];
      if (statements == null) {
        throw StateError('缺少 schema v$next 的迁移语句');
      }
      raw.execute('BEGIN');
      try {
        for (final sql in statements) {
          raw.execute(sql);
        }
        if (next == 7) migrateUtcTimes(raw);
        if (next == 11) SearchService(this).rebuild();
        raw.execute('PRAGMA user_version = $next');
        raw.execute('COMMIT');
      } catch (_) {
        raw.execute('ROLLBACK');
        rethrow;
      }
      current = next;
    }
  }

  /// 可嵌套的同步事务；释放内层SAVEPOINT不会提交调用方事务。
  T transaction<T>(T Function() body) {
    final name = 'seqpoint_tx_${++_transactionSequence}';
    raw.execute('SAVEPOINT $name');
    try {
      final result = body();
      raw.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      raw.execute('ROLLBACK TO SAVEPOINT $name');
      raw.execute('RELEASE SAVEPOINT $name');
      rethrow;
    }
  }

  /// 仅对已迁移的恢复候选调用；旧库/保护副本和系统私钥保持原样。
  void disconnectSyncForRestore() => transaction(() {
    raw.execute('DELETE FROM sync_checkpoint_staging');
    raw.execute('DELETE FROM sync_checkpoints');
    raw.execute('DELETE FROM sync_received_segments');
    raw.execute('DELETE FROM sync_operations');
    raw.execute('DELETE FROM sync_publications');
    raw.execute('DELETE FROM sync_state');
    raw.execute('DELETE FROM devices');
    raw.execute('DELETE FROM sync_local');
    raw.execute('INSERT INTO sync_local(id,requires_new_identity) VALUES (1,1)');
  });

  void close() => raw.dispose();
}
