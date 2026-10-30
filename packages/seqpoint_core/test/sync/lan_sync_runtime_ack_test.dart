import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';

void main() {
  test('corrupted ACK temporary bytes are never renamed or trusted', () async {
    final f = RuntimeFixture();
    await f.init();
    addTearDown(f.dispose);
    await f.start();
    f.b.ackWriter = (file, _) async {
      await file.writeAsBytes([1, 2, 3]);
    };
    final result = await f.b.runtime.syncOnce(f.peer(f.a));
    expect(result.isOk, isFalse);
    expect(
      File('${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json')
          .existsSync(),
      isFalse,
    );
  });

  test(
    'ACK disk failure retains committed receipts and retries database truth',
    () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      f.a.addOperations(500);
      await f.start();
      expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
      f.b.ackWriter = (_, _) async {
        throw FileSystemException('forced disk failure');
      };
      expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isFalse);
      expect(
        f.b.db.raw.select('SELECT * FROM sync_operations'),
        hasLength(500),
      );
      f.b.ackWriter = null;
      final retry = await f.b.runtime.syncOnce(f.peer(f.a));
      expect(retry.isOk, isTrue);
      expect(retry.valueOrNull!.pulled, 0);
      final path = '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json';
      expect(jsonDecode(await File(path).readAsString()), {
        f.a.keys.deviceId: 1,
      });
      expect(f.b.reconciled, 1);
    },
  );
  for (final change in ['membership', 'disabled', 'writer', 'stop']) {
    test('ACK final IO fence blocks $change after database commit', () async {
      final f = RuntimeFixture();
      await f.init();
      addTearDown(f.dispose);
      f.a.addOperations(500);
      await f.start();
      expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
      final entered = Completer<void>(), release = Completer<void>();
      f.b.ackWriter = (file, bytes) async {
        entered.complete();
        await release.future;
        await file.writeAsBytes(bytes, flush: true);
      };
      final accepted = f.b.runtime.syncOnce(f.peer(f.a));
      await entered.future;
      expect(
        f.b.db.raw
            .select('SELECT applied_seq FROM sync_state')
            .single['applied_seq'],
        1,
      );
      Future<void>? stopping;
      if (change == 'membership') {
        f.b.ready = false;
        f.b.version = Object();
      }
      if (change == 'disabled') {
        f.b.db.raw.execute('UPDATE sync_local SET enabled=0');
      }
      if (change == 'writer') {
        f.b.db.raw.execute('UPDATE sync_local SET hlc_counter=hlc_counter+1');
      }
      if (change == 'stop') {
        stopping = f.b.runtime.stop();
      }
      release.complete();
      expect((await accepted).isOk, isFalse);
      await stopping;
      expect(f.b.reconciled, 1);
      expect(
        File('${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json')
            .existsSync(),
        isFalse,
      );
      expect(
        f.b.runtime.publishedFiles().keys.where(
          (path) => path.startsWith('acks/'),
        ),
        isEmpty,
      );
    });
  }
}
