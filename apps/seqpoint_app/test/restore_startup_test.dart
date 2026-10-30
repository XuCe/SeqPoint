import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seqpoint_app/app/bootstrap.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

void main() {
  test('普通启动保留同步绑定，恢复候选装配后必须断开并要求新身份', () async {
    final dir = Directory.systemTemp.createTempSync('seqpoint-sync-bootstrap-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/current.db', sourcePath = '${dir.path}/source.db';
    final original = await Bootstrap.run(dbPath: path);
    original.noteService.capture('旧便签');
    original.db.raw.execute('UPDATE sync_local SET enabled = 1, device_id = ?, hlc_millis = 100',
        ['old-writer']);
    original.dispose();
    final normal = await Bootstrap.run(dbPath: path);
    try {
      final state = normal.db.raw.select('SELECT * FROM sync_local').single;
      expect(state['enabled'], 1); expect(state['device_id'], 'old-writer');
      expect(state['hlc_millis'], 100);
    } finally { normal.dispose(); }
    final source = await Bootstrap.run(dbPath: sourcePath);
    source.noteService.capture('恢复的便签');
    source.db.raw.execute('UPDATE sync_local SET enabled = 1, device_id = ?', ['source-writer']);
    source.dispose();
    final session = await RestoreSession.prepare(File(sourcePath), targetPath: path);
    await session.apply();
    final candidate = await Bootstrap.run(dbPath: path, recoverPendingRestore: false);
    try {
      final state = candidate.db.raw.select('SELECT * FROM sync_local').single;
      expect(state['enabled'], 0); expect(state['device_id'], isNull);
      expect(state['requires_new_identity'], 1);
      expect(candidate.notes.active().single.rawContent, '恢复的便签');
      await session.commit();
    } finally { candidate.dispose(); }
  });
  test('候选装配失败可回滚并重新打开旧库', () async {
    final dir = Directory.systemTemp.createTempSync('seqpoint-restore-fail-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/current.db';
    final snapshot = File('${dir.path}/snapshot.db');
    final current = await Bootstrap.run(dbPath: path);
    current.noteService.capture('原始数据'); current.dispose();
    final source = await Bootstrap.run(dbPath: snapshot.path);
    source.noteService.capture('装配失败的候选'); source.dispose();
    final session = await RestoreSession.prepare(snapshot, targetPath: path);
    await session.apply();
    // 在替换后注入装配故障；快照本身必须通过预检。
    final broken = SeqDatabase.open(path);
    // 初始化现在跳过已有标签；让候选确实需要一次INSERT才可触发故障。
    broken.raw.execute('DELETE FROM tags WHERE id = (SELECT id FROM tags WHERE builtin = 1 LIMIT 1)');
    broken.raw.execute('CREATE TRIGGER reject_builtin BEFORE INSERT ON tags '
      "BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    broken.close();
    await expectLater(Bootstrap.run(dbPath: path, recoverPendingRestore: false),
      throwsA(isA<Exception>()));
    expect(session.marker.existsSync(), isTrue);
    await session.rollback();
    final reopened = await Bootstrap.run(dbPath: path);
    try {
      expect(reopened.notes.active().single.rawContent, '原始数据');
    } finally { reopened.dispose(); }
  });

  test('恢复事务内显式重开候选，提交后下一次正常启动保留新数据', () async {
    final dir = Directory.systemTemp.createTempSync('seqpoint-restore-commit-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/current.db';
    final snapshot = File('${dir.path}/snapshot.db');
    final current = await Bootstrap.run(dbPath: path);
    current.noteService.capture('原始数据'); current.dispose();
    final source = await Bootstrap.run(dbPath: snapshot.path);
    source.noteService.capture('确认的新数据'); source.dispose();
    final session = await RestoreSession.prepare(snapshot, targetPath: path);
    await session.apply();
    final candidate = await Bootstrap.run(dbPath: path,
      recoverPendingRestore: false);
    try {
      expect(candidate.notes.active().single.rawContent, '确认的新数据');
      await session.commit();
    } finally { candidate.dispose(); }
    final reopened = await Bootstrap.run(dbPath: path);
    try {
      expect(reopened.notes.active().single.rawContent, '确认的新数据');
      expect(session.marker.existsSync(), isFalse);
    } finally { reopened.dispose(); }
  });

  test('启动装配前回滚未提交恢复，不向界面暴露候选数据', () async {
    final dir = Directory.systemTemp.createTempSync('seqpoint-restore-boot-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/current.db';
    final snapshot = File('${dir.path}/snapshot.db');
    final current = await Bootstrap.run(dbPath: path);
    current.noteService.capture('原始数据');
    current.dispose();
    final source = await Bootstrap.run(dbPath: snapshot.path);
    source.noteService.capture('尚未确认的新数据');
    source.dispose();
    final session = await RestoreSession.prepare(snapshot, targetPath: path);
    await session.apply();
    final reopened = await Bootstrap.run(dbPath: path);
    try {
      expect(reopened.notes.active().single.rawContent, '原始数据');
      expect(session.marker.existsSync(), isFalse);
      expect(SnapshotService.validate(snapshot), latestSchemaVersion);
    } finally { reopened.dispose(); }
  });
}
