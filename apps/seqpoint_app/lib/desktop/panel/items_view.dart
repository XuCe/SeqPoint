import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/item_tile.dart';
import '../../shared/item_editor_page.dart';

/// 跨便签的事项列表。
class ItemsView extends StatefulWidget {
  const ItemsView({super.key, this.onChanged,
    this.padding = const EdgeInsets.fromLTRB(36, 20, 36, 24)});

  final VoidCallback? onChanged;
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

  @override
  Widget build(BuildContext context) => Padding(
    padding: widget.padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(width: 280, child: TextField(
            controller: _keyword,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '按标题筛选',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _keyword.text.isEmpty ? null : IconButton(
                tooltip: '清除关键词',
                icon: const Icon(Icons.clear),
                onPressed: () => setState(_keyword.clear),
              ),
            ),
          )),
          SegmentedButton<ItemStatus?>(
            segments: const [
              ButtonSegment(value: ItemStatus.todo, label: Text('待办')),
              ButtonSegment(value: ItemStatus.done, label: Text('已完成')),
              ButtonSegment(value: null, label: Text('全部')),
            ],
            selected: {_status},
            showSelectedIcon: false,
            onSelectionChanged: (selected) => setState(() => _status = selected.single),
          ),
        ]),
        const SizedBox(height: 8),
        Expanded(child: _buildList(AppScope.of(context).items.listItems(
          titleKeyword: _keyword.text,
          status: _status,
        ))),
      ],
    ),
  );

  Widget _buildList(List<Item> items) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          _keyword.text.trim().isNotEmpty ? '没有匹配的事项。'
              : switch (_status) {
                  ItemStatus.todo => '没有待办事项。',
                  ItemStatus.done => '没有已完成事项。',
                  _ => '没有事项。',
                },
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return ItemTile(
          item: item,
          onTap: () async {
            if (await ItemEditorPage.open(context, item.id) == true &&
                mounted) {
              _changed();
            }
          },
          onToggle: () {
            AppScope.of(context).noteService.toggleItem(item.id);
            _changed();
          },
        );
      },
    );
  }
}
