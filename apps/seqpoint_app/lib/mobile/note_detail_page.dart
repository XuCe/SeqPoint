import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../features/attachments/attachment_panel.dart';
import '../features/meetings/meeting_panel.dart';
import '../shared/item_editor_page.dart';
import '../shared/organize_button.dart';
import '../desktop/sticky/item_row.dart';
import '../theme/seq_tokens.dart';

/// 便签详情：移动端上的"那张纸"。
///
/// 与桌面便签窗共用行组件，交互一致：点空行首的 ○ 转为事项，
/// 点已有事项勾选完成；全部完成后提示关闭。
class NoteDetailPage extends StatefulWidget {
  const NoteDetailPage({super.key, required this.noteId});

  final String noteId;

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

class _NoteDetailPageState extends State<NoteDetailPage> {
  Note? _note;
  List<Item> _items = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reload();
  }

  void _reload() {
    final scope = AppScope.of(context);
    setState(() {
      _note = scope.notes.byId(widget.noteId);
      _items = scope.items.byNote(widget.noteId);
    });
  }

  Map<int, Item> _itemsByLine(List<String> lines) => {
    for (final i in _items)
      if (i.lineIndex != null &&
          i.lineIndex! >= 0 &&
          i.lineIndex! < lines.length &&
          lines[i.lineIndex!].trim() == i.title)
        i.lineIndex!: i,
  };

  void _toggle(Item item) {
    AppScope.of(context).noteService.toggleItem(item.id);
    _reload();
    _maybeOfferClose();
  }

  void _convert(int lineIndex) {
    AppScope.of(context).noteService.lineToItem(widget.noteId, lineIndex);
    _reload();
  }

  Future<void> _editItem(Item item) async {
    if (await ItemEditorPage.open(context, item.id) == true && mounted) {
      _reload();
    }
  }

  /// 全部事项完成时提示关闭——这是产品的情绪终点，但不自动执行。
  Future<void> _maybeOfferClose() async {
    final scope = AppScope.of(context);
    if (!scope.noteService.allItemsDone(widget.noteId)) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('这张便签的事都办完了'),
        action: SnackBarAction(
          label: '关闭它',
          onPressed: () {
            scope.noteService.close(widget.noteId);
            if (mounted) Navigator.of(context).pop();
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (note == null) {
      return const Scaffold(body: Center(child: Text('便签不存在')));
    }

    final lines = note.lines;
    final byLine = _itemsByLine(lines);
    final standalone = _items
        .where((i) => byLine[i.lineIndex]?.id != i.id)
        .toList();
    final doneCount = _items.where((i) => i.isDone).length;
    final scope = AppScope.of(context);
    final database = scope.database;
    final rowCount = lines.length + standalone.length;

    return Scaffold(
      backgroundColor: SeqTokens.noteYellow,
      appBar: AppBar(
        backgroundColor: SeqTokens.noteYellow,
        foregroundColor: SeqTokens.noteInk,
        title: Text(note.title ?? '便签'),
        actions: [
          OrganizeButton(noteId: widget.noteId, onApplied: _reload),
          PopupMenuButton<String>(
            onSelected: (value) {
              final scope = AppScope.of(context);
              if (value == 'close') {
                scope.noteService.close(widget.noteId);
              } else if (value == 'trash') {
                scope.noteService.trash(widget.noteId);
              }
              Navigator.of(context).pop();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'close', child: Text('关闭（归档）')),
              PopupMenuItem(value: 'trash', child: Text('删除')),
            ],
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: rowCount + (database == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (index == rowCount) {
            return Column(children: [
              AttachmentPanel(database: database!, noteId: note.id, enabled: !scope.restoring),
              MeetingPanel(database: database, noteId: note.id, noteService: scope.noteService,
                  enabled: !scope.restoring, onChanged: _reload),
            ]);
          }
          final extra = index >= lines.length;
          final item = extra ? standalone[index - lines.length] : byLine[index];
          return ItemRow(
            text: extra ? item!.title : lines[index],
            isItem: item != null,
            isDone: item?.isDone ?? false,
            onToggle: item == null ? null : () => _toggle(item),
            onEdit: item == null ? null : () => _editItem(item),
            onConvert: extra || item != null || lines[index].trim().isEmpty
                ? null
                : () => _convert(index),
          );
        },
      ),
      bottomNavigationBar: _items.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Text(
                doneCount == _items.length
                    ? '全部完成 · 可以关闭了'
                    : '$doneCount / ${_items.length} 完成',
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A7A45)),
              ),
            ),
    );
  }
}
