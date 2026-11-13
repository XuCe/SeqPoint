import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/seq_widgets.dart';
import '../../theme/seq_tokens.dart';

/// 已关闭：揭走的便签与回收站合在一处，分两栏切换。
class ClosedView extends StatefulWidget {
  const ClosedView({super.key, this.onChanged, this.revision = 0, this.initialTrash = false,
    this.padding = const EdgeInsets.fromLTRB(40, 30, 40, 28), this.showHeader = true});

  final VoidCallback? onChanged;
  final int revision;
  final bool initialTrash;
  final EdgeInsets padding;
  final bool showHeader;

  @override
  State<ClosedView> createState() => _ClosedViewState();
}

class _ClosedViewState extends State<ClosedView> {
  late bool _trash = widget.initialTrash;
  List<Note> _closed = const [];
  List<Note> _trashed = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  @override
  void didUpdateWidget(ClosedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _reload();
  }

  void _reload() {
    final notes = AppScope.of(context).notes;
    setState(() {
      _closed = notes.closed();
      _trashed = notes.trashed();
    });
  }

  void _act(void Function(NoteService) action, String message, {void Function(NoteService)? undo}) {
    final service = AppScope.of(context).noteService;
    action(service);
    _reload();
    widget.onChanged?.call();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: undo == null ? null : SnackBarAction(label: '撤销', onPressed: () {
          undo(service);
          if (mounted) {
            _reload();
            widget.onChanged?.call();
          }
        }),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final notes = _trash ? _trashed : _closed;
    return ListView(
      padding: widget.padding,
      children: [
        if (widget.showHeader) ...[
          const SeqPageHeader(title: '已关闭', subtitle: '揭走的便签留在这里，随时可以重新打开。'),
          const SizedBox(height: 18),
        ],
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilterPill(label: '已揭走', count: _closed.length, selected: !_trash,
              onTap: () {
                _trash = false;
                _reload();
              }),
          FilterPill(label: '回收站', count: _trashed.length, selected: _trash,
              onTap: () {
                _trash = true;
                _reload();
              }),
          if (_trash)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text('删除 30 天后自动清除',
                  style: TextStyle(fontSize: 12.5, color: SeqTokens.inkMuted)),
            ),
        ]),
        const SizedBox(height: 14),
        if (notes.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 56),
            child: Center(child: Text(
              _trash ? '回收站是空的。' : '还没有揭走的便签。办完的事揭走，就会到这里。',
              style: Theme.of(context).textTheme.bodySmall,
            )),
          )
        else
          SeqCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (var i = 0; i < notes.length; i++) ...[
                if (i > 0) const Divider(height: 1, color: SeqTokens.lineSoft),
                _ClosedRow(
                  key: ValueKey('closed-${notes[i].id}'),
                  note: notes[i],
                  trash: _trash,
                  onRestore: () => _trash
                      ? _act((s) => s.restore(notes[i].id), '已恢复到便签',
                          undo: (s) => s.trash(notes[i].id))
                      : _act((s) => s.reopen(notes[i].id), '已重新打开',
                          undo: (s) => s.close(notes[i].id)),
                ),
              ],
            ]),
          ),
      ],
    );
  }
}

class _ClosedRow extends StatelessWidget {
  const _ClosedRow({super.key, required this.note, required this.trash, required this.onRestore});

  final Note note;
  final bool trash;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final color = SeqTokens.noteColors[note.color] ?? SeqTokens.noteYellow;
    final title = note.title?.trim().isNotEmpty == true
        ? note.title!
        : note.lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '（空便签）').trim();
    final when = trash ? note.deletedAt : note.closedAt;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
      child: Row(children: [
        Container(width: 14, height: 14, decoration: BoxDecoration(color: color,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: const Color(0x22000000)))),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5)),
            if (when != null)
              Text('${trash ? '删除于' : '揭走于'} ${_formatDate(when)}',
                  style: const TextStyle(fontSize: 12, color: SeqTokens.inkMuted)),
          ]),
        ),
        TextButton(
          onPressed: onRestore,
          style: TextButton.styleFrom(foregroundColor: SeqTokens.accentInk),
          child: Text(trash ? '恢复' : '重新打开'),
        ),
      ]),
    );
  }

  static String _formatDate(DateTime t) {
    t = t.toLocal();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
  }
}
