import 'dart:io';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:test/test.dart';

void main() {
  test('两个WAL连接重叠采纳，旧读事务回滚，重试不重复创建', () async {
    final dir = await Directory.systemTemp.createTemp('seqpoint-ai-race-');
    final path = '${dir.path}/test.db';
    final first = SeqDatabase.open(path)..migrate();
    first.raw.execute('PRAGMA journal_mode=WAL');
    final second = SeqDatabase.open(path)..migrate();
    try {
      final now = DateTime.utc(2026, 10, 25);
      final note = NoteRepository(first).insert(Note(id: 'note', kind: NoteKind.text,
          status: NoteStatus.active, rawContent: '一\n二', createdAt: now, updatedAt: now));
      final proposal = OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const [
        ProposedItem(id: 'a', title: '一', lineIndex: 0, projectTagName: '项目'),
        ProposedItem(id: 'b', title: '二', lineIndex: 1, projectTagName: '项目'),
      ]);
      var interleaved = false;
      final clock = _HookClock(() {
        interleaved = true;
        expect(OrganizeApplier(second).apply(proposal), hasLength(2));
      });
      expect(() => OrganizeApplier(first, clock: clock).apply(proposal), throwsA(anything));
      expect(interleaved, isTrue);
      expect(ItemRepository(first).byNote(note.id), hasLength(2));
      expect(ActivityRepository(first).forObject('note', note.id), hasLength(1));
      expect(TagRepository(first).all(kind: TagKind.project), hasLength(1));
      expect(OrganizeApplier(first).apply(proposal), isEmpty);
      expect(ActivityRepository(second).forObject('note', note.id), hasLength(1));
      expect(NoteRepository(first).byId(note.id)!.rawContent, note.rawContent);
    } finally {
      second.close(); first.close(); await dir.delete(recursive: true);
    }
  });
}

class _HookClock implements Clock {
  _HookClock(this.hook);
  final void Function() hook;
  bool called = false;
  @override
  DateTime now() {
    if (!called) { called = true; hook(); }
    return DateTime.utc(2026, 10, 25);
  }
}
