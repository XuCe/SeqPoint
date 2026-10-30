import 'dart:convert';
import '../model/item.dart';
import '../model/activity.dart';
import '../model/tag.dart';
import '../model/enums.dart';
import '../db/database.dart';
import '../repo/item_repository.dart';
import '../repo/note_repository.dart';
import '../repo/tag_repository.dart';
import '../repo/activity_repository.dart';
import '../util/clock.dart';
import 'organize_proposal.dart';

/// 把用户确认后的提案事务写入业务对象，原文保持不变。
///
/// 稳定候选ID和事务内来源行检查保证重复采纳不重复创建。
class OrganizeApplier {
  OrganizeApplier(this._db, {Clock clock = const SystemClock()}) : _clock = clock;
  final SeqDatabase _db;
  final Clock _clock;

  /// 采纳提案，返回新建的事项。
  List<Item> apply(OrganizeProposal proposal) {
    if (!proposal.items.any((item) => item.accepted)) return const [];
    return _db.transaction(() {
      final note = NoteRepository(_db).byId(proposal.noteId);
      if (note == null || note.isDeleted || note.rawContent != proposal.sourceContent) {
        throw StateError('便签已变化，请重新整理');
      }
      final repository = ItemRepository(_db);
      final occupied = repository.byNote(note.id).map((item) => item.lineIndex).toSet();
      final created = <Item>[];
      for (final candidate in proposal.items.where((item) => item.accepted)) {
        final line = candidate.lineIndex;
        final title = candidate.title.trim();
        final project = candidate.projectTagName;
        final type = candidate.typeTagName;
        if (candidate.id.isEmpty || line == null || line < 0 || line >= note.lines.length ||
            note.lines[line].trim().isEmpty || title.isEmpty || title.length > 500 ||
            title.contains(RegExp(r'[\r\n]')) ||
            (project != null && (project.trim().isEmpty || project.length > 100 || project.contains(RegExp(r'[\r\n]')))) ||
            (type != null && !builtinTypeTags.contains(type))) {
          throw StateError('整理候选无效，请重新整理');
        }
        final existing = repository.byId(candidate.id);
        if (existing != null && (existing.noteId != note.id || existing.lineIndex != line || existing.source != ItemSource.ai)) {
          throw StateError('整理候选身份冲突，请重新整理');
        }
        if (existing != null || occupied.contains(line)) continue;
        final now = _clock.now();
        final item = repository.insert(Item(id: candidate.id, noteId: note.id,
            lineIndex: candidate.lineIndex, title: title, status: ItemStatus.todo,
            priority: candidate.important ? Priority.p1 : Priority.p4, source: ItemSource.ai,
            dueAt: candidate.dueAt, createdAt: now, updatedAt: now));
        final tags = TagRepository(_db);
        for (final entry in {TagKind.project: candidate.projectTagName, TagKind.type: candidate.typeTagName}.entries) {
          if (entry.value == null) continue;
          final tag = tags.upsert(name: entry.value!.trim(), kind: entry.key);
          repository.addTag(item.id, tag.id);
        }
        created.add(item);
        occupied.add(candidate.lineIndex);
      }
      if (created.isNotEmpty) {
        ActivityRepository(_db, clock: _clock).log(objectType: 'note', objectId: note.id,
            action: ActivityAction.aiOrganizeApplied, newValue: jsonEncode(created.map((item) => item.id).toList()));
      }
      return created;
    });
  }
}
