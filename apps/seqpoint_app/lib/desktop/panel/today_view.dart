import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/item_editor_page.dart';
import '../../shared/item_tile.dart';
import '../../shared/open_note.dart';
import '../../shared/quick_composer.dart';
import '../../shared/seq_widgets.dart';
import '../../theme/seq_tokens.dart';

/// 今日视图。
///
/// 左栏：问候 → 随手记输入框 → 今天的时间线（逾期在上、"现在"指示线、
/// 今日已完成收在末尾）。右栏：待整理的便签、进行中的便签、晚间汇总。
class TodayView extends StatefulWidget {
  const TodayView({super.key, this.onChanged, this.revision = 0, this.composerFocus});

  final VoidCallback? onChanged;

  /// 外部数据变化（窗口重新聚焦、右侧面板修改）时递增，触发重新读库。
  final int revision;
  final FocusNode? composerFocus;

  @override
  State<TodayView> createState() => _TodayViewState();
}

class _TodayViewState extends State<TodayView> {
  List<Item> _due = const [];
  List<Item> _overdue = const [];
  List<Item> _completed = const [];
  List<WallNote> _unorganized = const [];
  List<WallNote> _active = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  @override
  void didUpdateWidget(TodayView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _reload();
  }

  void _reload() {
    final scope = AppScope.of(context);
    final now = DateTime.now();
    final overdue = scope.items.overdue(now);
    final overdueIds = overdue.map((i) => i.id).toSet();
    final wall = scope.notes.activeWithProgress();
    final notes = [for (var i = 0; i < wall.length && i < 64; i++) wall[i]];
    setState(() {
      // 今天到期但时刻已过的事项属于"逾期"，两个区必须互斥，
      // 否则同一件事会在页面上出现两次。
      _due = scope.items
          .dueOn(now)
          .where((i) => !overdueIds.contains(i.id))
          .toList();
      _overdue = overdue;
      _completed = scope.items.completedOn(now);
      _unorganized = notes
          .where((n) => n.total == 0 && n.note.rawContent.trim().isNotEmpty)
          .toList();
      _active = notes.where((n) => n.total > 0).toList();
    });
  }

  void _changed() {
    _reload();
    widget.onChanged?.call();
  }

  void _toggle(Item item) {
    AppScope.of(context).noteService.toggleItem(item.id);
    _changed();
  }

  Future<void> _edit(Item item) async {
    if (await ItemEditorPage.open(context, item.id) == true && mounted) {
      _changed();
    }
  }

  Future<void> _open(Note note) async {
    try {
      await openNote(context, note.id);
      if (mounted) _changed();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('打开便签失败，请重试。已保存的内容仍在。')));
      }
    }
  }

  void _saved(Note note, int itemCount) {
    _changed();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(itemCount == 0 ? '已记下，存成了一张便签' : '已记下，$itemCount 件事项排进了时间线'),
        action: SnackBarAction(label: '打开', onPressed: () => _open(note)),
      ));
  }

  ItemTile _tile(Item item, {required bool first, required bool last, String? label}) {
    final scope = AppScope.of(context);
    final noteId = item.noteId;
    final source = noteId == null ? null : scope.notes.byId(noteId);
    return ItemTile(
      item: item,
      timeline: true,
      first: first,
      last: last,
      timeLabel: label,
      sourceNoteTitle: source?.title,
      tagNames: [
        for (final id in scope.items.tagIdsOf(item.id))
          if (scope.tags.byId(id) case final tag?) tag.name,
      ],
      onToggle: () => _toggle(item),
      onTap: () => _edit(item),
    );
  }

  List<Widget> _timeline(DateTime now) {
    final rows = <Widget>[];
    final total = _overdue.length + _due.length;
    var index = 0;
    for (final item in _overdue) {
      final due = item.dueAt!.toLocal();
      final sameDay = due.year == now.year && due.month == now.month && due.day == now.day;
      rows.add(_tile(item, first: index == 0, last: index == total - 1,
          label: sameDay ? formatClock(due) : '${due.month}/${due.day}'));
      index++;
    }
    var markerPlaced = false;
    for (final item in _due) {
      if (!markerPlaced && item.dueAt!.isAfter(now)) {
        rows.add(NowMarker(now: now));
        markerPlaced = true;
      }
      rows.add(_tile(item, first: index == 0, last: index == total - 1));
      index++;
    }
    if (!markerPlaced && total > 0) rows.add(NowMarker(now: now));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final remaining = _due.length + _overdue.length;

    final main = <Widget>[
      SeqPageHeader(
        eyebrow: '${now.month} 月 ${now.day} 日 ${weekdayName(now)}',
        title: remaining == 0 ? '今天没有待办了' : '${greetingOf(now)}，今天还有 $remaining 件事',
      ),
      const SizedBox(height: 20),
      QuickComposer(onSaved: _saved, focusNode: widget.composerFocus),
      const SizedBox(height: 28),
      Row(children: [
        Text('今天的序列', style: theme.textTheme.titleMedium?.copyWith(
            fontFamily: SeqFonts.serif.first, fontFamilyFallback: SeqFonts.serif,
            fontWeight: FontWeight.w700, fontSize: 17)),
        const SizedBox(width: 10),
        if (_overdue.isNotEmpty)
          SeqBadge('逾期 ${_overdue.length}', tone: SeqBadgeTone.danger),
        const Spacer(),
        if (_completed.isNotEmpty)
          Text('今天已完成 ${_completed.length} 件',
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5)),
      ]),
      const SizedBox(height: 10),
      ..._timeline(now),
      if (_due.isEmpty && _overdue.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 36),
          child: Center(child: Text(_emptyHint(context), style: theme.textTheme.bodySmall)),
        ),
      if (_completed.isNotEmpty) ...[
        const SizedBox(height: 18),
        Text('今日已完成', style: theme.textTheme.labelSmall),
        const SizedBox(height: 4),
        for (final item in _completed)
          ItemTile(item: item, onToggle: () => _toggle(item), onTap: () => _edit(item)),
      ],
    ];

    final side = <Widget>[
      if (_unorganized.isNotEmpty) ...[
        _UnorganizedCard(notes: _unorganized, onOpen: _open),
        const SizedBox(height: 16),
      ],
      if (_active.isNotEmpty) ...[
        _ActiveNotes(notes: _active, onOpen: _open),
        const SizedBox(height: 16),
      ],
      const _DigestCard(),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 1040;
      if (!wide) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
          children: [...main, const SizedBox(height: 28), ...side],
        );
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(40, 30, 32, 32),
            children: main,
          ),
        ),
        SizedBox(
          width: 320,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 30, 32, 32),
            children: side,
          ),
        ),
      ]);
    });
  }

  /// 全局快捷键只在有独立窗口服务的桌面（macOS / Windows）注册，
  /// 组合与 DesktopHotkeyService.defaults 的“唤起”一致。
  static String _emptyHint(BuildContext context) {
    if (AppScope.of(context).windows == null) return '今天还没有带时间的事。在上面写一句试试。';
    return defaultTargetPlatform == TargetPlatform.windows
        ? '今天还没有带时间的事。按 Alt+Shift+Space 随时记一笔。'
        : '今天还没有带时间的事。按 ⌥Space 随时记一笔。';
  }
}

