import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';

/// 已归档的便签，可搜索、可重新打开。
class ArchiveView extends StatefulWidget {
  const ArchiveView({super.key});

  @override
  State<ArchiveView> createState() => _ArchiveViewState();
}

class _ArchiveViewState extends State<ArchiveView> {
  List<Note> _notes = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() =>
      setState(() => _notes = AppScope.of(context).notes.closed());

  @override
  Widget build(BuildContext context) {
    if (_notes.isEmpty) {
      return Center(
        child: Text('还没有归档的便签。办完的事关掉，就会到这里。',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(36, 20, 36, 24),
      itemCount: _notes.length,
      itemBuilder: (context, i) {
        final note = _notes[i];
        return ListTile(
          title: Text(note.title ?? note.lines.first),
          subtitle: Text(note.closedAt == null
              ? ''
              : '关闭于 ${_formatDate(note.closedAt!)}'),
          trailing: TextButton(
            onPressed: () {
              AppScope.of(context).noteService.reopen(note.id);
              _reload();
            },
            child: const Text('重新打开'),
          ),
        );
      },
    );
  }

  static String _formatDate(DateTime t) {
    t = t.toLocal();
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
  }
}
