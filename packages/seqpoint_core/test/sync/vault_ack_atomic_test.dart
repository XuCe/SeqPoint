import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('ACK半写失败保留旧字节并清临时文件，重试原子替换', () async {
    final root = Directory.systemTemp.createTempSync('seqpoint_ack_atomic_');
    addTearDown(() => root.deleteSync(recursive: true));
    final normal = VaultStore(root: root, deviceId: 'pc', codec: const PlainSegmentCodec());
    await normal.writeSelfAck({'phone': 1});
    final file = File('${root.path}/acks/pc.json'), old = await File('${root.path}/acks/pc.json').readAsBytes();
    final failing = VaultStore(root: root, deviceId: 'pc', codec: const PlainSegmentCodec(),
        writeAckBytes: (temp, bytes) async {
      expect(temp.path, isNot(file.path)); expect(temp.parent.path, file.parent.path);
      await temp.writeAsBytes(bytes.take(bytes.length ~/ 2).toList(), flush: true);
      throw const FileSystemException('forced partial ACK');
    });
    await expectLater(failing.writeSelfAck({'phone': 2}), throwsA(isA<FileSystemException>()));
    expect(await file.readAsBytes(), old);
    expect(file.parent.listSync(), hasLength(1));
    expect(await normal.readAck('pc'), {'phone': 1});
    await normal.writeSelfAck({'phone': 2});
    expect(await normal.readAck('pc'), {'phone': 2});
    expect(file.parent.listSync(), hasLength(1));
  });
}
