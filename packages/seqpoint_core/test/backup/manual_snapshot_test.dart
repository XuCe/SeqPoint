import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late Directory dir;
  late FakeClock clock;
  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    dir = Directory.systemTemp.createTempSync('seqpoint-manual-');
    clock = FakeClock(DateTime.utc(2026, 10, 25, 20, 30));
  });
  tearDown(() { db.close(); dir.deleteSync(recursive: true); });

  test('手动生成失败保留历史，不残留临时文件或目录', () async {
    final service = SnapshotService(db, clock: clock);
    final old = await service.createManual(dir);
    final before = old.file.readAsBytesSync();
    db.raw.execute('BEGIN IMMEDIATE');
    try {
      await expectLater(service.createManual(dir), throwsA(anything));
    } finally { db.raw.execute('ROLLBACK'); }
    expect(old.file.readAsBytesSync(), before);
    expect(dir.listSync().map((e) => e.path), [old.file.path]);
  });
  test('每日轮转仅清理每日快照，不删除手动保护快照', () async {
    final service = SnapshotService(db, clock: clock);
    final manual = await service.createManual(dir);
    for (var i = 0; i < 2; i++) {
      clock.advance(const Duration(days: 1));
      await service.createDaily(dir, keep: 1);
    }
    expect(manual.file.existsSync(), isTrue);
    expect(await service.list(dir), hasLength(2));
  });

  test('固定时钟重复手动备份不覆盖，旧内容完整且能列出', () async {
    final service = SnapshotService(db, clock: clock);
    final first = await service.createManual(dir);
    final before = first.file.readAsBytesSync();
    db.raw.execute('INSERT INTO notes '
      '(id,kind,raw_content,status,created_at,updated_at) VALUES (?,?,?,?,?,?)',
      ['note', 'text', 'new', 'active', '2026-10-25', '2026-10-25']);
    final second = await service.createManual(dir);
    expect(second.file.path, isNot(first.file.path));
    expect(first.file.readAsBytesSync(), before);
    expect(_count(first.file), 0);
    expect(_count(second.file), 1);
    expect(first.file.uri.pathSegments.last, isNot(contains(':')));
    final listed = await service.list(dir);
    expect(listed.map((s) => s.file.path),
      unorderedEquals([first.file.path, second.file.path]));
    expect(listed.every((s) => s.createdAt.isAtSameMomentAs(clock.now())), isTrue);
  });
}

int _count(File file) {
  final db = SeqDatabase.open(file.path);
  try {
    return db.raw.select('SELECT COUNT(*) FROM notes').single.columnAt(0) as int;
  } finally { db.close(); }
}
