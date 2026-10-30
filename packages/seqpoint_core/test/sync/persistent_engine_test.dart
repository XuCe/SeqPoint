import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  late Directory root;
  late SeqDatabase source, db;
  late DeviceKeys peerKeys, localKeys;
  late VaultStore sender, reader;
  late SyncEngine engine;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('seqpoint_persistent_sync_');
    source = SeqDatabase.inMemory()..migrate(); db = SeqDatabase.inMemory()..migrate();
    peerKeys = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    localKeys = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    source.raw.execute('UPDATE sync_local SET enabled=1,device_id=?', [peerKeys.deviceId]);
    db.raw.execute('UPDATE sync_local SET enabled=1,device_id=?', [localKeys.deviceId]);
    VaultStore store(DeviceKeys keys) => VaultStore(root: root, deviceId: keys.deviceId,
        clock: FakeClock(DateTime.utc(2026, 10, 25)), codec: EncryptedSegmentCodec(
          vaultPublicId: 'v1', deviceKeys: keys, epochKeys: {1: List.filled(32, 7)},
          trustedSigners: {peerKeys.deviceId: peerKeys.signer.publicKey, localKeys.deviceId: localKeys.signer.publicKey}));
    sender = store(peerKeys); reader = store(localKeys);
    await sender.init(vaultPublicId: 'v1'); await reader.init(vaultPublicId: 'v1');
    NoteRepository(source, clock: FakeClock(DateTime.utc(2026, 10, 25))).insert(Note(
        id: 'n1', kind: NoteKind.text, status: NoteStatus.active, rawContent: '加密接收',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    engine = SyncEngine.persistent(store: reader, receiver: SyncSegmentReceiver(db));
  });
  tearDown(() { source.close(); db.close(); root.deleteSync(recursive: true); });
  test('显式持久引擎将认证操作写DB，开放段ACK不提前且重复幂等', () async {
    await sender.append(facts(source));
    final result = await engine.syncOnce(); expect(result.isOk, isTrue);
    expect(result.valueOrNull!.pulled, facts(source).length);
    expect(result.valueOrNull!.pendingObjects, 0);
    expect(NoteRepository(db).byId('n1')!.rawContent, '加密接收');
    expect(await reader.readAck(localKeys.deviceId), isEmpty);
    expect((await engine.syncOnce()).valueOrNull!.pulled, 0);
  });
  test('持久入口不降级到内存发布/物化，身份必须绑定同一Store', () async {
    NoteRepository(db).insert(Note(id: 'own', kind: NoteKind.text, status: NoteStatus.active,
        rawContent: '本机事务Outbox', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    expect((await engine.push(facts(db))).isOk, isFalse);
    expect(await reader.listSegments(localKeys.deviceId), isEmpty);
    expect(engine.materialize, throwsStateError);
    expect(() => SyncEngine.persistent(store: sender, receiver: SyncSegmentReceiver(db)), throwsArgumentError);
  });
  test('持续开放tail和跨月认证封口后继续下一段，ACK只到完整前缀', () async {
    final initial = facts(source), ids = facts(source).map((op) => op.opId).toSet();
    await sender.append(initial); await engine.syncOnce();
    final repo = NoteRepository(source, clock: FakeClock(DateTime.utc(2026, 10, 25)));
    repo.update(repo.byId('n1')!.copyWith(rawContent: '同段追加'));
    final tail = facts(source).where((op) => !ids.contains(op.opId)).toList();
    await sender.append(tail);
    expect((await engine.syncOnce()).valueOrNull!.pulled, tail.length);
    expect(NoteRepository(db).byId('n1')!.rawContent, '同段追加');
    expect(await reader.readAck(localKeys.deviceId), isEmpty);
    ids.addAll(tail.map((op) => op.opId));
    repo.update(repo.byId('n1')!.copyWith(rawContent: '跨月后段'));
    final next = facts(source).where((op) => !ids.contains(op.opId)).toList();
    final later = VaultStore(root: root, deviceId: peerKeys.deviceId, codec: sender.codec,
        clock: FakeClock(DateTime.utc(2026, 11, 1)));
    await later.append(next);
    expect((await engine.syncOnce()).valueOrNull!.pulled, next.length);
    expect(NoteRepository(db).byId('n1')!.rawContent, '跨月后段');
    expect(await reader.readAck(localKeys.deviceId), {peerKeys.deviceId: 1});
    expect(db.raw.select('SELECT applied_seq FROM sync_state').single['applied_seq'], 1);
  });
  test('磁盘ACK伪高水位不能跳过DB未接收数据', () async {
    await reader.writeSelfAck({peerKeys.deviceId: 999});
    await sender.append(facts(source));
    expect((await engine.syncOnce()).valueOrNull!.pulled, facts(source).length);
    expect(NoteRepository(db).byId('n1'), isNotNull);
    expect(await reader.readAck(localKeys.deviceId), isEmpty);
  });
  test('两独立DB双向加密收敛，不同字段并发修改均保留，重开无重复', () async {
    final clock = FakeClock(DateTime.utc(2026, 10, 25));
    NoteRepository(db, clock: clock).insert(Note(id: 'n2', kind: NoteKind.text,
        status: NoteStatus.active, rawContent: '另一端便签',
        createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
    final aIds = facts(source).map((op) => op.opId).toSet();
    final bIds = facts(db).map((op) => op.opId).toSet();
    await sender.append(facts(source)); await reader.append(facts(db));
    final other = SyncEngine.persistent(store: sender, receiver: SyncSegmentReceiver(source));
    expect((await engine.syncOnce()).isOk, isTrue); expect((await other.syncOnce()).isOk, isTrue);
    final aRepo = NoteRepository(source, clock: clock), bRepo = NoteRepository(db, clock: clock);
    aRepo.update(aRepo.byId('n1')!.copyWith(rawContent: '电脑正文'));
    bRepo.update(bRepo.byId('n1')!.copyWith(title: '手机标题'));
    await sender.append(facts(source).where((op) => op.deviceId == peerKeys.deviceId && !aIds.contains(op.opId)).toList());
    await reader.append(facts(db).where((op) => op.deviceId == localKeys.deviceId && !bIds.contains(op.opId)).toList());
    expect((await other.syncOnce()).isOk, isTrue); expect((await engine.syncOnce()).isOk, isTrue);
    for (final database in [source, db]) {
      final note = NoteRepository(database).byId('n1')!;
      expect(note.rawContent, '电脑正文'); expect(note.title, '手机标题');
      expect(NoteRepository(database).active().map((n) => n.id), unorderedEquals(['n1', 'n2']));
    }
    final path = '${root.path}/receiver.db'; db.raw.execute('VACUUM INTO ?', [path]);
    db.close(); db = SeqDatabase.open(path)..migrate();
    final sourcePath = '${root.path}/source.db'; source.raw.execute('VACUUM INTO ?', [sourcePath]);
    source.close(); source = SeqDatabase.open(sourcePath)..migrate();
    engine = SyncEngine.persistent(store: reader, receiver: SyncSegmentReceiver(db));
    final reopenedOther = SyncEngine.persistent(store: sender, receiver: SyncSegmentReceiver(source));
    expect((await engine.syncOnce()).valueOrNull!.pulled, 0);
    expect((await reopenedOther.syncOnce()).valueOrNull!.pulled, 0);
    expect(NoteRepository(db).byId('n1')!.title, '手机标题');
    expect(NoteRepository(source).byId('n1')!.rawContent, '电脑正文');
    expect(db.raw.select('PRAGMA foreign_key_check'), isEmpty);
  });
  test('目录段反序缺口明确等待，前段补到后继续封口前缀', () async {
    final ops = facts(source); await sender.append(ops);
    final tail = Operation.fromJson({...ops.last.toJson(), 'op_id': 'gap-tail',
      'hlc': Hlc(millis: ops.last.hlc.millis, counter: 100, deviceId: peerKeys.deviceId).toString(),
      'field': 'raw_content', 'value': '缺口后段'});
    await VaultStore(root: root, deviceId: peerKeys.deviceId, codec: sender.codec,
        clock: FakeClock(DateTime.utc(2026, 11, 1))).append([tail]);
    final first = Directory('${root.path}/ops/${peerKeys.deviceId}').listSync()
        .whereType<File>().singleWhere((f) => f.path.endsWith('-0001.log'));
    final hidden = await first.rename('${root.path}/withheld.log');
    final waiting = (await engine.syncOnce()).valueOrNull!;
    expect(waiting.pulled, 0); expect(waiting.waitingPeers, [peerKeys.deviceId]);
    expect(db.raw.select('SELECT * FROM sync_operations'), isEmpty);
    await hidden.rename(first.path);
    final applied = (await engine.syncOnce()).valueOrNull!;
    expect(applied.pulled, ops.length + 1); expect(applied.waitingPeers, isEmpty);
    expect(NoteRepository(db).byId('n1')!.rawContent, '缺口后段');
    expect(await reader.readAck(localKeys.deviceId), {peerKeys.deviceId: 1});
  });
  test('持久引擎ACK失败保留业务，下一轮仅补确认不重复写', () async {
    await sender.append(facts(source));
    final failing = VaultStore(root: root, deviceId: localKeys.deviceId, codec: reader.codec,
        writeAckBytes: (_, _) async { throw const FileSystemException('forced ACK failure'); });
    final failedEngine = SyncEngine.persistent(store: failing, receiver: SyncSegmentReceiver(db));
    expect((await failedEngine.syncOnce()).isOk, isFalse);
    expect(NoteRepository(db).byId('n1')!.rawContent, '加密接收');
    expect(db.raw.select('SELECT * FROM sync_received_segments'), hasLength(1));
    db.raw.execute('CREATE TEMP TRIGGER reject_repeat BEFORE UPDATE ON notes '
        "BEGIN SELECT RAISE(ABORT,'must-not-repeat'); END");
    final retried = await engine.syncOnce();
    expect(retried.isOk, isTrue); expect(retried.valueOrNull!.pulled, 0);
    expect(Directory('${root.path}/acks').listSync().whereType<File>(), hasLength(1));
  });
  test('真实加密段缺创建字段返回待投影，同段补tail后归零', () async {
    final ops = facts(source);
    await sender.append(ops.where((op) => op.field == 'raw_content').toList());
    final partial = (await engine.syncOnce()).valueOrNull!;
    expect(partial.pendingObjects, 1); expect(NoteRepository(db).byId('n1'), isNull);
    await sender.append(ops.where((op) => op.field != 'raw_content').toList());
    final complete = (await engine.syncOnce()).valueOrNull!;
    expect(complete.pendingObjects, 0);
    expect(NoteRepository(db).byId('n1')!.rawContent, '加密接收');
    expect(await reader.readAck(localKeys.deviceId), isEmpty);
  });
  test('双库旧alias经加密归一，canonical删除压旧关联，真实重加跨端恢复', () async {
    final clock = FakeClock(DateTime.utc(2026, 10, 25));
    void legacy(SeqDatabase database, String id) => SyncOutbox(database, clock: clock).capture('tag', id,
        read: () { final rows = database.raw.select('SELECT * FROM tags WHERE id=?', [id]);
          return rows.isEmpty ? null : rows.single; },
        write: () => database.raw.execute("INSERT INTO tags(id,name,kind,builtin,sort) VALUES (?,'想法','type',1,80)", [id]));
    legacy(source, 'legacy-a'); legacy(db, 'legacy-b');
    final aItems = ItemRepository(source, clock: clock), bItems = ItemRepository(db, clock: clock);
    aItems.insert(Item(id: 'item', noteId: 'n1', title: '关联事项', status: ItemStatus.todo,
        priority: Priority.p4, source: ItemSource.manual, createdAt: clock.now(), updatedAt: clock.now()));
    aItems.addTag('item', 'legacy-a');
    final aIds = facts(source).map((op) => op.opId).toSet(), bIds = facts(db).map((op) => op.opId).toSet();
    await sender.append(facts(source)); await reader.append(facts(db));
    final other = SyncEngine.persistent(store: sender, receiver: SyncSegmentReceiver(source));
    expect((await engine.syncOnce()).isOk, isTrue); expect((await other.syncOnce()).isOk, isTrue);
    for (final database in [source, db]) {
      expect(TagRepository(database).all().single.id, 'builtin-type:8');
      expect(ItemRepository(database).tagIdsOf('item'), ['builtin-type:8']);
    }
    bItems.setTags('item', []);
    await reader.append(facts(db).where((op) => op.deviceId == localKeys.deviceId && !bIds.contains(op.opId)).toList());
    expect((await other.syncOnce()).isOk, isTrue);
    expect(aItems.tagIdsOf('item'), isEmpty);
    aItems.addTag('item', 'builtin-type:8');
    await sender.append(facts(source).where((op) => op.deviceId == peerKeys.deviceId && !aIds.contains(op.opId)).toList());
    expect((await engine.syncOnce()).isOk, isTrue);
    for (final database in [source, db]) {
      expect(ItemRepository(database).tagIdsOf('item'), ['builtin-type:8']);
      expect(database.raw.select('PRAGMA foreign_key_check'), isEmpty);
    }
  });
}
