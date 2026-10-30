import 'dart:async';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';
import 'publisher_prepare_test.dart' show DuringEncode;

void main() {
  late SeqDatabase db; late Directory root; late DeviceKeys keys;
  late EncryptedSegmentCodec codec; late SyncPublisher publisher;
  late FakeClock clock;
  VaultStore store({SegmentCodec? useCodec}) => VaultStore(root: root,
      deviceId: keys.deviceId, codec: useCodec ?? codec);
  File file(PublicationSnapshot saved) => File('${root.path}/ops/${keys.deviceId}/${saved.fileName}');
  void add(String id) => NoteRepository(db).insert(Note(id: id, kind: NoteKind.text,
      status: NoteStatus.active, rawContent: '临时发布:$id',
      createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026)));
  setUp(() async {
    db = SeqDatabase.inMemory()..migrate(); root = Directory.systemTemp.createTempSync('delivery-');
    keys = await DeviceKeys.fromSeeds(List.filled(32, 8), List.filled(32, 9));
    codec = EncryptedSegmentCodec(vaultPublicId: 'delivery', deviceKeys: keys,
        epochKeys: {1: List.filled(32, 10)}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
    add('n1');
    SyncBaseline(db).initialize(keys.deviceId);
    clock = FakeClock(DateTime.utc(2026, 10, 31));
    publisher = SyncPublisher(db, deviceId: keys.deviceId, clock: clock);
  });
  tearDown(() { db.close(); root.deleteSync(recursive: true); });
  test('陌生普通文件或目录阻止发布入口创建prepared/绑定/正式段', () async {
    final own = Directory('${root.path}/ops/${keys.deviceId}')..createSync(recursive: true);
    for (final directory in [false, true]) {
      final FileSystemEntity unexpected;
      if (directory) {
        unexpected = Directory('${own.path}/unknown')..createSync();
      } else {
        unexpected = File('${own.path}/unknown.txt')..createSync();
      }
      await expectLater(publisher.publishNext(store: store(), keyEpoch: 1), throwsStateError);
      expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
      expect(db.raw.select('SELECT 1 FROM sync_operations WHERE publication_seq IS NOT NULL'), isEmpty);
      expect(own.listSync(), hasLength(1));
      expect(db.raw.autocommit, isTrue);
      unexpected.deleteSync();
    }
  });
  test('真实加密prepared先提交，事务外写临时文件，原子替换后才标published', () async {
    final target = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async {
      expect(db.raw.autocommit, isTrue);
      expect(db.raw.select('SELECT published FROM sync_publications').single['published'], 0);
      await file.writeAsBytes(bytes, flush: true);
    });
    final saved = (await publisher.publishNext(store: target, keyEpoch: 1))!;
    expect(saved.published, isTrue); expect(file(saved).readAsBytesSync(), saved.bytes);
    expect(await publisher.publishNext(store: target, keyEpoch: 1), isNull);
  });
  test('文件已写但确认失败保留prepared，重试原bytes不重新加密', () async {
    db.raw.execute('CREATE TEMP TRIGGER fail_confirm BEFORE UPDATE OF published ON sync_publications '
        "WHEN NEW.published=1 BEGIN SELECT RAISE(ABORT,'injected'); END");
    await expectLater(publisher.publishNext(store: store(), keyEpoch: 1), throwsA(isA<Exception>()));
    final prepared = publisher.freeze().head!;
    expect(prepared.published, isFalse); expect(file(prepared).readAsBytesSync(), prepared.bytes);
    db.raw.execute('DROP TRIGGER fail_confirm');
    final retry = (await publisher.publishNext(store: store(useCodec: DuringEncode(codec,
        () async { fail('重试不能重新编码'); })), keyEpoch: 1))!;
    expect(retry.published, isTrue); expect(retry.bytes, prepared.bytes);
  });
  test('暂存写失败不落文件，队列仍可原bytes重试', () async {
    final failing = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async { await file.writeAsBytes([0]); throw StateError('injected'); });
    await expectLater(publisher.publishNext(store: failing, keyEpoch: 1), throwsStateError);
    final prepared = publisher.freeze().head!;
    expect(prepared.published, isFalse); expect(file(prepared).existsSync(), isFalse);
    expect(file(prepared).parent.listSync(), isEmpty);
    final retry = (await publisher.publishNext(store: store(useCodec: DuringEncode(codec,
        () async { fail('不能重新编码'); })), keyEpoch: 1))!;
    expect(retry.bytes, prepared.bytes); expect(retry.published, isTrue);
  });
  test('暂存期间恢复断开清同步状态，旧writer不能rename或确认', () async {
    final disconnecting = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async {
      await file.writeAsBytes(bytes, flush: true); db.disconnectSyncForRestore();
    });
    await expectLater(publisher.publishNext(store: disconnecting, keyEpoch: 1), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
    expect(db.raw.select('SELECT requires_new_identity FROM sync_local').single['requires_new_identity'], 1);
    expect(Directory('${root.path}/ops/${keys.deviceId}').listSync(), isEmpty);
  });
  test('同一发布队列串行，新写入只进入下一次开放tail', () async {
    final entered = Completer<void>(), resume = Completer<void>(); var writes = 0;
    final slow = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async {
      writes++; await file.writeAsBytes(bytes, flush: true);
      if (writes == 1) { entered.complete(); await resume.future; }
    });
    final first = publisher.publishNext(store: slow, keyEpoch: 1);
    await entered.future; expect(db.raw.autocommit, isTrue); add('n2');
    final second = publisher.publishNext(store: slow, keyEpoch: 1);
    expect(writes, 1); resume.complete();
    final original = (await first)!, tail = (await second)!;
    expect(writes, 2); expect(tail.seq, original.seq);
    expect((await codec.decode(Segment.decode(original.bytes))).every((op) => op.objectId == 'n1'), isTrue);
    expect((await codec.decode(Segment.decode(tail.bytes))).map((op) => op.objectId).toSet(), {'n1', 'n2'});
    expect(file(tail).readAsBytesSync(), tail.bytes);
  });
  test('另一发布者已确认并更新tail后，迟到暂存不能覆盖新文件', () async {
    final entered = Completer<void>(), resume = Completer<void>();
    final slow = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async {
      await file.writeAsBytes(bytes, flush: true); entered.complete(); await resume.future;
    });
    final stale = publisher.publishNext(store: slow, keyEpoch: 1);
    await entered.future;
    final other = SyncPublisher(db, deviceId: keys.deviceId);
    await other.publishNext(store: store(), keyEpoch: 1); add('n2');
    final latest = (await other.publishNext(store: store(), keyEpoch: 1))!;
    final rejected = expectLater(stale, throwsStateError); resume.complete(); await rejected;
    expect(file(latest).readAsBytesSync(), latest.bytes);
    expect(publisher.freeze().head!.bytes, latest.bytes);
    expect(file(latest).parent.listSync().where((entry) => entry.path.contains('.tmp.')), isEmpty);
  });
  test('stop拒绝新请求并等待已接受的发布队列，排空后旧DB可关闭', () async {
    final entered = Completer<void>(), resume = Completer<void>(); var writes = 0;
    final slow = VaultStore(root: root, deviceId: keys.deviceId, codec: codec,
        writeSegmentBytes: (file, bytes) async {
      writes++; await file.writeAsBytes(bytes, flush: true);
      if (writes == 1) { entered.complete(); await resume.future; }
    });
    final first = publisher.publishNext(store: slow, keyEpoch: 1);
    await entered.future; add('n2');
    final second = publisher.publishNext(store: slow, keyEpoch: 1);
    var stopped = false;
    final drain = publisher.stop().then((_) { stopped = true; });
    await expectLater(publisher.publishNext(store: slow, keyEpoch: 1), throwsStateError);
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 1), throwsStateError);
    expect(stopped, isFalse); expect(db.raw.autocommit, isTrue);
    resume.complete(); await first; final last = (await second)!; await drain;
    expect(stopped, isTrue); expect(writes, 2); expect(file(last).readAsBytesSync(), last.bytes);
    db.close(); db = SeqDatabase.inMemory()..migrate();
    await expectLater(publisher.prepare(codec: codec, keyEpoch: 1), throwsStateError);
    await publisher.stop();
  });
  test('stop同样等待独立prepare的事务外加密，不留下迟到DB写入', () async {
    final entered = Completer<void>(), resume = Completer<void>();
    final preparing = publisher.prepare(keyEpoch: 1, codec: DuringEncode(codec, () async {
      entered.complete(); await resume.future;
    }));
    await entered.future; var stopped = false;
    final drain = publisher.stop().then((_) { stopped = true; });
    await Future<void>.value(); expect(stopped, isFalse);
    resume.complete(); final prepared = (await preparing)!; await drain;
    expect(prepared.published, isFalse); expect(file(prepared).existsSync(), isFalse);
    db.disconnectSyncForRestore();
    await expectLater(publisher.publishNext(store: store(), keyEpoch: 1), throwsStateError);
    expect(db.raw.select('SELECT * FROM sync_publications'), isEmpty);
  });
  test('临时磁盘DB关闭重开后补确认同一prepared原bytes，身份/绑定不变', () async {
    db.close(); db = SeqDatabase.open('${root.path}/state.sqlite')..migrate();
    SyncBaseline(db).initialize(keys.deviceId); add('disk');
    publisher = SyncPublisher(db, deviceId: keys.deviceId, clock: clock);
    db.raw.execute('CREATE TEMP TRIGGER fail_confirm BEFORE UPDATE OF published ON sync_publications '
        "WHEN NEW.published=1 BEGIN SELECT RAISE(ABORT,'injected'); END");
    await expectLater(publisher.publishNext(store: store(), keyEpoch: 1), throwsA(isA<Exception>()));
    final prepared = publisher.freeze().head!;
    final bound = db.raw.select('SELECT op_id,publication_seq FROM sync_operations').map((r) => r.values.toList()).toList();
    db.close(); db = SeqDatabase.open('${root.path}/state.sqlite')..migrate();
    publisher = SyncPublisher(db, deviceId: keys.deviceId, clock: clock);
    final retry = (await publisher.publishNext(store: store(useCodec: DuringEncode(codec,
        () async { fail('重开不能重编码'); })), keyEpoch: 1))!;
    expect(retry.bytes, prepared.bytes); expect(retry.seq, prepared.seq); expect(retry.published, isTrue);
    expect(file(retry).readAsBytesSync(), prepared.bytes);
    expect(db.raw.select('SELECT device_id FROM sync_local').single['device_id'], keys.deviceId);
    expect(db.raw.select('SELECT op_id,publication_seq FROM sync_operations').map((r) => r.values.toList()), bound);
  });
  test('跨月全局序号不重置，旧缺文件从DB补发，陌生历史阻止新prepared', () async {
    await publisher.publishNext(store: store(), keyEpoch: 1);
    clock.set(DateTime.utc(2026, 11, 1)); add('n2');
    final sealed = (await publisher.publishNext(store: store(), keyEpoch: 1))!;
    expect(sealed.seq, 1); expect(sealed.sealed, isTrue);
    final november = (await publisher.publishNext(store: store(), keyEpoch: 1))!;
    expect(november.seq, 2); expect(november.fileName, contains('202611-'));
    file(sealed).deleteSync(); add('n3');
    final repair = (await publisher.publishNext(store: store(useCodec: DuringEncode(codec,
        () async { fail('旧缺文件不得重编码'); })), keyEpoch: 1))!;
    expect(repair.seq, 1); expect(repair.bytes, sealed.bytes);
    expect(file(repair).readAsBytesSync(), sealed.bytes);
    final unknown = File('${file(november).parent.path}/202611-0999.log')..writeAsBytesSync([]);
    await expectLater(publisher.publishNext(store: store(), keyEpoch: 1), throwsStateError);
    expect(publisher.freeze().head!.bytes, november.bytes);
    expect(db.raw.select("SELECT 1 FROM sync_operations WHERE object_id='n3' AND publication_seq IS NULL"), isNotEmpty);
    unknown.deleteSync();
    final tail = (await publisher.publishNext(store: store(), keyEpoch: 1))!;
    expect(tail.seq, 2); expect(file(tail).readAsBytesSync(), tail.bytes);
  });
}
