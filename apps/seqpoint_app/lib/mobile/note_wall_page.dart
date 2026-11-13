import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../desktop/panel/items_view.dart';
import '../desktop/panel/note_wall_view.dart' show NoteFilter, NoteFilterLabel;
import '../shared/note_card.dart';
import '../shared/note_search.dart';
import '../shared/seq_widgets.dart';
import '../theme/seq_tokens.dart';
import 'note_detail_page.dart';

/// 便签 Tab：内含"便签墙 / 事项"两个切换视图，便签墙可按状态筛选。
class NoteWallPage extends StatefulWidget {
  const NoteWallPage({super.key});

  @override
  State<NoteWallPage> createState() => _NoteWallPageState();
}

class _NoteWallPageState extends State<NoteWallPage> {
  int _view = 0;
  List<WallNote> _notes = const [];
  NoteFilter _filter = NoteFilter.all;

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
        final wall = scope.notes.activeWithProgress();
        _notes = [for (var i = 0; i < wall.length; i++) wall[i]];
      }
    });
  }

  Future<void> _openNote(Note note) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)));
    if (mounted) _reload();
  }

  void _peel(Note note) {
    final service = AppScope.of(context).noteService;
    service.close(note.id);
    _reload();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('揭走了，在"我的 · 已关闭"里能找回'),
        action: SnackBarAction(label: '撤销', onPressed: () {
          service.reopen(note.id);
          if (mounted) _reload();
        }),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 10, 0),
            child: Row(children: [
              Expanded(child: Text('便签', style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(fontSize: 28))),
              IconButton(
                onPressed: _search,
                icon: const Icon(Icons.search),
                color: SeqTokens.inkMuted,
                tooltip: '搜索',
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('便签墙')),
                ButtonSegment(value: 1, label: Text('事项')),
              ],
              selected: {_view},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: SeqTokens.ink,
                selectedForegroundColor: SeqTokens.paper,
                side: const BorderSide(color: SeqTokens.line),
              ),
              onSelectionChanged: (s) => _reload(view: s.first),
            ),
          ),
          Expanded(child: _view == 0 ? _buildWall() : ItemsView(
            showHeader: false,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            onChanged: _reload,
          )),
        ],
      ),
    );
  }

  Widget _buildWall() {
    if (_notes.isEmpty) return const _Empty(text: '还没有便签。点下面的“记一笔”写一句。');
    final visible = _notes.where(_filter.matches).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          children: [
            for (final f in NoteFilter.values) ...[
              FilterPill(
                label: f.label,
                count: _notes.where(f.matches).length,
                selected: _filter == f,
                onTap: () => setState(() => _filter = f),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
      Expanded(
        child: visible.isEmpty
            ? const _Empty(text: '这一栏是空的。')
            : GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 104),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.86,
                ),
                itemCount: visible.length,
                itemBuilder: (context, i) {
                  final entry = visible[i];
                  return NoteCard(
                    note: entry.note,
                    doneCount: entry.done,
                    totalCount: entry.total,
                    onTap: () => _openNote(entry.note),
                    onPeel: () => _peel(entry.note),
                  );
                },
              ),
      ),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Center(child: Text(text, style: Theme.of(context).textTheme.bodySmall));
}
