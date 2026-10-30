import 'dart:io';

import 'package:seqpoint_core/src/sync/sync_files.dart';
import 'package:test/test.dart';

void main() {
  test(
    'atomic cache IO rejects traversal, symbolic links and oversized reads',
    () async {
      final root = await Directory.systemTemp.createTemp('sync-files-');
      addTearDown(() => root.delete(recursive: true));
      final files = SyncFiles(root);
      await files.write('cache/a.bin', [1, 2, 3]);
      expect(await files.read('cache/a.bin', limit: 3), [1, 2, 3]);
      await expectLater(files.read('cache/a.bin', limit: 2), throwsStateError);
      expect(() => files.file('../escape'), throwsArgumentError);
      await Link('${root.path}/link').create(root.path);
      expect(() => files.file('link/escape'), throwsStateError);
      var accept = true;
      final guarded = SyncFiles(
        root,
        guard: () {
          if (!accept) throw StateError('paused');
        },
      );
      accept = false;
      await expectLater(guarded.write('cache/a.bin', [4]), throwsStateError);
      expect(await files.read('cache/a.bin', limit: 3), [1, 2, 3]);
    },
  );
}
