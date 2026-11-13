import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../theme/seq_tokens.dart';
import 'seq_widgets.dart';

/// 事项行。列表、今日时间线共用。
///
/// 圆点即勾选：点一下完成，再点一下撤销。时间线模式下左侧是时刻、
/// 中间是串起一天的竖线，与品牌"序点"同一个意象。
class ItemTile extends StatelessWidget {
  const ItemTile({
    super.key,
    required this.item,
    this.tagNames = const [],
    this.sourceNoteTitle,
    this.onToggle,
    this.onTap,
    this.timeline = false,
    this.timeLabel,
    this.first = false,
    this.last = false,
    this.now,
  });

  final Item item;
  final List<String> tagNames;
  final String? sourceNoteTitle;
  final VoidCallback? onToggle;
  final VoidCallback? onTap;

  /// 时间线模式：左侧时刻 + 竖线串联。
  final bool timeline;
  final String? timeLabel;
  final bool first;
  final bool last;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = item.isDone;
    final current = now ?? DateTime.now();
    final overdue = item.isOverdue(current);

    final title = Row(children: [
      Flexible(
        child: Text(
          item.title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14.5,
            color: done ? SeqTokens.inkMuted : null,
            decoration: done ? TextDecoration.lineThrough : null,
            decorationColor: SeqTokens.inkMuted,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (item.isImportant) ...[
        const SizedBox(width: 6),
        const Icon(Icons.star_rounded, size: 15, color: SeqTokens.accent),
      ],
    ]);

    final meta = <String>[
      if (sourceNoteTitle != null) sourceNoteTitle!,
      for (final name in tagNames) '#$name',
    ];
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        if (meta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(meta.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12)),
          ),
      ],
    );

    final dot = GestureDetector(
      onTap: onToggle,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Semantics(
          button: true,
          checked: done,
          label: done ? '标记为未完成' : '标记为完成',
          child: SeqDot(done: done, overdue: overdue),
        ),
      ),
    );

    if (!timeline) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: SeqTokens.chip.withValues(alpha: 0.6),
        child: Container(
          constraints: const BoxConstraints(minHeight: SeqSpace.minTapTarget + 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            dot,
            const SizedBox(width: 10),
            Expanded(child: body),
            if (item.dueAt != null) ...[
              const SizedBox(width: 12),
              Text(
                formatDue(item.dueAt!, current),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  color: overdue ? SeqTokens.dangerInk : SeqTokens.inkMuted,
                  fontWeight: overdue ? FontWeight.w600 : null,
                ),
              ),
            ],
          ]),
        ),
      );
    }

    final label = timeLabel ??
        (item.dueAt == null ? '' : formatClock(item.dueAt!));
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      hoverColor: SeqTokens.chip.withValues(alpha: 0.6),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: 56,
            child: Padding(
              padding: const EdgeInsets.only(top: 13),
              child: Text(label, textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: overdue ? SeqTokens.dangerInk : SeqTokens.inkMuted,
                    fontWeight: overdue ? FontWeight.w600 : FontWeight.w500,
                  )),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 24,
            child: Stack(alignment: Alignment.topCenter, children: [
              if (!(first && last)) Positioned(
                top: first ? 22 : 0,
                bottom: last ? null : 0,
                height: last ? 22 : null,
                child: Container(width: 2, color: SeqTokens.line),
              ),
              Padding(padding: const EdgeInsets.only(top: 10), child: dot),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: body,
            ),
          ),
        ]),
      ),
    );
  }
}
