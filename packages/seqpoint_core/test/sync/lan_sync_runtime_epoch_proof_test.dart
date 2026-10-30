import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'lan_sync_runtime_fixture.dart';
import 'lan_sync_runtime_epoch_fixture.dart';

void main() {
  for (final failure in [
    'unseen-op',
    'no-receipt',
    'changed-value',
    'reordered',
    'missing-fact',
    'receipt-time',
    'receipt-epoch',
  ]) {
    test(
      'historical seal $failure remains waiting and imports no current suffix',
      () async {
        final f = RuntimeFixture();
        await f.init();
        addTearDown(f.dispose);
        f.a.addOperations(2);
        await f.start();
        expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
        expect((await f.b.runtime.syncOnce(f.peer(f.a))).isOk, isTrue);
        if (failure == 'unseen-op') {
          f.a.addOperations(1, start: 2);
          expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
        }
        if (failure == 'no-receipt') {
          f.b.db.raw.execute('DELETE FROM sync_received_segments');
        }
        if (failure == 'changed-value') {
          f.b.db.raw.execute(
            "UPDATE sync_operations SET value_json='\"changed\"'",
          );
        }
        if (failure == 'missing-fact') {
          f.b.db.raw.execute('DELETE FROM sync_operations WHERE hlc_counter=0');
        }
        if (failure == 'receipt-time') {
          f.b.db.raw.execute(
            'UPDATE sync_received_segments SET created_at=created_at+1',
          );
        }
        if (failure == 'receipt-epoch') {
          f.b.db.raw.execute('UPDATE sync_received_segments SET key_epoch=2');
        }
        if (failure == 'reordered') {
          final ids = jsonDecode(
            f.b.db.raw
                    .select('SELECT op_ids_json FROM sync_received_segments')
                    .single['op_ids_json']
                as String,
          ) as List;
          f.b.db.raw.execute(
            'UPDATE sync_received_segments SET op_ids_json=?',
            [jsonEncode(ids.reversed.toList())],
          );
        }
        final before = jsonEncode(
          f.b.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id'),
        );
        await rotateRuntimePair(f);
        f.a.addOperations(1, start: 10);
        expect((await f.a.runtime.syncOnce(f.peer(f.b))).isOk, isTrue);
        final result = await f.b.runtime.syncOnce(f.peer(f.a));
        expect(result.isOk, isTrue);
        expect(result.valueOrNull!.waitingPeers, [f.a.keys.deviceId]);
        expect(result.valueOrNull!.pulled, 0);
        expect(
          jsonEncode(
            f.b.db.raw.select('SELECT * FROM sync_operations ORDER BY op_id'),
          ),
          before,
        );
        final ack = File(
          '${f.b.directory.path}/vault/acks/${f.b.keys.deviceId}.json',
        );
        expect(jsonDecode(await ack.readAsString()), isEmpty);
      },
    );
  }
}
