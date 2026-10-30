import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late VaultStore store;
  const codec = PlainSegmentCodec(); // 编排夹具，实际认证另用加密codec验证。
  const name = '202610-0001.log';
  final op = Operation(opId: 'writer:0', deviceId: 'writer',
      hlc: const Hlc(millis: 1, counter: 0, deviceId: 'writer'),
      objectType: 'note', objectId: 'n', field: 'raw_content', value: 'x');
  Future<List<int>> bytes({bool sealed = false}) async => (await codec.encode(Segment(
      deviceId: 'writer', keyEpoch: 1, seq: 1, opCount: 1,
      createdAt: DateTime.utc(2026, 10, 25), sealed: sealed, payload: const []), [op])).encode();
  File getFile() => File('${root.path}/ops/writer/$name');
  setUp(() {
    root = Directory.systemTemp.createTempSync('prepared-file-');
    store = VaultStore(root: root, deviceId: 'writer', codec: codec);
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('陌生旁文件/目录与伪暂存文件必须停止发布', () async {
    getFile().parent.createSync(recursive: true);
    final original = await bytes();
    for (final entry in [
      (name: 'unknown.txt', directory: false),
      (name: 'unknown', directory: true),
      (name: '$name.tmp.invalid', directory: false),
      (name: '$name.tmp.${newId()}', directory: true),
      (name: '202610-0002.log.tmp.${newId()}', directory: false),
    ]) {
      final path = '${getFile().parent.path}/${entry.name}';
      final FileSystemEntity unexpected;
      if (entry.directory) {
        unexpected = Directory(path)..createSync();
      } else {
        unexpected = File(path)..createSync();
      }
      expect(() => store.checkSelfHistory({name}), throwsStateError, reason: entry.name);
      await expectLater(store.writePrepared(fileName: name, bytes: original,
          knownFileNames: {name}, commit: (_, _) => fail('陌生条目不能提交')), throwsStateError);
      expect(getFile().existsSync(), isFalse);
      unexpected.deleteSync();
    }
  });
  test('崩溃遗留的已知段UUID暂存文件不阻止原bytes恢复', () async {
    getFile().parent.createSync(recursive: true);
    final leftover = File('${getFile().path}.tmp.${newId()}')..writeAsBytesSync([1]);
    final original = await bytes();
    expect(store.checkSelfHistory({name}), isEmpty);
    await store.writePrepared(fileName: name, bytes: original, knownFileNames: {name},
        commit: (_, replace) => replace());
    expect(getFile().readAsBytesSync(), original);
    expect(store.checkSelfHistory({name}), {name});
    expect(leftover.existsSync(), isTrue);
  });
  test('原prepared字节认证后暂存，提交回调内同步替换，重试保持原bytes', () async {
    final original = await bytes();
    for (var i = 0; i < 2; i++) {
      await store.writePrepared(fileName: name, bytes: original, knownFileNames: {name},
          commit: (operations, replace) { expect(operations.single.opId, op.opId); replace(); });
      expect(getFile().readAsBytesSync(), original);
    }
    expect(store.checkSelfHistory({name}), {name});
  });
  test('文件写入失败保留旧文件且清理暂存，不执行commit', () async {
    getFile().parent.createSync(recursive: true); getFile().writeAsBytesSync(await bytes());
    final failing = VaultStore(root: root, deviceId: 'writer', codec: codec,
        writeSegmentBytes: (file, data) async { await file.writeAsBytes([1]); throw StateError('injected'); });
    await expectLater(failing.writePrepared(fileName: name, bytes: await bytes(sealed: true),
        knownFileNames: {name}, commit: (_, _) => fail('不能提交')), throwsStateError);
    expect(getFile().readAsBytesSync(), await bytes());
    expect(getFile().parent.listSync(), hasLength(1));
  });
  test('静默短写与超过文件上限均不能commit或落正式文件', () async {
    final short = VaultStore(root: root, deviceId: 'writer', codec: codec,
        writeSegmentBytes: (file, data) async { await file.writeAsBytes([1]); });
    await expectLater(short.writePrepared(fileName: name, bytes: await bytes(),
        knownFileNames: {name}, commit: (_, _) => fail('短写不能提交')), throwsStateError);
    expect(getFile().existsSync(), isFalse); expect(getFile().parent.listSync(), isEmpty);
    await expectLater(store.writePrepared(fileName: name,
        bytes: List.filled(VaultStore.maxSegmentFileBytes + 1, 0), knownFileNames: {name},
        commit: (_, _) => fail('超限不能提交')), throwsStateError);
  });
  test('真实加密prepared须通过认证，密文篡改不能替换原文件', () async {
    final keys = await DeviceKeys.fromSeeds(List.filled(32, 11), List.filled(32, 12));
    final secure = EncryptedSegmentCodec(vaultPublicId: 'prepared-file', deviceKeys: keys,
        epochKeys: {1: List.filled(32, 13)}, trustedSigners: {keys.deviceId: keys.signer.publicKey});
    final own = Operation(opId: '${keys.deviceId}:0', deviceId: keys.deviceId,
        hlc: Hlc(millis: 1, counter: 0, deviceId: keys.deviceId),
        objectType: 'note', objectId: 'n', field: 'raw_content', value: 'x');
    final encoded = await secure.encode(Segment(deviceId: keys.deviceId, keyEpoch: 1,
        seq: 1, opCount: 1, createdAt: DateTime.utc(2026, 10, 25), payload: const []), [own]);
    final target = VaultStore(root: root, deviceId: keys.deviceId, codec: secure);
    await target.writePrepared(fileName: name, bytes: encoded.encode(), knownFileNames: {name},
        commit: (_, replace) => replace());
    final corrupted = encoded.withPayload([...encoded.payload]..[0] ^= 1,
        signature: encoded.signature).encode();
    await expectLater(target.writePrepared(fileName: name, bytes: corrupted, knownFileNames: {name},
        commit: (_, _) => fail('认证失败不能提交')), throwsStateError);
    expect(File('${root.path}/ops/${keys.deviceId}/$name').readAsBytesSync(), encoded.encode());
  });
  test('陌生/空段文件不能按最大序号采用', () {
    getFile().parent.createSync(recursive: true); getFile().writeAsBytesSync([]);
    expect(() => store.checkSelfHistory({}), throwsStateError);
  });
  test('只允许相同原bytes重试或认证开放前缀增长/封口，封口后不可变', () async {
    final original = await bytes(), sealed = await bytes(sealed: true);
    await store.writePrepared(fileName: name, bytes: original, knownFileNames: {name},
        commit: (_, replace) => replace());
    final different = Operation.fromJson({...op.toJson(), 'value': 'changed'});
    final bad = (await codec.encode(Segment.decode(original), [different])).encode();
    await expectLater(store.writePrepared(fileName: name, bytes: bad, knownFileNames: {name},
        commit: (_, _) => fail('前缀变值不能提交')), throwsStateError);
    expect(getFile().readAsBytesSync(), original);
    await store.writePrepared(fileName: name, bytes: sealed, knownFileNames: {name},
        commit: (_, replace) => replace());
    await expectLater(store.writePrepared(fileName: name, bytes: original, knownFileNames: {name},
        commit: (_, _) => fail('封口不能回退')), throwsStateError);
    expect(getFile().readAsBytesSync(), sealed);
  });
  test('prepared路径须匹配作者月份和序号，目录不能是链接或同名文件夹', () async {
    await expectLater(store.writePrepared(fileName: '../wrong.log', bytes: await bytes(),
        knownFileNames: {'../wrong.log'}, commit: (_, _) => fail('路径错误')), throwsStateError);
    getFile().createSync(recursive: true);
    getFile().deleteSync(); Directory(getFile().path).createSync();
    expect(() => store.checkSelfHistory({name}), throwsStateError);
    Directory(getFile().path).deleteSync();
    Link(getFile().path).createSync('${root.path}/missing');
    expect(() => store.checkSelfHistory({name}), throwsStateError);
  });
  test('暂存期间目标或目录变化时停止，保留变化后的现场并清理暂存', () async {
    for (final unknown in [false, true]) {
      getFile().parent.createSync(recursive: true); getFile().writeAsBytesSync(await bytes());
      final racing = VaultStore(root: root, deviceId: 'writer', codec: codec,
          writeSegmentBytes: (file, data) async {
        await file.writeAsBytes(data, flush: true);
        if (unknown) { File('${getFile().parent.path}/202610-0002.log').writeAsBytesSync([]); }
        else { getFile().writeAsBytesSync([3]); }
      });
      await expectLater(racing.writePrepared(fileName: name, bytes: await bytes(sealed: true),
          knownFileNames: {name}, commit: (_, replace) => replace()), throwsStateError);
      expect(getFile().readAsBytesSync(), unknown ? await bytes() : [3]);
      expect(getFile().parent.listSync().where((f) => f.path.contains('.tmp.')), isEmpty);
    }
  });
}
