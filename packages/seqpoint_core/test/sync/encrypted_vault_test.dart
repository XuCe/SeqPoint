import 'dart:convert';
import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late DeviceKeys a, b;
  late VaultStore sender, receiver;
  late Operation op;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('seqpoint_encrypted_');
    a = await DeviceKeys.fromSeeds(List.filled(32, 1), List.filled(32, 2));
    b = await DeviceKeys.fromSeeds(List.filled(32, 3), List.filled(32, 4));
    VaultStore store(DeviceKeys keys) => VaultStore(root: root,
        deviceId: keys.deviceId, codec: EncryptedSegmentCodec(
          vaultPublicId: 'v1', deviceKeys: keys, epochKeys: {1: List.filled(32, 7)},
          trustedSigners: {a.deviceId: a.signer.publicKey, b.deviceId: b.signer.publicKey}));
    sender = store(a);
    receiver = store(b);
    await sender.init(vaultPublicId: 'v1');
    await receiver.init(vaultPublicId: 'v1');
    op = Operation(opId: 'op1', deviceId: a.deviceId,
        hlc: Hlc(millis: 1, counter: 0, deviceId: a.deviceId), objectType: 'note',
        objectId: 'n1', field: 'raw_content', value: '仅测试内容');
    await sender.append([op]);
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('伪造封口不产生新段，不应用操作或写ACK；修复后可重试', () async {
    final file = Directory('${root.path}/ops/${a.deviceId}').listSync().whereType<File>().single;
    final valid = await file.readAsBytes();
    final lines = utf8.decode(valid).split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    await file.writeAsBytes(utf8.encode('${jsonEncode({...header, 'sealed': true})}\n${lines.last}'));
    await expectLater(sender.append([op]), throwsStateError);
    expect(file.parent.listSync(), hasLength(1));
    final engine = SyncEngine(store: receiver, log: OpLog());
    expect((await engine.syncOnce()).isOk, isFalse);
    expect(engine.log.length, 0);
    expect(await receiver.readAck(b.deviceId), isEmpty);
    await file.writeAsBytes(valid);
    expect((await engine.syncOnce()).valueOrNull!.pulled, 1);
    expect((await engine.syncOnce()).valueOrNull!.pulled, 0);
  });
  test('扫描后跨月封口，单次认证读取返回一致header/操作/原字节快照', () async {
    final scanned = (await receiver.listSegments(a.deviceId)).single;
    expect(scanned.isSealed, isFalse);
    final later = VaultStore(root: root, deviceId: a.deviceId, codec: sender.codec,
        clock: FakeClock(DateTime.utc(scanned.createdAt.year, scanned.createdAt.month + 1)));
    final next = Operation(opId: 'op2', deviceId: a.deviceId,
        hlc: Hlc(millis: 1, counter: 1, deviceId: a.deviceId), objectType: 'note',
        objectId: 'n1', field: 'raw_content', value: '第二条');
    await later.append([next]);
    final verified = (await receiver.readVerifiedSegment(a.deviceId, 1))!;
    expect(verified.segment.isSealed, isTrue);
    expect(verified.segment.opCount, 1);
    expect(verified.operations.single.opId, 'op1');
    expect(verified.bytes, verified.segment.encode());
    expect(() => verified.bytes[0] = 0, throwsUnsupportedError);
    expect(() => verified.operations.add(next), throwsUnsupportedError);
    expect(() => verified.segment.payload[0] = 0, throwsUnsupportedError);
    expect(await receiver.readVerifiedSegment(a.deviceId, 99), isNull);
  });
  test('认证读取拒绝扫描后伪造header，不把扫描结果当验签', () async {
    await receiver.listSegments(a.deviceId);
    final file = Directory('${root.path}/ops/${a.deviceId}').listSync().whereType<File>().single;
    final lines = utf8.decode(await file.readAsBytes()).split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    await file.writeAsBytes(utf8.encode('${jsonEncode({...header, 'sealed': true})}\n${lines.last}'));
    await expectLater(receiver.readVerifiedSegment(a.deviceId, 1), throwsStateError);
  });
}
