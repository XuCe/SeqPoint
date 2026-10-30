import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;

  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
  });

  tearDown(() => db.close());

  test('迁移到最新版本并建出全部表', () {
    expect(db.schemaVersion, latestSchemaVersion);
    final names = db.raw
        .select("SELECT name FROM sqlite_master WHERE type='table'")
        .map((r) => r['name'] as String)
        .toSet();
    expect(
      names,
      containsAll([
        'notes',
        'items',
        'tags',
        'item_tags',
        'reminders',
        'activities',
        'attachments',
        'devices',
        'sync_state',
        'secrets',
      ]),
    );
  });

  test('重复迁移幂等', () {
    db.migrate();
    expect(db.schemaVersion, latestSchemaVersion);
  });

  test('事务失败自动回滚', () {
    expect(
      () => db.transaction(() {
        db.raw.execute(
          'INSERT INTO notes (id, kind, raw_content, status, created_at, updated_at) '
          "VALUES ('n1','text','x','active','2026-09-03T09:00:00+08:00','2026-09-03T09:00:00+08:00')",
        );
        throw StateError('boom');
      }),
      throwsStateError,
    );
    expect(db.raw.select('SELECT COUNT(*) AS c FROM notes').first['c'], 0);
  });
}
