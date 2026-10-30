import 'dart:io';
import 'dart:isolate';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File target, snapshot;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('seqpoint-restore-');
    target = File('${dir.path}/current.db');
    snapshot = File('${dir.path}/snapshot.db');
    _seed(target, 'old'); _seed(snapshot, 'new');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('重新准备清理真实崩溃留下的候选WAL，不复用旧内容', () async {
    final candidate = target.copySync('${target.path}.restore-candidate.db');
    final core = await Isolate.resolvePackageUri(
      Uri.parse('package:seqpoint_core/seqpoint_core.dart'));
    final helper = core!.resolve('../test/backup/fixtures/stale_snapshot_child.dart');
    final config = await Isolate.packageConfig;
    final child = await Process.run(Platform.resolvedExecutable,
      ['--packages=${config!.toFilePath()}', helper.toFilePath(), candidate.path]);
    expect(child.exitCode, 0, reason: '${child.stdout}\n${child.stderr}');
    expect(File('${candidate.path}-wal').existsSync(), isTrue);
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    expect(_content(session.candidate), 'new');
    await session.apply();
    await session.commit();
    expect(_content(target), 'new');
  });
  for (final work in ['candidate', 'original', 'rollback']) {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      test('拒绝工作辅助路径源$work$suffix且保持源字节', () async {
        final source = snapshot.copySync('${target.path}.restore-$work.db$suffix');
        final before = source.readAsBytesSync();
        await expectLater(RestoreSession.prepare(source, targetPath: target.path),
          throwsArgumentError);
        expect(source.readAsBytesSync(), before);
        expect(_content(target), 'old');
      });
    }
  }

  test('文件替换失败保留标记，解除阻塞后可从保护副本恢复', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    target.deleteSync();
    final blocker = Directory(target.path)..createSync();
    await expectLater(session.apply(), throwsA(isA<FileSystemException>()));
    expect(session.marker.existsSync(), isTrue);
    expect(_content(session.protection), 'old');
    blocker.deleteSync();
    expect(await RestoreSession.recover(target.path), isTrue);
    expect(_content(target), 'old');
  });
  test('回滚清理新库遗留的事务辅助文件，不混入旧库', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    await session.apply();
    for (final suffix in ['-wal', '-shm', '-journal']) {
      File('${target.path}$suffix').writeAsStringSync('tentative');
    }
    await session.rollback();
    expect(_content(target), 'old');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      expect(File('${target.path}$suffix').existsSync(), isFalse);
    }
  });
  test('标记写入后替换前中断，即使空标记也安全回滚', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    session.marker.writeAsStringSync('', flush: true);
    expect(await RestoreSession.recover(target.path), isTrue);
    expect(_content(target), 'old');
    expect(_content(snapshot), 'new');
  });

  test('未提交时进程中断，启动检测回滚并可重复调用', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    await session.apply();
    final old = session.protection.readAsBytesSync();
    expect(await RestoreSession.recover(target.path), isTrue);
    expect(_content(target), 'old');
    expect(session.protection.readAsBytesSync(), old);
    expect(session.marker.existsSync(), isFalse);
    expect(await RestoreSession.recover(target.path), isFalse);
  });
  test('新库无法通过重开校验时保留标记并回滚旧库', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    await session.apply();
    target.writeAsBytesSync([1, 2, 3]);
    await expectLater(session.commit(), throwsA(anything));
    expect(session.marker.existsSync(), isTrue);
    await session.rollback();
    expect(_content(target), 'old');
    expect(_content(snapshot), 'new');
  });
  test('保护副本损坏时拒绝回滚且保留全部恢复证据', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    await session.apply();
    session.protection.writeAsBytesSync([1, 2, 3]);
    await expectLater(RestoreSession.recover(target.path), throwsA(anything));
    expect(session.marker.existsSync(), isTrue);
    expect(session.protection.readAsBytesSync(), [1, 2, 3]);
    expect(_content(target), 'new');
  });

  test('替换保留标记和保护副本，验证后提交才清除标记', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    await expectLater(session.commit(), throwsStateError);
    await session.apply();
    expect(_content(target), 'new');
    expect(_content(session.protection), 'old');
    expect(session.marker.existsSync(), isTrue);
    await expectLater(session.apply(), throwsStateError);
    await session.commit();
    expect(session.marker.existsSync(), isFalse);
    expect(_content(target), 'new');
    expect(_content(session.protection), 'old');
  });

  test('准备后候选损坏时替换被拒绝，目标字节不变', () async {
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    final before = target.readAsBytesSync();
    session.candidate.writeAsBytesSync([1, 2, 3]);
    await expectLater(session.apply(), throwsA(anything));
    expect(target.readAsBytesSync(), before);
    expect(session.marker.existsSync(), isFalse);
  });

  for (final suffix in ['', '.restore-candidate.db', '.restore-original.db',
      '.restore-rollback.db']) {
    test('拒绝内部源$suffix且不删除该文件', () async {
      final source = File('${target.path}$suffix');
      if (suffix.isNotEmpty) snapshot.copySync(source.path);
      final before = source.readAsBytesSync();
      await expectLater(RestoreSession.prepare(source, targetPath: target.path),
        throwsArgumentError);
      expect(source.readAsBytesSync(), before);
      expect(_content(target), 'old');
    });
  }
  for (final sourceSidecar in [true, false]) {
    test('存在活动辅助文件时拒绝准备 source=$sourceSidecar', () async {
      final file = sourceSidecar ? snapshot : target;
      final sidecar = File('${file.path}-journal')..writeAsStringSync('active');
      final before = target.readAsBytesSync();
      await expectLater(RestoreSession.prepare(snapshot, targetPath: target.path),
        throwsStateError);
      expect(sidecar.readAsStringSync(), 'active');
      expect(target.readAsBytesSync(), before);
    });
  }
  test('未完成标记阻止再次准备并保留旧保护副本', () async {
    final marker = File('${target.path}.restore-pending')..writeAsStringSync('pending');
    final protection = snapshot.copySync('${target.path}.restore-original.db');
    final before = protection.readAsBytesSync();
    await expectLater(RestoreSession.prepare(snapshot, targetPath: target.path),
      throwsStateError);
    expect(marker.existsSync(), isTrue);
    expect(protection.readAsBytesSync(), before);
    expect(_content(target), 'old');
  });

  test('只迁移候选，旧版本快照字节保持不变', () async {
    snapshot.deleteSync();
    final old = SeqDatabase.open(snapshot.path);
    for (final sql in migrations[1]!) { old.raw.execute(sql); }
    old.raw.execute('PRAGMA user_version = 1');
    old.close();
    final before = snapshot.readAsBytesSync();
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    expect(SnapshotService.validate(session.candidate), latestSchemaVersion);
    expect(SnapshotService.validate(snapshot), 1);
    expect(snapshot.readAsBytesSync(), before);
    expect(_content(target), 'old');
  });

  test('候选复制失败不修改目标，且不产生替换标记', () async {
    Directory('${target.path}.restore-candidate.db').createSync();
    final before = target.readAsBytesSync();
    await expectLater(RestoreSession.prepare(snapshot, targetPath: target.path),
      throwsA(isA<FileSystemException>()));
    expect(target.readAsBytesSync(), before);
    expect(File('${target.path}.restore-pending').existsSync(), isFalse);
  });

  test('准备会话保留目标与源文件，生成独立候选和保护副本', () async {
    final before = target.readAsBytesSync();
    final source = snapshot.readAsBytesSync();
    final session = await RestoreSession.prepare(snapshot,
      targetPath: target.path);
    expect(target.readAsBytesSync(), before);
    expect(snapshot.readAsBytesSync(), source);
    expect(_content(session.candidate), 'new');
    expect(_content(session.protection), 'old');
    expect(session.marker.existsSync(), isFalse);
  });
}

void _seed(File file, String content) {
  final db = SeqDatabase.open(file.path)..migrate();
  try {
    db.raw.execute('INSERT INTO notes '
      '(id,kind,raw_content,status,created_at,updated_at) VALUES (?,?,?,?,?,?)',
      ['note', 'text', content, 'active', '2026-10-25', '2026-10-25']);
  } finally { db.close(); }
}

String _content(File file) {
  final db = SeqDatabase.open(file.path);
  try {
    return db.raw.select('SELECT raw_content FROM notes').single['raw_content']
      as String;
  } finally { db.close(); }
}
