import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:seqpoint_core/src/sync/transport/lan_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final own = 'a' * 43, peer = 'b' * 43;
  late FolderTransport transport;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('seqpoint-folder-');
    transport = FolderTransport(root, writerDeviceId: own);
  });
  tearDown(() => root.delete(recursive: true));
  test(
    'prunes more than 1024 covered own segments without touching peers',
    () async {
      final ownDir = Directory('${root.path}/ops/$own')
        ..createSync(recursive: true);
      for (var seq = 1; seq <= 1026; seq++) {
        File('${ownDir.path}/202610-${seq.toString().padLeft(4, '0')}.log')
            .writeAsBytesSync([1]);
      }
      final peerFile = File('${root.path}/ops/$peer/202610-0001.log');
      peerFile.parent.createSync(recursive: true);
      peerFile.writeAsBytesSync([2]);
      expect((await transport.list('ops/$own')).isOk, isFalse);
      expect((await transport.pruneOperations(1025)).isOk, isTrue);
      expect(
        (await transport.list('ops/$own')).valueOrNull!.single.name,
        '202610-1026.log',
      );
      expect(await peerFile.readAsBytes(), [2]);
    },
  );
  test(
    'bounded reads, writes and lists reject oversized publications',
    () async {
      transport = FolderTransport(
        root,
        writerDeviceId: own,
        limits: LanLimits(maxFileBytes: 2, maxFiles: 1),
      );
      final path = 'ops/$own/202610-0001.log';
      expect((await transport.put(path, [1, 2, 3])).isOk, isFalse);
      await File('${root.path}/$path').parent.create(recursive: true);
      await File('${root.path}/$path').writeAsBytes([1, 2, 3]);
      expect((await transport.get(path)).isOk, isFalse);
      expect((await transport.list('ops/$own')).isOk, isFalse);
      await File('${root.path}/$path').writeAsBytes([1]);
      await File('${root.path}/ops/$own/202610-0002.log').writeAsBytes([2]);
      expect((await transport.list('ops/$own')).isOk, isFalse);
    },
  );
  test(
    'parent links cannot escape and identical publication is not rewritten',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'seqpoint-outside-',
      );
      try {
        await Link('${root.path}/content').create(outside.path);
        final path = 'content/$own/${'0' * 64}.bin';
        expect((await transport.put(path, [1])).isOk, isFalse);
        expect((await transport.list('content/$own')).isOk, isFalse);
        expect(await outside.list().isEmpty, isTrue);
        final ownPath = 'members/$own.json';
        await transport.put(ownPath, [1]);
        final file = File('${root.path}/$ownPath');
        final stamp = DateTime.utc(2020);
        await file.setLastModified(stamp);
        expect((await transport.put(ownPath, [1])).isOk, isTrue);
        expect((await file.lastModified()).toUtc(), stamp);
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
  test('only own publications can be written or deleted', () async {
    final path = 'ops/$own/202610-0001.log';
    expect((await transport.put(path, [1, 2])).isOk, isTrue);
    expect((await transport.get(path)).valueOrNull, [1, 2]);
    expect(
      (await transport.list('ops/$own')).valueOrNull!.single.name,
      '202610-0001.log',
    );
    for (final invalid in [
      '../escape',
      'database.sqlite',
      'ops/$peer/202610-0001.log',
      'members/$peer.json',
    ]) {
      expect((await transport.put(invalid, [1])).isOk, isFalse);
      expect((await transport.delete(invalid)).isOk, isFalse);
    }
    expect((await transport.delete(path)).isOk, isTrue);
    expect((await transport.get(path)).isOk, isFalse);
  });
  test('conflict copies, temporary files and links are not listed', () async {
    final path = 'ops/$peer';
    await Directory('${root.path}/$path').create(recursive: true);
    for (final name in [
      '202610-0001.log',
      '202610-0001.sync-conflict.log',
      '.syncthing.tmp',
      '202610-0002.log.tmp',
    ]) {
      await File('${root.path}/$path/$name').writeAsBytes([3]);
    }
    await Link('${root.path}/$path/202610-0003.log')
        .create('${root.path}/$path/202610-0001.log');
    expect((await transport.list(path)).valueOrNull!.map((f) => f.name), [
      '202610-0001.log',
    ]);
    expect((await transport.get('$path/202610-0003.log')).isOk, isFalse);
    expect(
      (await transport.get('$path/202610-0001.sync-conflict.log')).isOk,
      isFalse,
    );
  });
}
