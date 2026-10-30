import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../settings/settings_scaffold.dart';
import '../shared/item_editor_page.dart';
import '../shared/item_tile.dart';

class TagsPage extends StatelessWidget {
  const TagsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final tags = AppScope.of(context).tags;
    return SettingsScaffold(
      title: '标签',
      children: [
        for (final kind in TagKind.values)
          SettingsGroup(
            label: switch (kind) {
              TagKind.project => '项目标签',
              TagKind.type => '任务类型',
              TagKind.custom => '自定义',
            },
            children: [
              if (tags.all(kind: kind).isEmpty)
                const ListTile(title: Text('还没有标签')),
              for (final tag in tags.all(kind: kind))
                ListTile(
                  title: Text(tag.name),
                  trailing: Text('${tags.usageCount(tag.id)} 件'),
                  onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => TaggedItemsPage(tag: tag),
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class TaggedItemsPage extends StatefulWidget {
  const TaggedItemsPage({super.key, required this.tag});
  final Tag tag;
  @override
  State<TaggedItemsPage> createState() => _TaggedItemsPageState();
}

class _TaggedItemsPageState extends State<TaggedItemsPage> {
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final items = scope.items.byTag(widget.tag.id);
    return Scaffold(
      appBar: AppBar(title: Text('#${widget.tag.name}')),
      body: items.isEmpty
          ? const Center(child: Text('这个标签下还没有事项'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                for (final item in items)
                  ItemTile(
                    item: item,
                    onToggle: () {
                      scope.noteService.toggleItem(item.id);
                      setState(() {});
                    },
                    onTap: () async {
                      await ItemEditorPage.open(context, item.id);
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
    );
  }
}
