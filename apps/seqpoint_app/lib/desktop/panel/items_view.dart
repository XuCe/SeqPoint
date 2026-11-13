import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/item_editor_page.dart';
import '../../shared/item_tile.dart';
import '../../shared/seq_widgets.dart';
import '../../theme/seq_tokens.dart';

/// 跨便签的事项，按时间分组：逾期 / 今天 / 明天 / 本周 / 以后 / 没定时间。
class ItemsView extends StatefulWidget {
  const ItemsView({super.key, this.onChanged, this.tagId, this.onClearTag,
    this.revision = 0, this.showHeader = true,
    this.padding = const EdgeInsets.fromLTRB(40, 30, 40, 28)});

  final VoidCallback? onChanged;
  final String? tagId;
  final VoidCallback? onClearTag;
  final int revision;
  final bool showHeader;
  final EdgeInsets padding;

  @override
  State<ItemsView> createState() => _ItemsViewState();
}

class _ItemsViewState extends State<ItemsView> {
  final _keyword = TextEditingController();
  ItemStatus? _status = ItemStatus.todo;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  void _changed() {
    setState(() {});
    widget.onChanged?.call();
  }

  static String _group(Item item, DateTime now) {
    final due = item.dueAt?.toLocal();
    if (item.isDone) return '已完成';
    if (due == null) return '没定时间';
    if (due.isBefore(now)) return '逾期';
    final today = DateTime(now.year, now.month, now.day);
    final days = DateTime(due.year, due.month, due.day).difference(today).inDays;
    if (days == 0) return '今天';
    if (days == 1) return '明天';
    if (days < 8 - now.weekday) return '本周';
    return '以后';
  }

  static const _order = ['逾期', '今天', '明天', '本周', '以后', '没定时间', '已完成'];

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final now = DateTime.now();
    var items = scope.items.listItems(titleKeyword: _keyword.text, status: _status);
    final tagId = widget.tagId;
    final tag = tagId == null ? null : scope.tags.byId(tagId);
    if (tagId != null) {
      final ids = scope.items.byTag(tagId).map((i) => i.id).toSet();
      items = items.where((i) => ids.contains(i.id)).toList();
    }
    final groups = <String, List<Item>>{};
    for (final item in items) {
      groups.putIfAbsent(_group(item, now), () => []).add(item);
    }
    for (final list in groups.values) {
      list.sort((a, b) {
        final ad = a.dueAt, bd = b.dueAt;
        if (ad == null || bd == null) return b.createdAt.compareTo(a.createdAt);
        return ad.compareTo(bd);
      });
    }

    return Padding(
      padding: widget.padding,
      child: Align(alignment: Alignment.topLeft, child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader) ...[
            SeqPageHeader(
              title: tag == null ? '事项' : '#${tag.name}',
              subtitle: tag == null ? '所有便签里拆出来的事，按时间排好。' : '带这个标签的事项',
            ),
            const SizedBox(height: 18),
          ],
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final (status, label) in const [
              (ItemStatus.todo, '待办'), (ItemStatus.done, '已完成'), (null, '全部')])
              FilterPill(label: label, selected: _status == status,
                  onTap: () => setState(() => _status = status)),
            if (tag != null)
              InputChip(
                label: Text('#${tag.name}'),
                onDeleted: widget.onClearTag,
                deleteButtonTooltipMessage: '清除标签筛选',
                backgroundColor: SeqTokens.accentSoft,
                side: BorderSide.none,
              ),
            SizedBox(width: 240, height: 38, child: TextField(
              controller: _keyword,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '按标题筛选',
                isDense: true,
                filled: true,
                fillColor: SeqTokens.raised,
                prefixIcon: const Icon(Icons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: SeqTokens.line)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: SeqTokens.line)),
                suffixIcon: _keyword.text.isEmpty ? null : IconButton(
                  tooltip: '清除关键词',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => setState(_keyword.clear),
                ),
              ),
            )),
          ]),
          const SizedBox(height: 12),
          Expanded(child: items.isEmpty ? _empty(context) : ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final name in _order)
                if (groups[name] case final list?) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                    child: Row(children: [
                      Text(name, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700,
                          color: name == '逾期' ? SeqTokens.dangerInk : SeqTokens.inkSoft)),
                      const SizedBox(width: 8),
                      Text('${list.length}', style: const TextStyle(
                          fontSize: 12, color: SeqTokens.inkFaint)),
                    ]),
                  ),
                  for (final item in list) _tile(context, item, now),
                ],
            ],
          )),
        ],
      ),
      )),
    );
  }

  Widget _tile(BuildContext context, Item item, DateTime now) {
    final scope = AppScope.of(context);
    final noteId = item.noteId;
    return ItemTile(
      item: item,
      now: now,
      sourceNoteTitle: noteId == null ? null : scope.notes.byId(noteId)?.title,
      tagNames: [
        for (final id in scope.items.tagIdsOf(item.id))
          if (scope.tags.byId(id) case final tag?) tag.name,
      ],
      onTap: () async {
        if (await ItemEditorPage.open(context, item.id) == true && mounted) {
          _changed();
        }
      },
      onToggle: () {
        AppScope.of(context).noteService.toggleItem(item.id);
        _changed();
      },
    );
  }

  Widget _empty(BuildContext context) => Center(
        child: Text(
          _keyword.text.trim().isNotEmpty || widget.tagId != null ? '没有匹配的事项。'
              : switch (_status) {
                  ItemStatus.todo => '没有待办事项。',
                  ItemStatus.done => '没有已完成事项。',
                  _ => '没有事项。',
                },
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
}
