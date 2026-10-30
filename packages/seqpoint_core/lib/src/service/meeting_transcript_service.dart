import '../db/database.dart';
import '../model/note.dart';
import '../repo/note_repository.dart';
import 'note_service.dart';

class MeetingTranscript {
  const MeetingTranscript._(this.noteId, this.originalContent, this.text);
  final String noteId;
  final String originalContent;
  final String text;
}

/// 用户明确导入的转写先预览再追加，后续沿用现有人工确认整理。
class MeetingTranscriptService {
  MeetingTranscriptService({required this.db, required this.notes});
  final SeqDatabase db;
  final NoteService notes;

  MeetingTranscript prepare(String noteId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > 50000) {
      throw ArgumentError('转写文字必须介于 1 和 50000 字之间');
    }
    return MeetingTranscript._(noteId, _note(noteId).rawContent, trimmed);
  }

  Note apply(MeetingTranscript draft) => db.transaction(() {
    final current = _note(draft.noteId);
    if (current.rawContent != draft.originalContent) {
      throw StateError('便签已变化，请重新预览转写内容');
    }
    final separator = current.rawContent.isEmpty ? '' : '\n\n';
    return notes.editContent(
      current.id,
      '${current.rawContent}$separator会议转写（手动导入，待校对）\n${draft.text}',
    );
  });

  Note _note(String id) {
    final note = NoteRepository(db).byId(id);
    if (note == null || note.isDeleted) throw StateError('便签不存在或已删除');
    return note;
  }
}
