import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'sync_projector_test.dart' show facts;

void main() {
  test('另一连接只见关闭或完整基线，提交后写入立即使用同一writer/HLC', () {
    final directory = Directory.systemTemp.createTempSync('seqpoint_baseline_visibility_');
    final path = '${directory.path}/shared.db';
    final writer = SeqDatabase.open(path)..migrate();
    writer.raw.execute('PRAGMA journal_mode=WAL');
    final observer = SeqDatabase.open(path)..migrate();
    try {
      final clock = FakeClock(DateTime.utc(2026, 10, 25));
      final note = NoteRepository(writer, clock: clock).insert(Note(id: 'n1', kind: NoteKind.text,
          status: NoteStatus.active, rawContent: '完整存量', createdAt: clock.now(), updatedAt: clock.now()));
      var observations = 0;
      writer.raw.createFunction(functionName: 'observe_baseline', directOnly: false,
          argumentCount: const AllowedArgumentCount(0), function: (_) {
        observations++;
        final state = observer.raw.select('SELECT enabled,baseline_ready FROM sync_local').single;
        expect(state['enabled'], 0); expect(state['baseline_ready'], 0);
        expect(facts(observer), isEmpty);
        return 0;
      });
      writer.raw.execute('CREATE TEMP TRIGGER observe_seed AFTER INSERT ON sync_operations '
          'BEGIN SELECT observe_baseline(); END');
      final count = SyncBaseline(writer, clock: clock).initialize('writer');
      expect(observations, count); expect(count, greaterThan(0));
      expect(observer.raw.select('SELECT enabled,baseline_ready FROM sync_local').single['enabled'], 1);
      expect(facts(observer), hasLength(count));
      final before = facts(writer).last.hlc;
      NoteRepository(observer, clock: clock).update(note.copyWith(rawContent: '另一连接修改'));
      expect(facts(writer), hasLength(count + 1)); expect(facts(writer).last.hlc > before, isTrue);
      expect(facts(writer).last.deviceId, 'writer');
      expect(SyncBaseline(observer, clock: clock).initialize('writer'), 0);
    } finally {
      observer.close(); writer.close(); directory.deleteSync(recursive: true);
    }
  });
}
