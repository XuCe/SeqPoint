import 'dart:io';

import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

class _RevokingFolder extends FolderTransport {
  _RevokingFolder(
    super.root, {
    required super.writerDeviceId,
    required this.revoke,
  });
  final void Function() revoke;
  bool fired = false;
  @override
  Future<Result<void>> put(
    String path,
    List<int> bytes, {
    void Function()? guard,
  }) {
    return super.put(
      path,
      bytes,
      guard: () {
        if (!fired &&
            path.startsWith('ops/') &&
            root
                .listSync(recursive: true)
                .any((f) => f.path.contains('.tmp.'))) {
          fired = true;
          revoke();
        }
        guard?.call();
      },
    );
  }
}

void main() {
  test(
    'revocation before final export rename prevents a new publication',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      final shared = Directory('${f.root.path}/shared');
      final transport = _RevokingFolder(
        shared,
        writerDeviceId: f.a.keys.deviceId,
        revoke: () => f.a.version = Object(),
      );
      f.a.addOperations(1);
      expect((await f.a.runtime.syncFolder(transport)).isOk, isFalse);
      expect(transport.fired, isTrue);
      final files = await shared
          .list(recursive: true)
          .where((f) => f is File)
          .toList();
      expect(files.where((f) => f.path.endsWith('.log')), isEmpty);
      expect(files.where((f) => f.path.contains('.tmp.')), isEmpty);
    },
  );
}
