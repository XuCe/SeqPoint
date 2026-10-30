import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

/// AI 整理确认卡。双端共用。
///
/// 铁律：未确认前不写入任何业务对象。
/// 首批仅预览可保存字段并逐项勾选，保留来源正文和稳定候选身份。
class OrganizeConfirmCard extends StatefulWidget {
  const OrganizeConfirmCard({
    super.key,
    required this.proposal,
    required this.onAccept,
    required this.onCancel,
  });

  final OrganizeProposal proposal;
  final Future<void> Function(OrganizeProposal) onAccept;
  final VoidCallback onCancel;

  @override
  State<OrganizeConfirmCard> createState() => _OrganizeConfirmCardState();
}

class _OrganizeConfirmCardState extends State<OrganizeConfirmCard> {
  late final _items = widget.proposal.items.toList();
  bool _submitting = false;
  String? _error;
  Future<void> _accept() async {
    if (_submitting || !_items.any((item) => item.accepted)) return;
    setState(() { _submitting = true; _error = null; });
    try {
      await widget.onAccept(OrganizeProposal(noteId: widget.proposal.noteId,
          sourceContent: widget.proposal.sourceContent, items: _items.toList()));
    } catch (error) {
      if (mounted) setState(() => _error = error is StateError ? error.message : '采纳失败，请重试');
    } finally { if (mounted) setState(() => _submitting = false); }
  }
  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(padding: EdgeInsets.all(16), child: Text('请选择要采纳的事项，原文保持不变')),
      if (_items.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('没有可采纳的新事项')),
      if (_submitting) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      Expanded(child: ListView.builder(itemCount: _items.length, itemBuilder: (context, index) {
        final item = _items[index]; final due = item.dueAt?.toLocal();
        return CheckboxListTile(key: ValueKey(item.id), value: item.accepted,
            title: Text(item.title), controlAffinity: ListTileControlAffinity.leading,
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (item.lineIndex != null) Text('来源：第 ${item.lineIndex! + 1} 行'),
              if (item.important) const Text('⭐ 重要'),
              if (item.typeTagName != null) Text('类型：${item.typeTagName}'),
              if (item.projectTagName != null) Text('项目：${item.projectTagName}'),
              if (due != null) Text('期限：${localizations.formatCompactDate(due)} '
                  '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(due), alwaysUse24HourFormat: true)}'),
            ]), onChanged: _submitting ? null :
                (value) => setState(() => _items[index] = item.copyWith(accepted: value ?? false)));
      })),
      Padding(padding: const EdgeInsets.all(16), child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: _submitting ? null : widget.onCancel, child: const Text('取消')),
        const SizedBox(width: 12),
        FilledButton(onPressed: _submitting || !_items.any((item) => item.accepted) ? null : _accept,
            child: const Text('采纳勾选项')),
      ])),
    ]);
  }
}
