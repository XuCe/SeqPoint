import 'package:flutter/material.dart';

import '../theme/seq_tokens.dart';

/// 页面标题：衬线大字 + 可选的一行说明。
class SeqPageHeader extends StatelessWidget {
  const SeqPageHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.subtitle,
    this.trailing,
    this.size = 28,
  });

  final String title;
  final String? eyebrow;
  final String? subtitle;
  final Widget? trailing;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (eyebrow != null) ...[
                Text(eyebrow!, style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13, color: SeqTokens.inkMuted)),
                const SizedBox(height: 4),
              ],
              Text(title, style: theme.textTheme.displaySmall?.copyWith(
                  fontSize: size, height: 1.25)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(
                    color: SeqTokens.inkMuted, fontSize: 14)),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 筛选胶囊。选中时墨色底，未选中时浅底。
class FilterPill extends StatelessWidget {
  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? SeqTokens.paper : SeqTokens.inkSoft;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? SeqTokens.ink : SeqTokens.chip,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: TextStyle(fontSize: 13, color: fg,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
              if (count != null) ...[
                const SizedBox(width: 6),
                Text('$count', style: TextStyle(fontSize: 12,
                    color: selected ? SeqTokens.line : SeqTokens.inkFaint)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// 白底卡片，细描边。
class SeqCard extends StatelessWidget {
  const SeqCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = SeqTokens.raised,
    this.radius = SeqSpace.radiusCard,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: const Color(0xFFECE6D8)),
        ),
        child: child,
      );
}

/// 快捷键提示，如 ⌘K。
class KbdHint extends StatelessWidget {
  const KbdHint(this.text, {super.key, this.dark = false});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: dark ? const Color(0x1F000000) : SeqTokens.raised,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: dark ? const Color(0x33000000) : SeqTokens.line),
        ),
        child: Text(text, style: TextStyle(fontSize: 11,
            color: dark ? SeqTokens.noteInk : SeqTokens.inkMuted)),
      );
}

/// 小标签：事项 / 备注 / 时间 / #标签。
class SeqBadge extends StatelessWidget {
  const SeqBadge(this.text, {super.key, this.tone = SeqBadgeTone.neutral});

  final String text;
  final SeqBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      SeqBadgeTone.accent => (SeqTokens.accentSoft, SeqTokens.accentInk),
      SeqBadgeTone.danger => (SeqTokens.dangerBg, SeqTokens.dangerInk),
      SeqBadgeTone.good => (SeqTokens.goodBg, SeqTokens.goodInk),
      SeqBadgeTone.neutral => (SeqTokens.chip, SeqTokens.inkMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 11.5, color: fg,
          fontWeight: FontWeight.w600)),
    );
  }
}

enum SeqBadgeTone { neutral, accent, danger, good }

/// 品牌里的"序点"：时间线上可点的圆点。
class SeqDot extends StatelessWidget {
  const SeqDot({super.key, required this.done, this.overdue = false, this.size = 20});

  final bool done;
  final bool overdue;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done ? SeqTokens.accentInk : SeqTokens.raised,
          border: done
              ? null
              : Border.all(
                  color: overdue ? SeqTokens.dangerInk : const Color(0xFFB9B2A3),
                  width: 1.6),
        ),
        child: done
            ? Icon(Icons.check, size: size * 0.65, color: SeqTokens.paper)
            : null,
      );
}

/// 时间线上的"现在"指示线。
class NowMarker extends StatelessWidget {
  const NowMarker({super.key, required this.now, this.timeWidth = 56});

  final DateTime now;
  final double timeWidth;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(
            width: timeWidth,
            child: Text(formatClock(now), textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: SeqTokens.accentInk)),
          ),
          const SizedBox(width: 8),
          Container(width: 24, alignment: Alignment.center, child: Container(
            width: 10, height: 10,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: SeqTokens.accent),
          )),
          Expanded(child: Container(height: 2, color: SeqTokens.accent)),
          const SizedBox(width: 8),
          const Text('现在', style: TextStyle(fontSize: 12, color: SeqTokens.accentInk,
              fontWeight: FontWeight.w600)),
        ]),
      );
}

String formatClock(DateTime t) {
  t = t.toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String weekdayName(DateTime d) =>
    const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];

String greetingOf(DateTime t) {
  if (t.hour < 6) return '夜深了';
  if (t.hour < 12) return '早上好';
  if (t.hour < 18) return '下午好';
  return '晚上好';
}

/// 相对日期 + 时刻：今天 09:00 / 明天 14:00 / 5月6日 09:00。
String formatDue(DateTime due, DateTime now) {
  due = due.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(due.year, due.month, due.day);
  final diff = day.difference(today).inDays;
  final clock = formatClock(due);
  return switch (diff) {
    0 => '今天 $clock',
    1 => '明天 $clock',
    -1 => '昨天 $clock',
    _ => '${due.month}月${due.day}日 $clock',
  };
}
