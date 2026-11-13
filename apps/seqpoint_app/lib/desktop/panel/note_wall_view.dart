import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../../app/app_scope.dart';
import '../../shared/note_card.dart';
import '../../shared/open_note.dart';
import '../../shared/seq_widgets.dart';

/// 便签筛选：全部 / 待整理（还没拆出事项）/ 进行中 / 可揭走（事项全部完成）。
enum NoteFilter { all, unorganized, inProgress, done }

extension NoteFilterLabel on NoteFilter {
  String get label => switch (this) {
        NoteFilter.all => '全部',
        NoteFilter.unorganized => '待整理',
        NoteFilter.inProgress => '进行中',
        NoteFilter.done => '可揭走',
      };

  bool matches(WallNote n) => switch (this) {
        NoteFilter.all => true,
        NoteFilter.unorganized => n.total == 0,
        NoteFilter.inProgress => n.total > 0 && n.done < n.total,
        NoteFilter.done => n.total > 0 && n.done == n.total,
      };
}

/// 便签墙：活跃便签的缩略卡片，可按状态筛选，办完的直接揭走。
class NoteWallView extends StatefulWidget {
  const NoteWallView({super.key, this.revision = 0, this.onChanged});

  final int revision;
  final VoidCallback? onChanged;

  @override
  State<NoteWallView> createState() => _NoteWallViewState();
}

class _NoteWallViewState extends State<NoteWallView> {
  List<WallNote> _notes = const [];
  NoteFilter _filter = NoteFilter.all;
  final _opening = <String>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  @override
  void didUpdateWidget(NoteWallView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _reload();
  }

  void _reload() {
    final wall = AppScope.of(context).notes.activeWithProgress();
    setState(() => _notes = [for (var i = 0; i < wall.length; i++) wall[i]]);
  }

  Future<void> _open(Note note) async {
    if (!_opening.add(note.id)) return;
    try {
      await openNote(context, note.id);
      if (mounted) _reload();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('打开便签失败，请重试。已保存的内容仍在。')));
    } finally {
      _opening.remove(note.id);
    }
  }

  void _peel(Note note) {
    final service = AppScope.of(context).noteService;
    service.close(note.id);
    _reload();
    widget.onChanged?.call();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: const Text('揭走了，在"已关闭"里能找回'),
        action: SnackBarAction(label: '撤销', onPressed: () {
          service.reopen(note.id);
          if (mounted) {
            _reload();
            widget.onChanged?.call();
          }
        }),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final visible = _notes.where(_filter.matches).toList();
    final counts = {for (final f in NoteFilter.values) f: _notes.where(f.matches).length};
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 30, 40, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SeqPageHeader(
          title: '便签',
          subtitle: _notes.isEmpty ? null : '${_notes.length} 张贴在墙上',
        ),
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in NoteFilter.values)
            FilterPill(
              label: f.label,
              count: counts[f],
              selected: _filter == f,
              onTap: () => setState(() => _filter = f),
            ),
        ]),
        const SizedBox(height: 18),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    _notes.isEmpty ? '还没有便签。点左上角“记一笔”。' : '这一栏是空的。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.only(bottom: 32, top: 4),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    crossAxisSpacing: 18,
                    mainAxisSpacing: 18,
                    childAspectRatio: 0.92,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (context, i) {
                    final entry = visible[i];
                    return NoteCard(
                      note: entry.note,
                      doneCount: entry.done,
                      totalCount: entry.total,
                      onTap: () => _open(entry.note),
                      onPeel: () => _peel(entry.note),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
