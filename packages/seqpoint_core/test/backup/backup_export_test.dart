import 'dart:convert';
import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:test/test.dart';

void main() {
  late SeqDatabase db;
  late NoteService service;
  late FakeClock clock;
  late Directory tmp;

  setUp(() {
    db = SeqDatabase.inMemory()..migrate();
    clock = FakeClock(DateTime.parse('2026-09-05T09:00:00+08:00'));
    service = NoteService(
      db: db,
      notes: NoteRepository(db, clock: clock),
      items: ItemRepository(db, clock: clock),
      activities: ActivityRepository(db, clock: clock),
      clock: clock,
    );
    tmp = Directory.systemTemp.createTempSync('seqpoint_test_');
  });

  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('快照', () {
    test('生成快照且可被重新打开', () async {
      service.capture('快照里应该有这条内容');
      final snapshots = SnapshotService(db, clock: clock);

      final snap = await snapshots.createDaily(tmp);
      expect(snap.file.existsSync(), isTrue);
      expect(snap.bytes, greaterThan(0));

      final restored = SeqDatabase.open(snap.file.path);
      addTearDown(restored.close);
      final count =
          restored.raw.select('SELECT COUNT(*) AS c FROM notes').first['c']
              as int;
      expect(count, 1);
    });

    test('同日重复生成只占一个名额', () async {
      final snapshots = SnapshotService(db, clock: clock);
      service.capture('第一份内容');
      final first = await snapshots.createDaily(tmp);
      service.capture('同日新增内容');
      final second = await snapshots.createDaily(tmp);
      expect(second.file.path, first.file.path);
      expect(await snapshots.list(tmp), hasLength(1));
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
      final probe = SeqDatabase.open(second.file.path);
      try {
        expect(probe.raw.select('SELECT raw_content FROM notes').map((r) => r['raw_content']),
          unorderedEquals(['第一份内容', '同日新增内容']));
      } finally {
        probe.close();
      }
    });

    test('同日新快照生成失败时旧备份字节和可读内容完整保留', () async {
      final snapshots = SnapshotService(db, clock: clock);
      service.capture('旧备份中的便签');
      final old = await snapshots.createDaily(tmp);
      final before = await old.file.readAsBytes();
      service.capture('等待下一次快照的新便签');
      db.raw.execute('BEGIN');
      try {
        await expectLater(snapshots.createDaily(tmp), throwsA(isA<SqliteException>()));
      } finally {
        db.raw.execute('ROLLBACK');
      }
      expect(old.file.existsSync(), isTrue);
      expect(await old.file.readAsBytes(), before);
      expect((await snapshots.list(tmp)).single.file.path, old.file.path);
      final probe = SeqDatabase.open(old.file.path);
      try {
        expect(probe.raw.select('SELECT raw_content FROM notes').single['raw_content'],
          '旧备份中的便签');
      } finally {
        probe.close();
      }
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
      final retry = await snapshots.createDaily(tmp);
      expect(retry.file.path, old.file.path);
      final updated = SeqDatabase.open(retry.file.path);
      try {
        expect(updated.raw.select('SELECT raw_content FROM notes').map((r) => r['raw_content']),
          unorderedEquals(['旧备份中的便签', '等待下一次快照的新便签']));
      } finally {
        updated.close();
      }
      expect(await snapshots.list(tmp), hasLength(1));
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
    });

    test('首次生成失败不留下正式快照或临时目录，重试可成功', () async {
      final snapshots = SnapshotService(db, clock: clock);
      db.raw.execute('BEGIN');
      try {
        await expectLater(snapshots.createDaily(tmp), throwsA(isA<SqliteException>()));
      } finally {
        db.raw.execute('ROLLBACK');
      }
      expect(await snapshots.list(tmp), isEmpty);
      expect(tmp.listSync(), isEmpty);
      service.capture('首次失败后重试');
      final retry = await snapshots.createDaily(tmp);
      final probe = SeqDatabase.open(retry.file.path);
      try {
        expect(probe.schemaVersion, db.schemaVersion);
        expect(probe.raw.select('SELECT raw_content FROM notes').single['raw_content'],
          '首次失败后重试');
      } finally {
        probe.close();
      }
      expect(await snapshots.list(tmp), hasLength(1));
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
    });

    test('新快照失败不轮转任何历史备份，成功重试后才按保留数清理', () async {
      final snapshots = SnapshotService(db, clock: clock);
      service.capture('前一日内容');
      final older = await snapshots.createDaily(tmp);
      clock.advance(const Duration(days: 1));
      service.capture('后一日内容');
      final current = await snapshots.createDaily(tmp);
      final beforeOlder = await older.file.readAsBytes();
      final beforeCurrent = await current.file.readAsBytes();
      db.raw.execute('BEGIN');
      try {
        await expectLater(snapshots.createDaily(tmp, keep: 1),
          throwsA(isA<SqliteException>()));
      } finally {
        db.raw.execute('ROLLBACK');
      }
      expect((await snapshots.list(tmp)).map((s) => s.file.path),
        unorderedEquals([older.file.path, current.file.path]));
      expect(await older.file.readAsBytes(), beforeOlder);
      expect(await current.file.readAsBytes(), beforeCurrent);
      expect(tmp.listSync().whereType<Directory>(), isEmpty);
      final retry = await snapshots.createDaily(tmp, keep: 1);
      expect(retry.file.path, current.file.path);
      expect((await snapshots.list(tmp)).single.file.path, current.file.path);
      expect(older.file.existsSync(), isFalse);
      expect(current.file.existsSync(), isTrue);
    });

    test('超出保留数的旧快照被清理，最新的留下', () async {
      final snapshots = SnapshotService(db, clock: clock);
      for (var i = 0; i < 9; i++) {
        await snapshots.createDaily(tmp, keep: 7);
        clock.advance(const Duration(days: 1));
      }
      final kept = await snapshots.list(tmp);
      expect(kept, hasLength(7));
      expect(kept.first.createdAt.day, 13);
    });

    test('恢复前会校验文件确实是序点数据库', () async {
      final bogus = File('${tmp.path}/bogus.db')..writeAsStringSync('not a db');
      final snapshots = SnapshotService(db, clock: clock);
      expect(
        () => snapshots.restore(bogus, targetPath: '${tmp.path}/out.db'),
        throwsA(anything),
      );
    });
  });

  group('JSON 导出', () {
    test('包含便签与事项，且绝不含 secrets', () async {
      final note = service.capture('导出测试便签\n第二行');
      service.lineToItem(note.id, 0);

      final file = await JsonExporter(db, clock: clock).export(tmp);
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

      expect(json['format'], 'seqpoint-export');
      expect(json['notes'], hasLength(1));
      expect(json['items'], hasLength(1));
      expect(json.containsKey('secrets'), isFalse, reason: '密钥永不进导出文件');
    });

    test('默认排除回收站中的便签', () async {
      final keep = service.capture('保留的便签');
      final drop = service.capture('删掉的便签');
      service.trash(drop.id);

      final json = JsonExporter(db, clock: clock).build();
      final notes = json['notes'] as List;
      expect(notes, hasLength(1));
      expect((notes.first as Map)['id'], keep.id);
    });
  });

  group('Markdown 导出', () {
    test('UTC数据库日期导出为本地可读时刻', () async {
      clock.set(DateTime(2026, 10, 25, 23, 30));
      service.capture('本地日期');
      final index = await MarkdownExporter(db, clock: clock).export(tmp);
      final contents = await Future.wait(index.parent.listSync()
          .whereType<File>().map((file) => file.readAsString()));
      expect(contents.join('\n'), contains('创建于 2026-10-25 23:30'));
    });
    test('事项渲染为 checkbox，完成的打勾', () async {
      final note = service.capture('回复张三报价\n周五前发周报');
      service.lineToItem(note.id, 0);
      final second = service.lineToItem(note.id, 1);
      service.toggleItem(second.id);

      final index = await MarkdownExporter(db, clock: clock).export(tmp);

      final files = index.parent
          .listSync()
          .whereType<File>()
          .where((f) =>
              f.path.endsWith('.md') && !f.path.endsWith('README.md'))
          .toList();
      expect(files, hasLength(1));

      final content = files.first.readAsStringSync();
      expect(content, contains('- [ ] 回复张三报价'));
      expect(content, contains('- [x] 周五前发周报'));
    });

    test('生成 README 索引', () async {
      service.capture('第一条');
      service.capture('第二条');

      final index = await MarkdownExporter(db, clock: clock).export(tmp);
      final content = index.readAsStringSync();
      expect(content, contains('# 序点导出'));
      expect(content, contains('第一条'));
      expect(content, contains('第二条'));
    });

    test('标题里的路径字符不会破坏文件名', () async {
      service.capture('a/b\\c:d*e?f 的记录');
      final index = await MarkdownExporter(db, clock: clock).export(tmp);
      expect(index.parent.listSync().whereType<File>().length, 2);
    });
  });
}
