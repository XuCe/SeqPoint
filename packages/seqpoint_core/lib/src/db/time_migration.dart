import 'package:sqlite3/sqlite3.dart';

import '../util/clock.dart';

/// 仅由v7事务调用。旧朴素日期沿用本机时区解释，不读取正文或密文。
void migrateUtcTimes(Database db) {
  const columns = {
    'notes': ['created_at', 'updated_at', 'closed_at', 'deleted_at'],
    'items': ['due_at', 'completed_at', 'created_at', 'updated_at', 'deleted_at'],
    'reminders': ['trigger_at', 'last_fired_at'],
    'activities': ['created_at'],
    'attachments': ['created_at', 'deleted_at'],
    'devices': ['added_at', 'revoked_at'],
    'sync_state': ['last_synced_at'],
    'secrets': ['updated_at'],
    'notification_plans': ['fire_at'],
  };
  for (final entry in columns.entries) {
    final fields = entry.value;
    final rows = db.select('SELECT rowid AS migration_row,${fields.join(',')} '
        'FROM ${entry.key}');
    final update = db.prepare('UPDATE ${entry.key} SET '
        '${fields.map((field) => '$field=?').join(',')} WHERE rowid=?');
    try {
      for (final row in rows) {
        final values = fields.map((field) {
          final value = row[field] as String?;
          return value == null ? null : encodeTime(DateTime.parse(value));
        }).toList();
        if (fields.indexed.any((f) => row[f.$2] != values[f.$1])) {
          update.execute([...values, row['migration_row']]);
        }
      }
    } finally {
      update.dispose();
    }
  }
}
