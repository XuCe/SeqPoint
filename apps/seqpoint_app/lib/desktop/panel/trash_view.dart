import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';

/// 回收站，30 天后自动清除。
class TrashView extends StatefulWidget {
  const TrashView({super.key, this.onChanged});

  final VoidCallback? onChanged;

  @override
  State<TrashView> createState() => _TrashViewState();
}

class _TrashViewState extends State<TrashView> {
  List<Note> _notes = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() =>
      setState(() => _notes = AppScope.of(context).notes.trashed());

  @override
  Widget build(BuildContext context) {
    if (_notes.isEmpty) {
      return Center(
        child: Text('回收站是空的。',
            style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 20, 36, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('删除 30 天后自动清除',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(36, 8, 36, 24),
            itemCount: _notes.length,
            itemBuilder: (context, i) {
              final note = _notes[i];
              return ListTile(
                title: Text(note.title ?? note.lines.first),
                trailing: TextButton(
                  onPressed: () {
                    AppScope.of(context).noteService.restore(note.id);
                    _reload();
                    widget.onChanged?.call();
                  },
                  child: const Text('恢复'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
