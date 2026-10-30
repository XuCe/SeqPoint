import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('本机通知计划重开后保留稳定ID与待取消状态', () {
    final dir = Directory.systemTemp.createTempSync('seqpoint-plans-');
    final path = '${dir.path}/test.db';
    var db = SeqDatabase.open(path)..migrate();
    try {
      final tables = db.raw.select(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      expect(tables.map((r) => r['name']), contains('notification_plans'));
      db.raw.execute(
        'INSERT INTO notification_plans '
        '(plan_key, item_id, fire_at, state) VALUES (?, ?, ?, ?)',
        ['i1:due:2026-10-25', 'i1', '2026-10-25T12:00:00Z', 'cancel_pending'],
      );
      final id = db.raw.lastInsertRowId;
      db.close();
      db = SeqDatabase.open(path)..migrate();
      final row = db.raw.select('SELECT * FROM notification_plans').single;
      expect(row['notification_id'], id);
      expect(row['state'], 'cancel_pending');
      expect(
        () => db.raw.execute(
          'INSERT INTO notification_plans '
          '(plan_key, item_id, fire_at, state) VALUES (?, ?, ?, ?)',
          ['i1:due:2026-10-25', 'i1', '2026-10-25T12:00:00Z', 'pending'],
        ),
        throwsA(isA<Exception>()),
      );
    } finally {
      db.close();
      dir.deleteSync(recursive: true);
    }
  });
}
