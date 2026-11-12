import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../desktop/panel/items_view.dart';
import '../shared/note_card.dart';
import '../shared/note_search.dart';
import '../theme/seq_tokens.dart';
import 'note_detail_page.dart';

/// 便签 Tab：内含"便签墙 / 全部事项"两个切换视图。
class NoteWallPage extends StatefulWidget {
  const NoteWallPage({super.key});

  @override
  State<NoteWallPage> createState() => _NoteWallPageState();
}

class _NoteWallPageState extends State<NoteWallPage> {
  int _view = 0;
  late NoteWallSnapshot _notes;

  Future<void> _search() async {
    await openNoteSearch(context);
    if (mounted) _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload({int? view}) {
    final scope = AppScope.of(context);
    setState(() {
      _view = view ?? _view;
      if (_view == 0) {
        _notes = scope.notes.activeWithProgress();
      }
    });
  }

  Future<void> _openNote(Note note) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('便签墙')),
                      ButtonSegment(value: 1, label: Text('全部事项')),
                    ],
                    selected: {_view},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => _reload(view: s.first),
                  ),
                ),
                IconButton(
                  onPressed: _search,
                  icon: const Icon(Icons.search),
                  color: SeqTokens.inkMuted,
                  tooltip: '搜索',
                ),
              ],
            ),
          ),
          Expanded(child: _view == 0 ? _buildWall() : ItemsView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            onChanged: _reload,
          )),
        ],
      ),
    );
  }

  Widget _buildWall() {
    if (_notes.isEmpty) return const _Empty(text: '还没有便签。点 ＋ 记一笔。');
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 0.92,
      ),
      itemCount: _notes.length,
      itemBuilder: (context, i) {
        final entry = _notes[i];
        return NoteCard(
          note: entry.note,
          doneCount: entry.done,
          totalCount: entry.total,
          onTap: () => _openNote(entry.note),
        );
      },
    );
  }

}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, style: Theme.of(context).textTheme.bodySmall));
}
