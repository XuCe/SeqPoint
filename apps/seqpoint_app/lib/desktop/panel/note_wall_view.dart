import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/note_card.dart';

/// 便签墙：活跃便签的缩略图网格，点击还原为桌面便签窗。
class NoteWallView extends StatefulWidget {
  const NoteWallView({super.key});

  @override
  State<NoteWallView> createState() => _NoteWallViewState();
}

class _NoteWallViewState extends State<NoteWallView> {
  List<Note> _notes = const [];
  bool _opening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() =>
      setState(() => _notes = AppScope.of(context).notes.active());

  Future<void> _open(Note note) async {
    final windows = AppScope.of(context).windows;
    if (windows == null || _opening) return;
    _opening = true;
    try {
      await windows.openSticky(note.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('打开便签失败，请重试。已保存的内容仍在。')));
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_notes.isEmpty) {
      return Center(
        child: Text(
          '还没有便签。点击“新建便签”记一笔。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(28),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
        childAspectRatio: 0.95,
      ),
      itemCount: _notes.length,
      itemBuilder: (context, i) {
        final note = _notes[i];
        final items = AppScope.of(context).items.byNote(note.id);
        return NoteCard(
          note: note,
          doneCount: items.where((it) => it.isDone).length,
          totalCount: items.length,
          onTap: () => _open(note),
        );
      },
    );
  }
}
