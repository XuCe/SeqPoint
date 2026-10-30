import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/item_tile.dart';
import '../../shared/item_editor_page.dart';

/// 跨便签的事项列表。M1 先给全量，筛选在后续版本补。
class ItemsView extends StatefulWidget {
  const ItemsView({super.key, this.onChanged});

  final VoidCallback? onChanged;

  @override
  State<ItemsView> createState() => _ItemsViewState();
}

class _ItemsViewState extends State<ItemsView> {
  List<Item> _items = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() =>
      setState(() => _items = AppScope.of(context).items.openAll());

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) {
      return Center(
        child: Text('没有待办事项。', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(36, 20, 36, 24),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        return ItemTile(
          item: item,
          onTap: () async {
            if (await ItemEditorPage.open(context, item.id) == true &&
                mounted) {
              _reload();
              widget.onChanged?.call();
            }
          },
          onToggle: () {
            AppScope.of(context).noteService.toggleItem(item.id);
            _reload();
            widget.onChanged?.call();
          },
        );
      },
    );
  }
}
