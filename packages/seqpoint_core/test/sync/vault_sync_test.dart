import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

const itemKey = (type: 'item', id: 'i1');

Operation op(String dev, int ms, String objectId, String field, Object? v) =>
    Operation(
      opId: '$dev-$ms-$objectId-$field',
      deviceId: dev,
      hlc: Hlc(millis: ms, counter: 0, deviceId: dev),
      objectType: 'item',
      objectId: objectId,
      field: field,
      value: v,
    );

void main() {
  late Directory tmp;
  late FakeClock clock;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('seqpoint_vault_');
    clock = FakeClock(DateTime(2026, 9, 5, 10));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  VaultStore storeFor(String deviceId) => VaultStore(
        root: tmp,
        deviceId: deviceId,
        codec: const PlainSegmentCodec(),
        clock: clock,
      );

  group('Vault 目录', () {
    test('初始化建出全部子目录与 manifest', () async {
      final store = storeFor('phone');
      final manifest = await store.init(vaultPublicId: 'vault-abc');

      expect(manifest.vaultPublicId, 'vault-abc');
      expect(manifest.keyEpoch, 1);
      for (final dir in ['members', 'ops', 'acks', 'attachments', 'snapshots']) {
        expect(Directory('${tmp.path}/$dir').existsSync(), isTrue,
            reason: '缺少目录 $dir');
      }
    });

    test('重复初始化不覆盖已有 manifest', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'first');
      final again = await store.init(vaultPublicId: 'second');
      expect(again.vaultPublicId, 'first');
    });
  });

  group('段写入与读回', () {
    test('写入的操作能原样读回', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');

      await store.append([
        op('phone', 100, 'i1', 'title', '回复张三报价'),
        op('phone', 101, 'i1', 'due_at', '2026-09-05T18:00:00+08:00'),
      ]);

      final segments = await store.listSegments('phone');
      expect(segments, hasLength(1));
      expect(segments.first.opCount, 2);

      final ops = await store.readOperations('phone', segments.first.seq);
      expect(ops, hasLength(2));
      expect(ops.first.value, '回复张三报价');
    });

    test('段写满后自动封口另起新段', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');

      final many = List.generate(
        Segment.maxOpsPerSegment + 10,
        (i) => op('phone', 100 + i, 'i$i', 'title', 't$i'),
      );
      await store.append(many);

      final segments = await store.listSegments('phone');
      expect(segments, hasLength(2));
      expect(segments.first.opCount, Segment.maxOpsPerSegment);
      expect(segments.last.opCount, 10);
    });

    test('段头可单独解析，不必读段体', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');
      await store.append([op('phone', 100, 'i1', 'title', 'x')]);

      final segments = await store.listSegments('phone');
      expect(segments.first.deviceId, 'phone');
      expect(segments.first.keyEpoch, 1);
      expect(segments.first.payload, isEmpty, reason: '只解析了段头');
    });

    test('发现冲突文件时报错，不静默吞掉', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');
      await store.append([op('phone', 100, 'i1', 'title', 'x')]);

      File('${tmp.path}/ops/phone/000001.sync-conflict-20260905.log')
          .writeAsStringSync('{}\n');

      expect(() => store.listSegments('phone'), throwsStateError);
    });
  });

  group('两台设备经共享目录收敛', () {
    test('各写各的，同步后双方状态一致', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');

      // 手机改标签，电脑改截止时间——不同字段，都该保留
      await phone.push([op('phone', 100, 'i1', 'tags', '运维')]);
      await pc.push([op('pc', 101, 'i1', 'due_at', '2026-09-06')]);

      final r1 = await phone.syncOnce();
      final r2 = await pc.syncOnce();
      expect(r1.isOk, isTrue);
      expect(r2.isOk, isTrue);

      final phoneState = phone.materialize()[itemKey]!;
      final pcState = pc.materialize()[itemKey]!;
      expect(phoneState['tags'], '运维');
      expect(phoneState['due_at'], '2026-09-06');
      expect(phoneState, pcState, reason: '两端应完全收敛');
    });

    test('同字段并发按 HLC 决胜，两端结论一致', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');

      await phone.push([op('phone', 100, 'i1', 'priority', 'p3')]);
      await pc.push([op('pc', 200, 'i1', 'priority', 'p1')]);

      await phone.syncOnce();
      await pc.syncOnce();

      expect(phone.materialize()[itemKey]!['priority'], 'p1');
      expect(pc.materialize()[itemKey]!['priority'], 'p1');
    });

    test('重复同步不产生重复操作', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');

      await pc.push([op('pc', 100, 'i1', 'title', '只有一条')]);

      final first = (await phone.syncOnce()).valueOrNull!;
      expect(first.pulled, 1);

      final second = (await phone.syncOnce()).valueOrNull!;
      expect(second.pulled, 0, reason: '水位已记录，不该重复拉取');
      expect(phone.log.length, 1);
    });

    test('同段多次追加完整同步，反复同步不重复处理', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      final expected = <String, Object?>{};
      var count = 0;
      for (final (field, value) in [('title', '初次标题'), ('priority', 'p1'),
        ('due_at', '2026-09-06'), ('title', '后续修改标题')]) {
        expect((await pc.push([op('pc', 100 + count, 'i1', field, value)])).isOk, isTrue);
        final result = await phone.syncOnce();
        expect(result.isOk, isTrue);
        expect(result.valueOrNull!.pulled, 1);
        expected[field] = value;
        expect(phone.materialize()[itemKey], expected);
        expect(phone.log.length, ++count);
        expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
        expect(phone.log.length, count);
      }
      final segments = await pc.store.listSegments('pc');
      expect(segments.single.seq, 1);
      expect(segments.single.opCount, count);
    });

    test('补满水位段并换段后，先回收也不会丢失尚未拉取的段尾', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push([op('pc', 100, 'first', 'title', '首条')]);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      await pc.push(List.generate(Segment.maxOpsPerSegment,
        (i) => op('pc', 200 + i, 'tail$i', 'title', '追加$i')));
      expect((await pc.store.listSegments('pc')).map((s) => s.seq), [1, 2]);
      expect(await pc.store.reclaim(members: ['pc', 'phone']), 0,
        reason: 'phone 只读过第1段前缀，不能回收后追加的段尾');
      expect((await phone.syncOnce()).valueOrNull!.pulled, Segment.maxOpsPerSegment);
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
      expect(phone.materialize(), pc.materialize());
      expect(await pc.store.reclaim(members: ['pc', 'phone']), 0);
      expect((await pc.store.listSegments('pc')).map((s) => s.seq), [1, 2]);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
    });

    test('较新段先到时不越过未封口段，段尾到达后完整同步', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push([op('pc', 100, 'first', 'title', '首条')]);
      final file = File('${tmp.path}/ops/pc/202609-0001.log');
      final prefix = await file.readAsBytes();
      await pc.push(List.generate(Segment.maxOpsPerSegment,
        (i) => op('pc', 200 + i, 'tail$i', 'title', '追加$i')));
      final complete = await file.readAsBytes();
      await file.writeAsBytes(prefix);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      expect((await phone.store.readAck('phone'))['pc'], 1);
      expect(phone.log.length, 1);
      await file.writeAsBytes(complete);
      expect((await phone.syncOnce()).valueOrNull!.pulled, Segment.maxOpsPerSegment);
      expect(phone.materialize(), pc.materialize());
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
    });

    test('段内容少于声明条数时不应用或确认，完整后重试仅处理一次', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push([op('pc', 100, 'i1', 'title', '完整修改')]);
      final file = File('${tmp.path}/ops/pc/202609-0001.log');
      final valid = await file.readAsBytes();
      final segment = Segment.decode(valid);
      await file.writeAsBytes(Segment(deviceId: segment.deviceId,
        keyEpoch: segment.keyEpoch, seq: segment.seq, opCount: segment.opCount + 1,
        createdAt: segment.createdAt, payload: segment.payload).encode());
      expect((await phone.syncOnce()).isOk, isFalse);
      expect(phone.log.length, 0);
      expect(await phone.store.readAck('phone'), isEmpty);
      await file.writeAsBytes(valid);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      expect(phone.materialize(), pc.materialize());
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect(phone.log.length, 1);
    });

    test('日志段乱序到达时保留缺口，补齐后不漏不重', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push(List.generate(Segment.maxOpsPerSegment + 1,
        (i) => op('pc', 100 + i, 'i$i', 'title', '修改$i')));
      final first = File('${tmp.path}/ops/pc/202609-0001.log');
      final pending = await first.rename('${first.path}.pending');
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect(await phone.store.readAck('phone'), isEmpty);
      expect(phone.log.length, 0);
      await pending.rename(first.path);
      expect((await phone.syncOnce()).valueOrNull!.pulled, Segment.maxOpsPerSegment + 1);
      expect(phone.materialize(), pc.materialize());
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
    });

    test('后段读取失败不推进文件水位，修复重试不重复处理前段', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push(List.generate(Segment.maxOpsPerSegment + 1,
        (i) => op('pc', 100 + i, 'i$i', 'title', '修改$i')));
      final file = File('${tmp.path}/ops/pc/202609-0002.log');
      final valid = await file.readAsBytes();
      final corrupt = List<int>.from(valid);
      corrupt[corrupt.length - 1] = 33;
      await file.writeAsBytes(corrupt);
      expect((await phone.syncOnce()).isOk, isFalse);
      expect(await phone.store.readAck('phone'), isEmpty);
      expect(phone.log.length, Segment.maxOpsPerSegment);
      await file.writeAsBytes(valid);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      expect(phone.materialize(), pc.materialize());
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
      expect((await phone.store.readAck('phone'))['pc'], 2);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
    });

    test('重新打开目录复用已知日志时，文件水位不跳过同段后续修改', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push([op('pc', 100, 'i1', 'title', '原来标题')]);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      final known = OpLog()..appendAll(phone.log.all);
      final reopened = SyncEngine(store: storeFor('phone'), log: known);
      await reopened.store.init(vaultPublicId: 'v1');
      expect((await reopened.store.readAck('phone'))['pc'], 1);
      await pc.push([op('pc', 101, 'i1', 'priority', 'p1')]);
      expect((await reopened.syncOnce()).valueOrNull!.pulled, 1);
      expect(reopened.materialize(), pc.materialize());
      expect(reopened.log.length, 2);
      expect((await reopened.store.readAck('phone'))['pc'], 1);
      expect((await reopened.syncOnce()).valueOrNull!.pulled, 0);
      expect(reopened.log.length, 2);
    });

    test('两端持续同段追加并重复发送，状态收敛且每个操作只处理一次', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      for (var i = 0; i < 4; i++) {
        await phone.push([op('phone', 100 + i * 2, 'i1', 'title', '手机标题$i')]);
        await pc.push([op('pc', 101 + i * 2, 'i1', 'tags', '电脑标签$i')]);
        expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
        expect((await pc.syncOnce()).valueOrNull!.pulled, 1);
        expect(phone.materialize()[itemKey], {'title': '手机标题$i', 'tags': '电脑标签$i'});
        expect(phone.materialize(), pc.materialize());
        expect(phone.log.length, (i + 1) * 2);
        expect(pc.log.length, phone.log.length);
        expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
        expect((await pc.syncOnce()).valueOrNull!.pulled, 0);
      }
      await phone.push([phone.log.ofDevice('phone').first]);
      await pc.push([pc.log.ofDevice('pc').first]);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect((await pc.syncOnce()).valueOrNull!.pulled, 0);
      expect(phone.log.length, 8);
      expect(pc.log.length, 8);
      expect(phone.materialize(), pc.materialize());
      expect((await phone.store.listSegments('phone')).single.opCount, 5);
      expect((await pc.store.listSegments('pc')).single.opCount, 5);
    });

    test('已读水位段暂缺时等待重读，补齐前不确认后段或回收尾部', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');
      await pc.push([op('pc', 100, 'first', 'title', '首条')]);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 1);
      await pc.push(List.generate(Segment.maxOpsPerSegment,
        (i) => op('pc', 200 + i, 'tail$i', 'title', '追加$i')));
      final first = File('${tmp.path}/ops/pc/202609-0001.log');
      final pending = await first.rename('${first.path}.pending');
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
      expect((await phone.store.readAck('phone'))['pc'], 1);
      expect(phone.log.length, 1);
      await pending.rename(first.path);
      expect(await pc.store.reclaim(members: ['pc', 'phone']), 0);
      expect((await phone.syncOnce()).valueOrNull!.pulled, Segment.maxOpsPerSegment);
      expect(phone.materialize(), pc.materialize());
      expect(phone.log.length, Segment.maxOpsPerSegment + 1);
      expect(await pc.store.reclaim(members: ['pc', 'phone']), 0);
      expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
    });

    test('水位记录到 acks 目录', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');

      await pc.push([op('pc', 100, 'i1', 'title', 'x')]);
      await phone.syncOnce();

      final ack = await phone.store.readAck('phone');
      expect(ack['pc'], 1);
    });

    test('删除用 tombstone，同步后对象消失', () async {
      final phone = SyncEngine(store: storeFor('phone'), log: OpLog());
      final pc = SyncEngine(store: storeFor('pc'), log: OpLog());
      await phone.store.init(vaultPublicId: 'v1');
      await pc.store.init(vaultPublicId: 'v1');

      await phone.push([op('phone', 100, 'i1', 'title', '要被删的')]);
      await pc.syncOnce();
      expect(pc.materialize().containsKey(itemKey), isTrue);

      await pc.push([op('pc', 200, 'i1', Operation.tombstoneField, null)]);
      await phone.syncOnce();
      expect(phone.materialize().containsKey(itemKey), isFalse);
    });
  });

  group('段回收', () {
    test('即使全体已确认，无覆盖快照仍保留全部段', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');

      // 写满两段再加一点，得到 3 个段
      await store.append(List.generate(Segment.maxOpsPerSegment,
          (i) => op('phone', 100 + i, 'a$i', 'f', i)));
      await store.append(List.generate(Segment.maxOpsPerSegment,
          (i) => op('phone', 2000 + i, 'b$i', 'f', i)));
      await store.append([op('phone', 5000, 'c', 'f', 1)]);
      expect(await store.listSegments('phone'), hasLength(3));

      // 对端读到第 2 段，其尾部可能仍会追加，只能确认第 1 段。
      final pc = storeFor('pc');
      await pc.init(vaultPublicId: 'v1');
      await pc.writeSelfAck({'phone': 2});

      final removed = await store.reclaim(members: ['phone', 'pc']);
      expect(removed, 0);
      expect((await store.listSegments('phone')).map((s) => s.seq), [1, 2, 3]);
      await pc.writeSelfAck({'phone': 3});
      expect(await store.reclaim(members: ['phone', 'pc']), 0);
      expect((await store.listSegments('phone')).map((s) => s.seq), [1, 2, 3]);
    });

    test('对端未确认时不回收', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');
      await store.append(List.generate(Segment.maxOpsPerSegment,
          (i) => op('phone', 100 + i, 'a$i', 'f', i)));
      await store.append([op('phone', 5000, 'c', 'f', 1)]);

      final pc = storeFor('pc');
      await pc.init(vaultPublicId: 'v1');
      await pc.writeSelfAck({'phone': 0});

      expect(await store.reclaim(members: ['phone', 'pc']), 0);
    });

    test('超过 TTL 但无人确认且无快照，仍保留旧段', () async {
      final store = storeFor('phone');
      await store.init(vaultPublicId: 'v1');
      await store.append(List.generate(Segment.maxOpsPerSegment,
          (i) => op('phone', 100 + i, 'a$i', 'f', i)));

      clock.advance(const Duration(days: 40));
      await store.append([op('phone', 5000, 'c', 'f', 1)]);

      final pc = storeFor('pc');
      await pc.init(vaultPublicId: 'v1');
      await pc.writeSelfAck({'phone': 0});

      final removed =
          await store.reclaim(members: ['phone', 'pc'], ttl: const Duration(days: 30));
      expect(removed, 0);
      expect(await store.listSegments('phone'), hasLength(2));
    });
  });
}
