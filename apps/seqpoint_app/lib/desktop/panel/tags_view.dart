import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/section_label.dart';
import '../../theme/seq_tokens.dart';

/// 两维标签管理：项目标签与类型标签。内置类型标签只可重命名。
class TagsView extends StatefulWidget {
  const TagsView({super.key});

  @override
  State<TagsView> createState() => _TagsViewState();
}

class _TagsViewState extends State<TagsView> {
  List<Tag> _project = const [];
  List<Tag> _type = const [];
  List<Tag> _custom = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final tags = AppScope.of(context).tags;
    setState(() {
      _project = tags.all(kind: TagKind.project);
      _type = tags.all(kind: TagKind.type);
      _custom = tags.all(kind: TagKind.custom);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(36, 20, 36, 24),
      children: [
        const SectionLabel('项目标签'),
        if (_project.isEmpty)
          const _Hint('还没有项目标签。AI 整理时会从你的记录里归纳出来。')
        else
          _chips(_project),
        const SectionLabel('任务类型'),
        _chips(_type),
        if (_custom.isNotEmpty) ...[
          const SectionLabel('自定义'),
          _chips(_custom),
        ],
      ],
    );
  }

  Widget _chips(List<Tag> tags) {
    final scope = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final tag in tags)
            Chip(
              label: Text('${tag.name}  ${scope.tags.usageCount(tag.id)}'),
              backgroundColor: tag.kind == TagKind.project
                  ? SeqTokens.accentSoft
                  : null,
              side: BorderSide(color: SeqTokens.line),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text, style: Theme.of(context).textTheme.bodySmall),
      );
}
