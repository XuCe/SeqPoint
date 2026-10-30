import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../shared/item_tile.dart';
import '../shared/item_editor_page.dart';
import '../shared/note_search.dart';
import '../shared/section_label.dart';
import '../theme/seq_tokens.dart';

/// 移动端今日页（简约版定稿）。
///
/// 结构：日期与问候 → AI 建议卡（便签纸样式）→ 今天 → 逾期 → 晚间汇总提示。
/// 卡片版已弃用：白卡叠在深底上层次太重，与"轻"的定位相冲。
class TodayPage extends StatefulWidget {
  const TodayPage({super.key});

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> {
  List<Item> _due = const [];
  List<Item> _overdue = const [];
  List<Item> _completed = const [];
  bool _snoozing = false;

  Future<void> _search() async {
    await openNoteSearch(context);
    if (mounted) _reload();
  }

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
      // 今天到期但时刻已过的事项属于"逾期"，两个区必须互斥。
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
  }

  Future<void> _edit(Item item) async {
    if (await ItemEditorPage.open(context, item.id) == true && mounted) {
      _reload();
    }
  }

  Future<void> _snooze(Item item) async {
    final scope = AppScope.of(context);
    if (_snoozing || scope.restoring) return;
    final reminders = scope.reminders;
    final messenger = ScaffoldMessenger.of(context);
    if (reminders == null) {
      messenger.showSnackBar(const SnackBar(content: Text('提醒服务不可用，请检查提醒设置。')));
      return;
    }
    setState(() => _snoozing = true);
    try {
      await reminders.snooze(item.id);
      if (!mounted) return;
      final current = AppScope.of(context);
      if (current.restoring || !identical(current.reminders, reminders)) return;
      _reload();
      messenger..clearSnackBars()..showSnackBar(SnackBar(content: Text(
        reminders.error == null ? '已稍后 1 小时提醒（仅本机）'
          : '已保存稍后提醒，请检查提醒设置（仅本机）')));
    } catch (_) {
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('稍后提醒失败，请重试。')));
    } finally {
      if (mounted) setState(() => _snoozing = false);
    }
  }

  /// 建议优先处理的那一件：先看逾期，再看今天最早到期的。
  Item? get _suggestion {
    if (_overdue.isNotEmpty) return _overdue.first;
    final open = _due.where((i) => i.isOpen).toList();
    return open.isEmpty ? null : open.first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final now = DateTime.now();
    final remaining = _due.where((i) => i.isOpen).length + _overdue.length;
    final suggestion = _suggestion;

    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => _reload(),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            _Greeting(now: now, remaining: remaining, onSearch: _search),
            if (suggestion != null) ...[
              const SizedBox(height: 18),
              _SuggestionNote(
                item: suggestion,
                overdue: _overdue.contains(suggestion),
                onStart: () => _toggle(suggestion),
                onSnooze: _snoozing || scope.restoring ? null : () => _snooze(suggestion),
              ),
            ],
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
                padding: const EdgeInsets.symmetric(vertical: 64),
                child: Center(
                  child: Text(
                    '今天还没有事项。点 ＋ 随手记一笔。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            const SizedBox(height: 28),
            Row(
              children: [
                const Icon(
                  Icons.notifications_none,
                  size: 16,
                  color: SeqTokens.inkMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '20:00 晚间汇总会再提醒你未完成的事',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({
    required this.now,
    required this.remaining,
    required this.onSearch,
  });

  final DateTime now;
  final int remaining;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${now.month} 月 ${now.day} 日 ${_weekday(now)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                _greetingOf(now),
                style: theme.textTheme.displaySmall?.copyWith(fontSize: 26),
              ),
              const SizedBox(height: 2),
              Text(
                remaining == 0 ? '今天没有待办了' : '今天还有 $remaining 件事',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: SeqTokens.inkMuted,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onSearch,
          icon: const Icon(Icons.search),
          color: SeqTokens.inkMuted,
          tooltip: '搜索',
        ),
      ],
    );
  }

  static String _greetingOf(DateTime t) {
    if (t.hour < 6) return '还没睡？';
    if (t.hour < 12) return '早上好';
    if (t.hour < 18) return '下午好';
    return '晚上好';
  }

  static String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];
}

/// AI 建议卡：做成一张贴上去的便签纸，是页面的视觉重点。
class _SuggestionNote extends StatelessWidget {
  const _SuggestionNote({
    required this.item,
    required this.overdue,
    required this.onStart,
    required this.onSnooze,
  });

  final Item item;
  final bool overdue;
  final VoidCallback onStart;
  final VoidCallback? onSnooze;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: -0.014,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          color: SeqTokens.noteYellow,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(4),
            bottomRight: Radius.circular(6),
            bottomLeft: Radius.circular(16),
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF5A460A).withValues(alpha: 0.28),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, size: 15, color: Color(0xFF7A6620)),
                SizedBox(width: 8),
                Text(
                  '建议优先处理',
                  style: TextStyle(
                    fontSize: 11.5,
                    letterSpacing: 1.2,
                    color: Color(0xFF7A6620),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontSize: 18, color: SeqTokens.noteInk),
            ),
            const SizedBox(height: 3),
            Text(
              _subtitle(),
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B5A20)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: onStart,
                  style: FilledButton.styleFrom(
                    backgroundColor: SeqTokens.noteInk,
                    foregroundColor: SeqTokens.noteYellow,
                  ),
                  child: const Text('完成'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: onSnooze,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF7A6620),
                    side: const BorderSide(color: Color(0xFFB39A3C)),
                  ),
                  child: const Text('1 小时后'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    final due = item.dueAt?.toLocal();
    if (due == null) return '还没开始';
    if (overdue) return '已经过了截止时间';
    final hh = due.hour.toString().padLeft(2, '0');
    final mm = due.minute.toString().padLeft(2, '0');
    return '今天 $hh:$mm 到期，还没开始';
  }
}
