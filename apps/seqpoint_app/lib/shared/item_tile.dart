import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../theme/seq_tokens.dart';

/// 事项行。列表与今日视图共用。
///
/// 显示：勾选圈、标题、重要星标、标签、时间。移动端最小高度 44px。
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    this.tagNames = const [],
    this.sourceNoteTitle,
    this.onToggle,
    this.onTap,
  });

  final Item item;
  final List<String> tagNames;
  final String? sourceNoteTitle;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = item.isDone;

    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: SeqSpace.minTapTarget),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: SeqTokens.lineSoft)),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: onToggle,
              child: _Circle(done: done),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.title,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: done ? SeqTokens.inkMuted : null,
                            decoration:
                                done ? TextDecoration.lineThrough : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (item.isImportant) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.star,
                            size: 13, color: SeqTokens.accent),
                      ],
                    ],
                  ),
                  if (tagNames.isNotEmpty || sourceNoteTitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final name in tagNames)
                            Text('#$name',
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontSize: 11.5)),
                          if (sourceNoteTitle != null)
                            Text(sourceNoteTitle!,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(fontSize: 11.5)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (item.dueAt != null)
              Text(_formatDue(item.dueAt!), style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  static String _formatDue(DateTime d) {
    d = d.toLocal();
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    if (sameDay) return '$hh:$mm';
    return '${d.month}/${d.day} $hh:$mm';
  }
}

class _Circle extends StatelessWidget {
  const _Circle({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done ? SeqTokens.accentInk : null,
        border: done
            ? null
            : Border.all(color: const Color(0xFFB9B2A3), width: 1.5),
      ),
      child: done
          ? const Icon(Icons.check, size: 13, color: SeqTokens.paper)
          : null,
    );
  }
}
