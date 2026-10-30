import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../shared/item_tile.dart';
import '../shared/item_editor_page.dart';
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
  List<Note> _notes = const [];
  List<Item> _items = const [];

  Future<void> _search() async {
    await openNoteSearch(context);
    if (mounted) _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final scope = AppScope.of(context);
    setState(() {
      _notes = scope.notes.active();
      _items = scope.items.openAll();
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
                    onSelectionChanged: (s) => setState(() => _view = s.first),
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
          Expanded(child: _view == 0 ? _buildWall() : _buildItems()),
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
        final note = _notes[i];
        final scope = AppScope.of(context);
        final items = scope.items.byNote(note.id);
        return NoteCard(
          note: note,
          doneCount: items.where((it) => it.isDone).length,
          totalCount: items.length,
          onTap: () => _openNote(note),
        );
      },
    );
  }

  Widget _buildItems() {
    if (_items.isEmpty) return const _Empty(text: '没有待办事项。');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        return ItemTile(
          item: item,
          onTap: () async {
            if (await ItemEditorPage.open(context, item.id) == true &&
                mounted) {
              _reload();
            }
          },
          onToggle: () {
            AppScope.of(context).noteService.toggleItem(item.id);
            _reload();
          },
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
