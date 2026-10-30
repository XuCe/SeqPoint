import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void seed(String path, String writer) {
  final db = SeqDatabase.open(path)..migrate();
  try {
    final now = DateTime.utc(2026, 10, 25);
    NoteRepository(db).insert(Note(id: 'n1', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: writer, createdAt: now, updatedAt: now));
    TagRepository(db).ensureBuiltins();
    db.raw.execute('UPDATE sync_local SET enabled = 1, device_id = ?, hlc_millis = 100, hlc_counter = 1', [writer]);
    db.raw.execute('INSERT INTO sync_operations(op_id,device_id,hlc_millis,hlc_counter,object_type,object_id,field,value_json,source) '
        "VALUES (?,?,100,1,'note','n1','raw_content','null','local')", ['op1', writer]);
    // 仅测试公开元数据，不代表真实配对/密文或私钥。
    db.raw.execute('INSERT INTO sync_publications(seq,file_name,key_epoch,segment_bytes,sealed,published) '
        "VALUES (1,'202610-0001.log',1,?,1,1)", [[1]]);
    db.raw.execute('INSERT INTO sync_received_segments '
        '(device_id,seq,key_epoch,created_at,op_count,sealed,segment_hash) '
        'VALUES (?,1,1,?,1,1,?)', ['peer', encodeTime(now), '0' * 64]);
    db.raw.execute('UPDATE sync_local SET pending_count=3,baseline_ready=1');
    db.raw.execute('INSERT INTO sync_state(device_id,applied_seq) VALUES (?,7)', [writer]);
    db.raw.execute('INSERT INTO devices(id,name,signing_public_key,exchange_public_key,is_self,added_at) '
        'VALUES (?,?,?,?,1,?)', [writer, writer, 'test-public', 'test-public', now.toIso8601String()]);
  } finally { db.close(); }
}

void expectDetached(String path) {
  final db = SeqDatabase.open(path);
  try {
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['enabled'], 0); expect(state['device_id'], isNull);
    expect(state['hlc_millis'], 0); expect(state['hlc_counter'], 0);
    expect(state['requires_new_identity'], 1);
    expect(state['pending_count'], 0);
    expect(state['baseline_ready'], 0);
    for (final table in ['devices', 'sync_state', 'sync_operations', 'sync_publications', 'sync_received_segments']) {
      expect(db.raw.select('SELECT * FROM $table'), isEmpty);
    }
    expect(NoteRepository(db).byId('n1')!.rawContent, 'source-writer');
  } finally { db.close(); }
}

void expectBound(String path, String writer) {
  final db = SeqDatabase.open(path);
  try {
    final state = db.raw.select('SELECT * FROM sync_local').single;
    expect(state['enabled'], 1); expect(state['device_id'], writer);
    expect(state['hlc_millis'], 100); expect(state['hlc_counter'], 1);
    expect(state['pending_count'], 3);
    expect(state['baseline_ready'], 1);
    for (final table in ['devices', 'sync_state', 'sync_operations', 'sync_publications', 'sync_received_segments']) {
      expect(db.raw.select('SELECT * FROM $table'), hasLength(1));
    }
  } finally { db.close(); }
}

