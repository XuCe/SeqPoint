import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  Operation op(
    String field,
    Object? value, {
    String id = '00000000-0000-4000-8000-000000000001',
  }) => Operation(
    opId: 'op',
    deviceId: 'peer',
    hlc: Hlc(millis: 1, counter: 0, deviceId: 'peer'),
    objectType: 'attachment',
    objectId: id,
    field: field,
    value: value,
  );
  test('media facts accept bounded identifiers and immutable hashes', () {
    for (final (field, value) in <(String, Object?)>[
      ('media', 'audio'),
      ('mime', 'audio/mp4'),
      ('byte_size', 1024),
      ('note_id', 'note'),
      ('item_id', null),
      ('file_name', 'meeting.m4a'),
      ('sha256', 'a' * 64),
      ('manifest_hash', 'b' * 64),
      ('content_owner', 'c' * 43),
      ('created_at', '2026-10-30T00:00:00.000Z'),
      ('deleted_at', null),
    ]) {
      expect(
        () => validateIncomingOperation(
          op(field, value),
          expectedDeviceId: 'peer',
        ),
        returnsNormally,
      );
    }
  });
  test(
    'media rejects traversal, oversized payloads and untrusted local settings',
    () {
      for (final operation in [
        op('media', 'video'),
        op('byte_size', -1),
        op('byte_size', 50 * 1024 * 1024 + 1),
        op('sha256', '../path'),
        op('manifest_hash', 'z' * 64),
        op('content_owner', '../peer'),
        op('sync', 'trusted_devices'),
        op('file_name', 'file', id: '../file'),
      ]) {
        expect(
          () => validateIncomingOperation(operation, expectedDeviceId: 'peer'),
          throwsFormatException,
        );
      }
    },
  );
}
