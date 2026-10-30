import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

Operation op(int number) => Operation(opId: 'op$number', deviceId: 'pc',
    hlc: Hlc(millis: number, counter: 0, deviceId: 'pc'), objectType: 'note',
    objectId: 'n1', field: 'raw_content', value: '内容$number');

void main() {
  test('半写失败保留旧段，清理暂存；重试发布完整版本', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_atomic_');
    addTearDown(() => root.deleteSync(recursive: true));
    final normal = VaultStore(root: root, deviceId: 'pc',
        codec: const PlainSegmentCodec());
    await normal.init(vaultPublicId: 'v1');
    await normal.append([op(1)]);
    final file = Directory('${root.path}/ops/pc').listSync().whereType<File>().single;
    final old = await file.readAsBytes();
    final failing = VaultStore(root: root, deviceId: 'pc',
        codec: const PlainSegmentCodec(), writeSegmentBytes: (temp, bytes) async {
      expect(temp.path, isNot(file.path));
      expect(temp.parent.path, file.parent.path);
      await temp.writeAsBytes(bytes.take(bytes.length ~/ 2).toList(), flush: true);
      throw const FileSystemException('forced partial write');
    });
    await expectLater(failing.append([op(2)]), throwsA(isA<FileSystemException>()));
    expect(await file.readAsBytes(), old);
    expect(Directory('${root.path}/ops/pc').listSync(), hasLength(1));
    expect((await normal.readOperations('pc', 1)).map((o) => o.opId), ['op1']);
    await normal.append([op(2)]);
    expect((await normal.readOperations('pc', 1)).map((o) => o.opId), ['op1', 'op2']);
    expect(Directory('${root.path}/ops/pc').listSync(), hasLength(1));
  });
  test('扫描和读取绑定作者/序号路径，拒绝目录穿越', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_paths_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = VaultStore(root: root, deviceId: 'pc', codec: const PlainSegmentCodec());
    await store.init(vaultPublicId: 'v1');
    await store.append([op(1)]);
    final file = Directory('${root.path}/ops/pc').listSync().whereType<File>().single;
    final old = await file.readAsBytes();
    final moved = await file.rename('${file.parent.path}/000002.log');
    await expectLater(store.listSegments('pc'), throwsStateError);
    await moved.rename(file.path);
    final segment = Segment.decode(old);
    await file.writeAsBytes(Segment(deviceId: 'phone', keyEpoch: 1, seq: 1,
        opCount: 1, createdAt: segment.createdAt, payload: segment.payload).encode());
    await expectLater(store.listSegments('pc'), throwsStateError);
    await expectLater(store.readOperations('pc', 1), throwsStateError);
    await expectLater(store.listSegments('../pc'), throwsArgumentError);
    await expectLater(store.readOperations('../pc', 1), throwsArgumentError);
    expect(() => VaultStore(root: root, deviceId: '..',
        codec: const PlainSegmentCodec()), throwsArgumentError);
  });
  test('超限文件在读取正文或段头前拒绝', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_size_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = VaultStore(root: root, deviceId: 'pc', codec: const PlainSegmentCodec());
    await store.init(vaultPublicId: 'v1');
    await store.append([op(1)]);
    final file = Directory('${root.path}/ops/pc').listSync().whereType<File>().single;
    final handle = await file.open(mode: FileMode.append);
    await handle.truncate(VaultStore.maxSegmentFileBytes + 1);
    await handle.close();
    await expectLater(store.listSegments('pc'), throwsStateError);
    await expectLater(store.readOperations('pc', 1), throwsStateError);
  });
  test('V1月份加序号命名，跨月封口且序号不重用', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_month_');
    addTearDown(() => root.deleteSync(recursive: true));
    final clock = FakeClock(DateTime.utc(2026, 9, 30));
    final store = VaultStore(root: root, deviceId: 'pc',
        codec: const PlainSegmentCodec(), clock: clock);
    await store.init(vaultPublicId: 'v1');
    await store.append([op(1)]);
    final first = File('${root.path}/ops/pc/202609-0001.log');
    expect(await first.exists(), isTrue);
    clock.set(DateTime.utc(2026, 10, 1));
    await store.append([op(2)]);
    expect(Segment.decode(await first.readAsBytes()).isSealed, isTrue);
    expect(await File('${root.path}/ops/pc/202610-0002.log').exists(), isTrue);
    expect((await store.readOperations('pc', 1)).single.opId, 'op1');
    expect((await store.readOperations('pc', 2)).single.opId, 'op2');
  });
  test('跨月后仍等待旧月封口版本，不能跳过尚未到达的尾部', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_month_tail_');
    addTearDown(() => root.deleteSync(recursive: true));
    final clock = FakeClock(DateTime.utc(2026, 9, 30));
    final pc = SyncEngine(store: VaultStore(root: root, deviceId: 'pc',
        codec: const PlainSegmentCodec(), clock: clock), log: OpLog());
    final phone = SyncEngine(store: VaultStore(root: root, deviceId: 'phone',
        codec: const PlainSegmentCodec(), clock: clock), log: OpLog());
    await pc.store.init(vaultPublicId: 'v1');
    await phone.store.init(vaultPublicId: 'v1');
    await pc.push([op(1)]);
    final first = File('${root.path}/ops/pc/202609-0001.log');
    final prefix = await first.readAsBytes();
    await phone.syncOnce();
    await pc.push([op(2)]);
    clock.set(DateTime.utc(2026, 10, 1));
    await pc.push([op(3)]);
    final sealed = await first.readAsBytes();
    await first.writeAsBytes(prefix);
    expect((await phone.syncOnce()).valueOrNull!.pulled, 0);
    expect((await phone.store.readAck('phone'))['pc'], 1);
    await first.writeAsBytes(sealed);
    expect((await phone.syncOnce()).valueOrNull!.pulled, 2);
    expect(phone.log.length, 3);
    expect((await phone.store.readAck('phone'))['pc'], 2);
  });
  test('拒绝段文件与作者目录符号链接', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_links_');
    addTearDown(() => root.deleteSync(recursive: true));
    final store = VaultStore(root: root, deviceId: 'pc', codec: const PlainSegmentCodec());
    await store.init(vaultPublicId: 'v1');
    await store.append([op(1)]);
    final file = Directory('${root.path}/ops/pc').listSync().whereType<File>().single;
    final external = File('${root.path}/outside.log')..writeAsStringSync('fixture');
    await file.delete();
    await Link(file.path).create(external.path);
    await expectLater(store.listSegments('pc'), throwsStateError);
    await expectLater(store.readOperations('pc', 1), throwsStateError);
    await Link(file.path).delete();
    await file.parent.delete();
    final folder = await Directory('${root.path}/outside').create();
    await Link(file.parent.path).create(folder.path);
    await expectLater(store.append([op(2)]), throwsStateError);
    await expectLater(store.listSegments('pc'), throwsStateError);
    expect(await folder.list().isEmpty, isTrue);
  }, skip: Platform.isWindows ? 'Windows需创建符号链接权限，待原生验收' : false);
}
