import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('冻结跨await不持事务，双连接真实仓储新增和重开不混入旧批次', () async {
    final directory = Directory.systemTemp.createTempSync('seqpoint_publish_');
    final path = '${directory.path}/shared.db';
    var writer = SeqDatabase.open(path)..migrate();
    writer.raw.execute('PRAGMA journal_mode=WAL');
    final observer = SeqDatabase.open(path)..migrate();
    try {
      SyncBaseline(writer).initialize('writer');
      final now = DateTime.utc(2026, 10, 25);
      final clock = FakeClock(now);
      final note = NoteRepository(writer, clock: clock).insert(Note(id: 'n1', kind: NoteKind.text,
          status: NoteStatus.active, rawContent: 'before', createdAt: now, updatedAt: now));
      final batch = SyncPublisher(writer, deviceId: 'writer').freeze();
      final ids = batch.operations.map((op) => op.opId).toSet();
      await Future<void>(() {
        expect(writer.raw.autocommit, isTrue);
        NoteRepository(observer, clock: clock).update(note.copyWith(rawContent: 'after'));
      });
      expect(batch.operations.singleWhere((op) => op.field == 'raw_content').value, 'before');
      expect(batch.operations.map((op) => op.opId).toSet(), ids);
      writer.close();
      writer = SeqDatabase.open(path)..migrate();
      final publisher = SyncPublisher(writer, deviceId: 'writer');
      final reopened = publisher.freeze();
      expect(reopened.operations, hasLength(ids.length + 1));
      expect(reopened.operations.last.value, 'after');
      expect(reopened.operations.last.opId, isNot(isIn(ids)));
      expect(writer.raw.select('SELECT * FROM sync_publications'), isEmpty);
      observer.raw.execute("UPDATE sync_local SET device_id='other'");
      expect(() => publisher.freeze(), throwsStateError);
      observer.disconnectSyncForRestore();
      expect(() => publisher.freeze(), throwsStateError);
      expect(writer.raw.autocommit, isTrue);
    } finally {
      observer.close();
      writer.close();
      directory.deleteSync(recursive: true);
    }
  });
}
