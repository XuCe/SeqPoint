import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/item_tile.dart';
import '../../shared/item_editor_page.dart';
import '../../shared/section_label.dart';
import '../../theme/seq_tokens.dart';

/// 今日视图。
///
/// 结构（按定稿效果图）：问候与剩余数量 → AI 建议卡（M3 接入）
/// → 今天到期 → 逾期区 → 今日已完成 → 底部晚间汇总提示。
class TodayView extends StatefulWidget {
  const TodayView({super.key, this.onChanged});

  final VoidCallback? onChanged;

  @override
  State<TodayView> createState() => _TodayViewState();
}

class _TodayViewState extends State<TodayView> {
  List<Item> _due = const [];
  List<Item> _overdue = const [];
  List<Item> _completed = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final scope = AppScope.of(context);
    final now = DateTime.now();
    final overdue = scope.items.overdue(now);
    final overdueIds = overdue.map((i) => i.id).toSet();
    setState(() {
      // 今天到期但时刻已过的事项属于"逾期"，两个区必须互斥，
      // 否则同一件事会在页面上出现两次。
      _due = scope.items
          .dueOn(now)
          .where((i) => !overdueIds.contains(i.id))
          .toList();
      _overdue = overdue;
      _completed = scope.items.completedOn(now);
    });
  }

  void _toggle(Item item) {
    AppScope.of(context).noteService.toggleItem(item.id);
    _reload();
    widget.onChanged?.call();
  }

  Future<void> _edit(Item item) async {
    if (await ItemEditorPage.open(context, item.id) == true && mounted) {
      _reload();
      widget.onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final remaining = _due.length + _overdue.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(36, 26, 36, 20),
      children: [
        Text(
          '${now.month} 月 ${now.day} 日 ${_weekday(now)}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Text(
          remaining == 0 ? '今天没有待办了' : '早上好，今天还有 $remaining 件事',
          style: theme.textTheme.displaySmall?.copyWith(fontSize: 28),
        ),
        const SizedBox(height: 24),
        if (_due.isNotEmpty) ...[
          const SectionLabel('今天'),
          for (final item in _due)
            ItemTile(
              item: item,
              onToggle: () => _toggle(item),
              onTap: () => _edit(item),
            ),
        ],
        if (_overdue.isNotEmpty) ...[
          SectionLabel('逾期', badge: '${_overdue.length}', danger: true),
          for (final item in _overdue)
            ItemTile(
              item: item,
              onToggle: () => _toggle(item),
              onTap: () => _edit(item),
            ),
        ],
        if (_completed.isNotEmpty) ...[
          const SectionLabel('今日已完成'),
          for (final item in _completed)
            ItemTile(
              item: item,
              onToggle: () => _toggle(item),
              onTap: () => _edit(item),
            ),
        ],
        if (_due.isEmpty && _overdue.isEmpty && _completed.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: Text(
                '还没有事项。按 ⌥Space 随手记一笔。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        const SizedBox(height: 32),
        Row(
          children: [
            const Icon(
              Icons.notifications_none,
              size: 16,
              color: SeqTokens.inkMuted,
            ),
            const SizedBox(width: 8),
            Text(
              '20:00 晚间汇总会再提醒你未完成的事 · 勿扰 22:00–08:00',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ],
    );
  }

  static String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];
}
