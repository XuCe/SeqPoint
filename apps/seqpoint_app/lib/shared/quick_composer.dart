import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../theme/seq_tokens.dart';
import 'seq_widgets.dart';

/// 输入框下方的逐行预览：哪一行会变成事项、识别到的时间和标签。
class ComposerLine {
  const ComposerLine({
    required this.title,
    required this.isItem,
    this.due,
    this.tags = const [],
    this.important = false,
  });

  final String title;
  final bool isItem;
  final DateTime? due;
  final List<String> tags;
  final bool important;
}

/// 与"仅本地规则"整理同一套规则：勾选框、!P 优先级或时间短语的行成为事项。
List<ComposerLine> previewComposerLines(String text, DateTime now,
    {Set<String> knownTags = const {}}) {
  const syntax = SyntaxParser();
  const time = TimeParser();
  final checklist = RegExp(r'^\s*(?:[-*]\s*)?\[ \]\s*');
  final result = <ComposerLine>[];
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final parsed = syntax.parse(line.replaceFirst(checklist, ''));
    final when = parsed.cleanTitle.isEmpty ? null : time.parse(parsed.cleanTitle, now);
    final isItem = when?.recurrence == null && parsed.cleanTitle.isNotEmpty &&
        parsed.cleanTitle.length <= 500 &&
        (checklist.hasMatch(line) || parsed.priorityName != null || when != null);
    result.add(ComposerLine(
      title: parsed.cleanTitle.isEmpty ? line.trim() : parsed.cleanTitle,
      isItem: isItem,
      due: isItem ? when?.dateTime : null,
      tags: isItem ? parsed.tagNames.where(knownTags.contains).toList() : const [],
      important: ['p0', 'p1'].contains(parsed.priorityName),
    ));
  }
  return result;
}

/// 今日页顶部的随手记输入框。
///
/// 不用先建便签：写下就存，带时间的行自动变成事项并提醒；其余行原样留作备注。
class QuickComposer extends StatefulWidget {
  const QuickComposer({super.key, required this.onSaved, this.focusNode});

  final void Function(Note note, int itemCount) onSaved;
  final FocusNode? focusNode;

  @override
  State<QuickComposer> createState() => _QuickComposerState();
}

class _QuickComposerState extends State<QuickComposer> {
  final _controller = TextEditingController();
  FocusNode? _ownFocus;
  bool _saving = false;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

  @override
  void dispose() {
    _controller.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  Set<String> _knownTags(AppScope scope) => {
        ...scope.tags.all(kind: TagKind.project).map((t) => t.name),
        ...builtinTypeTags,
      };

  Future<void> _save() async {
    final scope = AppScope.of(context);
    final text = _controller.text;
    if (_saving || scope.restoring || text.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final note = scope.noteService.capture(text.trimRight());
      var created = 0;
      final database = scope.database;
      if (database != null) {
        final known = scope.tags.all(kind: TagKind.project).map((t) => t.name).toList();
        final proposal = (await OrganizeService(mode: AiMode.localRulesOnly)
            .organize(note, knownProjectTags: known)).valueOrNull;
        if (proposal != null && proposal.items.isNotEmpty && mounted) {
          created = OrganizeApplier(database).apply(proposal).length;
        }
      }
      if (!mounted) return;
      _controller.clear();
      widget.onSaved(note, created);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('保存失败，请重试。输入的内容仍在。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final mac = defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _save,
      },
      child: SeqCard(
        padding: EdgeInsets.zero,
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final lines = previewComposerLines(_controller.text, DateTime.now(),
                knownTags: _knownTags(scope));
            final items = lines.where((l) => l.isItem).length;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              TextField(
                key: const ValueKey('quick-composer'),
                controller: _controller,
                focusNode: _focus,
                minLines: 2,
                maxLines: 8,
                enabled: !scope.restoring,
                style: const TextStyle(fontSize: 15, height: 1.6),
                decoration: const InputDecoration(
                  hintText: '随手记：一行一件事，写上"明天 9 点"就会提醒你',
                  hintStyle: TextStyle(color: SeqTokens.inkFaint),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.fromLTRB(18, 16, 18, 8),
                ),
              ),
              if (lines.isNotEmpty) ...[
                const Divider(height: 1, color: SeqTokens.lineSoft),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                  child: Column(children: [
                    for (final line in lines) _PreviewRow(line: line),
                  ]),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 12, 12),
                child: Row(children: [
                  Expanded(
                    child: Text(
                      lines.isEmpty
                          ? '不用填任何属性，写下就存'
                          : items == 0
                              ? '这次没有带时间的事，会存成一张便签'
                              : '$items 件事项会出现在时间线上',
                      style: const TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  KbdHint(mac ? '⌘↵' : 'Ctrl+↵'),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _saving || lines.isEmpty || scope.restoring ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: SeqTokens.ink,
                      foregroundColor: SeqTokens.paper,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: const Text('记下'),
                  ),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.line});

  final ComposerLine line;

  @override
  Widget build(BuildContext context) {
    final due = line.due;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SeqBadge(line.isItem ? '事项' : '备注',
            tone: line.isItem ? SeqBadgeTone.accent : SeqBadgeTone.neutral),
        const SizedBox(width: 10),
        Expanded(
          child: Text(line.title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5,
                  color: line.isItem ? SeqTokens.ink : SeqTokens.inkMuted)),
        ),
        if (line.important) ...[
          const SizedBox(width: 6),
          const Icon(Icons.star_rounded, size: 15, color: SeqTokens.accent),
        ],
        if (due != null) ...[
          const SizedBox(width: 6),
          SeqBadge(formatDue(due, DateTime.now())),
        ],
        for (final tag in line.tags) ...[
          const SizedBox(width: 6),
          SeqBadge('#$tag'),
        ],
      ]),
    );
  }
}
