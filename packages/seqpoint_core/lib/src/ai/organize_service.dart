import 'dart:convert';
import '../model/note.dart';
import '../model/tag.dart';
import '../util/clock.dart';
import '../util/ids.dart';
import '../util/result.dart';
import 'ai_provider.dart';
import 'organize_proposal.dart';
import 'rules/syntax_parser.dart';
import 'rules/time_parser.dart';

/// 手动整理：按隐私档位使用本地规则或单次模型调用，产出待确认提案。
///
/// 三步：
/// 1. 本地规则：分行、`#`/`!P` 语法、时间短语；
/// 2. 模型调用（仅当档位为 cloud）：一次调用返回结构化结果；
/// 3. 产出 [OrganizeProposal]，等确认卡采纳后才写库。
///
/// 云端只发送当前原文；已整理行仅在本地过滤，不自动重试或回退。
class OrganizeService {
  OrganizeService({
    required AiMode mode,
    AiProvider? provider,
    this.config,
    this.timeParser = const TimeParser(),
    this.syntaxParser = const SyntaxParser(),
    Clock clock = const SystemClock(),
  })  : _mode = mode,
        _provider = provider,
        _clock = clock;

  final AiMode _mode;
  final AiProvider? _provider;
  final ProviderConfig? config;
  final TimeParser timeParser;
  final SyntaxParser syntaxParser;
  final Clock _clock;

  /// 整理一张便签。[alreadyOrganizedLines] 用于增量整理。
  Future<Result<OrganizeProposal>> organize(
    Note note, {
    Set<int> alreadyOrganizedLines = const {},
    List<String> knownProjectTags = const [],
    String? apiKey,
  }) async {
    if (_mode == AiMode.off) return const Err('ai_disabled');
    if (note.isDeleted) return const Err('note_unavailable');
    if (utf8.encode(note.rawContent).length > 65536) return const Err('invalid_request');
    if (note.rawContent.trim().isEmpty) {
      return Ok(OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: const []));
    }
    if (_mode == AiMode.cloud) {
      if (_provider == null || config == null || apiKey == null || apiKey.isEmpty) {
        return const Err('ai_not_configured');
      }
      try {
        final result = await _provider.complete(prompt: note.rawContent, apiKey: apiKey,
            config: config!, schemaHint: 'JSON {"items":[{"title":"text","lineIndex":0,'
            '"important":false,"projectTagName":null,"typeTagName":null,"dueAt":null}]}. '
            'Use zero-based source line indexes, at most one task per nonempty line. '
            'Only actionable tasks. typeTagName must be null or one of $builtinTypeTags. '
            'dueAt must be null or ISO8601 timestamp with timezone; never invent a deadline. '
            'Local reference time: ${_clock.now().toIso8601String()}; offset minutes: ${_clock.now().timeZoneOffset.inMinutes}.');
        if (result is Err<Map<String, Object?>>) return Err(result.code);
        if (result.valueOrNull!.keys.any((key) => key != 'items')) throw const FormatException();
        final rows = result.valueOrNull!['items'] as List;
        if (rows.length > 100) throw const FormatException();
        const fields = {'title', 'lineIndex', 'important', 'projectTagName', 'typeTagName', 'dueAt'};
        final lines = note.lines;
        final seen = <int>{};
        final items = <ProposedItem>[];
        for (final row in rows.cast<Map>()) {
          final line = row['lineIndex'] as int;
          final title = (row['title'] as String).trim();
          final type = row['typeTagName'] as String?;
          final project = (row['projectTagName'] as String?)?.trim();
          final dueText = row['dueAt'] as String?;
          final due = _parseDue(dueText);
          if (!row.keys.every(fields.contains) || line < 0 || line >= lines.length ||
              lines[line].trim().isEmpty || !seen.add(line) || title.isEmpty ||
              title.length > 500 || title.contains(RegExp(r'[\r\n]')) ||
              (type != null && !builtinTypeTags.contains(type)) ||
              (project != null && (project.isEmpty || project.length > 100 || project.contains(RegExp(r'[\r\n]')))) ||
              (dueText != null && due == null)) {
            throw const FormatException();
          }
          if (alreadyOrganizedLines.contains(line)) continue;
          final repeated = project != null && rows.cast<Map>().where((other) =>
              !alreadyOrganizedLines.contains(other['lineIndex']) && other['projectTagName'] == project).length >= 2;
          items.add(ProposedItem(id: newId(), title: title, lineIndex: line, typeTagName: type, dueAt: due,
              important: row['important'] as bool? ?? false,
              projectTagName: knownProjectTags.contains(project) || repeated ? project : null));
        }
        return Ok(OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: items));
      } catch (_) {
        return const Err('invalid_proposal');
      }
    }
    final items = <ProposedItem>[];
    final checklist = RegExp(r'^\s*(?:[-*]\s*)?\[ \]\s*');
    for (var index = 0; index < note.lines.length; index++) {
      if (alreadyOrganizedLines.contains(index)) continue;
      final line = note.lines[index];
      final syntax = syntaxParser.parse(line.replaceFirst(checklist, ''));
      final time = timeParser.parse(syntax.cleanTitle, _clock.now());
      if (time?.recurrence != null || syntax.cleanTitle.isEmpty || syntax.cleanTitle.length > 500 ||
          (!checklist.hasMatch(line) && syntax.priorityName == null && time == null)) {
        continue;
      }
      final projects = syntax.tagNames.where(knownProjectTags.contains);
      final types = syntax.tagNames.where(builtinTypeTags.contains);
      items.add(ProposedItem(id: newId(), title: syntax.cleanTitle, lineIndex: index,
          dueAt: time?.dateTime, important: ['p0', 'p1'].contains(syntax.priorityName),
          projectTagName: projects.isEmpty ? null : projects.first,
          typeTagName: types.isEmpty ? null : types.first));
      if (items.length > 100) return const Err('invalid_proposal');
    }
    return Ok(OrganizeProposal(noteId: note.id, sourceContent: note.rawContent, items: items));
  }

  DateTime? _parseDue(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d{1,6})?(Z|[+-]\d\d:\d\d)$')
        .firstMatch(text);
    if (match == null) throw const FormatException();
    final parts = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
    final date = DateTime.utc(parts[0], parts[1], parts[2]);
    final zone = match.group(7)!;
    if (date.year != parts[0] || date.month != parts[1] || date.day != parts[2] ||
        parts[3] > 23 || parts[4] > 59 || parts[5] > 59 ||
        (zone != 'Z' && (int.parse(zone.substring(1, 3)) > 23 || int.parse(zone.substring(4)) > 59))) {
      throw const FormatException();
    }
    return DateTime.parse(text);
  }

  bool get canUseCloud => _mode == AiMode.cloud && _provider != null;
}