void main() {
  late Directory dir;
  late File source, target;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('seqpoint_restore_sync_');
    source = File('${dir.path}/source.db'); target = File('${dir.path}/target.db');
    seed(source.path, 'source-writer'); seed(target.path, 'target-writer');
  });
  tearDown(() => dir.deleteSync(recursive: true));
  test('准备后的候选断开同步并要求新身份，源和目标不变', () async {
    final sourceBytes = source.readAsBytesSync(), targetBytes = target.readAsBytesSync();
    final session = await RestoreSession.prepare(source, targetPath: target.path);
    expectDetached(session.candidate.path);
    expectBound(source.path, 'source-writer');
    expectBound(session.protection.path, 'target-writer');
    expect(source.readAsBytesSync(), sourceBytes);
    expect(target.readAsBytesSync(), targetBytes);
    expect(session.protection.readAsBytesSync(), targetBytes);
  });
  test('替换和提交后断开持久化，保护副本仍保留原绑定', () async {
    final session = await RestoreSession.prepare(source, targetPath: target.path);
    await session.apply();
    expectDetached(target.path);
    await session.commit();
    expectDetached(target.path);
    expectBound(session.protection.path, 'target-writer');
    expect(await RestoreSession.recover(target.path), isFalse);
    expectDetached(target.path);
  });
  for (final action in ['rollback', 'startup']) {
    test('$action恢复旧writer/时钟/操作/水位，不能把旧库也断开', () async {
      final session = await RestoreSession.prepare(source, targetPath: target.path);
      await session.apply();
      if (action == 'rollback') { await session.rollback(); }
      else { expect(await RestoreSession.recover(target.path), isTrue); }
      expectBound(target.path, 'target-writer');
      expectBound(source.path, 'source-writer');
      expect(await RestoreSession.recover(target.path), isFalse);
      expectBound(target.path, 'target-writer');
    });
  }
  test('v5源迁移后也要求新身份，源文件保留原版本/字节', () async {
    source.deleteSync(); // 仅本测试临时源；按旧迁移真实创建v5，而非修改最新库版本号。
    final old = SeqDatabase.open(source.path);
    try {
      for (var version = 1; version <= 5; version++) {
        for (final sql in migrations[version]!) { old.raw.execute(sql); }
      }
      old.raw.execute('INSERT INTO notes(id,kind,status,raw_content,created_at,updated_at) '
          'VALUES (?,?,?,?,?,?)',
          ['n1', 'text', 'active', 'source-writer', '2026-10-25', '2026-10-25']);
      old.raw.execute('PRAGMA user_version = 5');
    } finally {
      old.close();
    }
    final bytes = source.readAsBytesSync();
    expect(SnapshotService.validate(source), 5);
    final session = await RestoreSession.prepare(source, targetPath: target.path);
    expectDetached(session.candidate.path);
    expect(source.readAsBytesSync(), bytes);
    expect(SnapshotService.validate(source), 5);
  });
  test('低阶恢复同样先准备断开的候选再替换，源保持原绑定', () async {
    final host = SeqDatabase.inMemory()..migrate();
    try {
      await SnapshotService(host).restore(source, targetPath: target.path);
      expectDetached(target.path);
      expectBound(source.path, 'source-writer');
    } finally { host.close(); }
  });
  test('低阶恢复拒绝源目标同一文件，不能就地断开源快照', () async {
    final host = SeqDatabase.inMemory()..migrate();
    final bytes = source.readAsBytesSync();
    try {
      await expectLater(SnapshotService(host).restore(source, targetPath: source.path),
          throwsArgumentError);
      expect(source.readAsBytesSync(), bytes);
    } finally { host.close(); }
  });
  test('低阶恢复拒绝目标WAL，保留旧库字节/绑定和源', () async {
    final host = SeqDatabase.inMemory()..migrate();
    final bytes = target.readAsBytesSync();
    File('${target.path}-wal').writeAsBytesSync([1]);
    try {
      await expectLater(SnapshotService(host).restore(source, targetPath: target.path),
          throwsStateError);
      expect(target.readAsBytesSync(), bytes);
      expectBound(source.path, 'source-writer');
      File('${target.path}-wal').deleteSync();
      expectBound(target.path, 'target-writer');
    } finally { host.close(); }
  });
  test('低阶候选替换失败清暂存，保留既有目标目录内容', () async {
    final host = SeqDatabase.inMemory()..migrate();
    final occupied = Directory('${dir.path}/occupied.db')..createSync();
    final keep = File('${occupied.path}/keep.txt')..writeAsStringSync('保留');
    try {
      await expectLater(SnapshotService(host).restore(source, targetPath: occupied.path),
          throwsA(isA<FileSystemException>()));
      expect(keep.readAsStringSync(), '保留');
      expect(dir.listSync().whereType<Directory>().map((d) => d.path), [occupied.path]);
      expectBound(source.path, 'source-writer');
    } finally { host.close(); }
  });
}