class _SideTitle extends StatelessWidget {
  const _SideTitle(this.text, {this.trailing});

  final String text;
  final String? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
              color: SeqTokens.inkSoft)),
          const Spacer(),
          if (trailing != null)
            Text(trailing!, style: const TextStyle(fontSize: 12, color: SeqTokens.inkMuted)),
        ]),
      );
}

class _UnorganizedCard extends StatelessWidget {
  const _UnorganizedCard({required this.notes, required this.onOpen});

  final List<WallNote> notes;
  final ValueChanged<Note> onOpen;

  @override
  Widget build(BuildContext context) => SeqCard(
        color: SeqTokens.accentSoft,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.auto_awesome_outlined, size: 16, color: SeqTokens.accentInk),
            const SizedBox(width: 8),
            Expanded(child: Text('${notes.length} 张便签还没整理',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700,
                    color: SeqTokens.accentInk))),
          ]),
          const SizedBox(height: 4),
          const Text('打开后点"整理"，把里面的事拆出来、排上时间。',
              style: TextStyle(fontSize: 12.5, color: SeqTokens.inkSoft, height: 1.5)),
          const SizedBox(height: 6),
          for (final entry in notes.take(3))
            _NoteLink(note: entry.note, onTap: () => onOpen(entry.note)),
        ]),
      );
}

class _ActiveNotes extends StatelessWidget {
  const _ActiveNotes({required this.notes, required this.onOpen});

  final List<WallNote> notes;
  final ValueChanged<Note> onOpen;

  @override
  Widget build(BuildContext context) => SeqCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _SideTitle('进行中的便签', trailing: '${notes.length}'),
          for (final entry in notes.take(6))
            _NoteLink(
              note: entry.note,
              trailing: entry.done == entry.total ? '可揭走' : '${entry.done}/${entry.total}',
              progress: entry.done / entry.total,
              onTap: () => onOpen(entry.note),
            ),
        ]),
      );
}

class _NoteLink extends StatelessWidget {
  const _NoteLink({required this.note, required this.onTap, this.trailing, this.progress});

  final Note note;
  final VoidCallback onTap;
  final String? trailing;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final color = SeqTokens.noteColors[note.color] ?? SeqTokens.noteYellow;
    final title = note.title?.trim().isNotEmpty == true
        ? note.title!
        : note.lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '（空便签）').trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Row(children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(3),
              border: Border.all(color: const Color(0x22000000)))),
          const SizedBox(width: 10),
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5))),
          if (progress != null) ...[
            const SizedBox(width: 8),
            SizedBox(width: 36, child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: progress, minHeight: 3,
                  backgroundColor: SeqTokens.line, color: SeqTokens.accentInk),
            )),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(trailing!, style: const TextStyle(fontSize: 12, color: SeqTokens.inkMuted)),
          ],
        ]),
      ),
    );
  }
}

class _DigestCard extends StatelessWidget {
  const _DigestCard();

  @override
  Widget build(BuildContext context) => const SeqCard(
        color: SeqTokens.chrome,
        padding: EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.notifications_none, size: 17, color: SeqTokens.inkMuted),
          SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('20:00 晚间汇总会再提醒你未完成的事',
                style: TextStyle(fontSize: 12.5, color: SeqTokens.inkSoft, height: 1.55)),
            Text('勿扰 22:00–08:00',
                style: TextStyle(fontSize: 12, color: SeqTokens.inkMuted, height: 1.55)),
          ])),
        ]),
      );
}
