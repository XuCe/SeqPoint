import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

import '../app/app_scope.dart';
import '../features/attachments/attachment_panel.dart';
import '../features/meetings/meeting_panel.dart';
import '../shared/item_editor_page.dart';
import '../shared/organize_button.dart';
import '../desktop/sticky/item_row.dart';
import '../theme/seq_tokens.dart';
import 'quick_capture_page.dart';

/// 便签详情：移动端上的"那张纸"。
///
/// 与桌面便签窗共用行组件，交互一致：点空行首的 ○ 转为事项，
/// 点已有事项勾选完成；全部完成后提示关闭。
class NoteDetailPage extends StatefulWidget {
  const NoteDetailPage({super.key, required this.noteId, this.onDismiss, this.onChanged});

  final String noteId;

  /// 不为空时作为桌面主面板右侧的嵌入面板：关闭不弹路由，而是回调。
  final VoidCallback? onDismiss;

  /// 便签或事项发生变化时通知宿主刷新列表。
  final VoidCallback? onChanged;

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

  @override
  void didUpdateWidget(NoteDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != widget.noteId) _reload();
  }

  void _reload({bool changed = false}) {
    final scope = AppScope.of(context);
    setState(() {
      _note = scope.notes.byId(widget.noteId);
      _items = scope.items.byNote(widget.noteId);
    });
    if (changed) widget.onChanged?.call();
  }

  void _dismiss() {
    final dismiss = widget.onDismiss;
    if (dismiss != null) {
      dismiss();
    } else {
      Navigator.of(context).pop();
    }
  }

  Map<int, Item> _itemsByLine(List<String> lines) => Note.itemsByLine(lines, _items);

  void _toggle(Item item) {
    AppScope.of(context).noteService.toggleItem(item.id);
    _reload(changed: true);
    _maybeOfferClose();
  }

  void _convert(int lineIndex) {
    AppScope.of(context).noteService.lineToItem(widget.noteId, lineIndex);
    _reload(changed: true);
  }

  Future<void> _editItem(Item item) async {
    if (await ItemEditorPage.open(context, item.id) == true && mounted) {
      _reload(changed: true);
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
          label: '揭走',
          onPressed: () {
            scope.noteService.close(widget.noteId);
            widget.onChanged?.call();
            if (mounted) _dismiss();
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

    final paper = SeqTokens.noteColors[note.color] ?? SeqTokens.noteYellow;
    final embedded = widget.onDismiss != null;
    final allDone = _items.isNotEmpty && doneCount == _items.length;

    return Scaffold(
      backgroundColor: paper,
      appBar: AppBar(
        backgroundColor: paper,
        foregroundColor: SeqTokens.noteInk,
        automaticallyImplyLeading: !embedded,
        leading: embedded
            ? IconButton(tooltip: '关闭', icon: const Icon(Icons.close), onPressed: _dismiss)
            : null,
        titleSpacing: embedded ? 0 : null,
        title: Text(note.title ?? '便签', style: TextStyle(
          fontFamily: SeqFonts.serif.first,
          fontFamilyFallback: SeqFonts.serif,
          fontWeight: FontWeight.w700,
          fontSize: 18,
        )),
        actions: [
          IconButton(tooltip: '编辑便签', icon: const Icon(Icons.edit_outlined),
            onPressed: () async {
              final saved = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => QuickCapturePage(note: note)));
              if (mounted && saved == true) _reload(changed: true);
            }),
          OrganizeButton(noteId: widget.noteId, onApplied: () => _reload(changed: true)),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) {
              final scope = AppScope.of(context);
              if (value == 'close') {
                scope.noteService.close(widget.noteId);
              } else if (value == 'trash') {
                scope.noteService.trash(widget.noteId);
              }
              widget.onChanged?.call();
              _dismiss();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'close', child: Text('揭走（办完收起）')),
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
                  enabled: !scope.restoring, onChanged: () => _reload(changed: true)),
            ]);
          }
          final extra = index >= lines.length;
          final item = extra ? standalone[index - lines.length] : byLine[index];
          return ItemRow(
            text: item?.title ?? lines[index],
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
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: doneCount / _items.length,
                            minHeight: 4,
                            backgroundColor: SeqTokens.noteInk.withValues(alpha: 0.12),
                            color: SeqTokens.noteInk,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          allDone ? '都办完了 · 可以揭走了' : '$doneCount / ${_items.length} 完成',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF6B5A20)),
                        ),
                      ],
                    ),
                  ),
                  if (allDone) ...[
                    const SizedBox(width: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: SeqTokens.noteInk,
                        foregroundColor: paper,
                      ),
                      onPressed: () {
                        AppScope.of(context).noteService.close(widget.noteId);
                        widget.onChanged?.call();
                        _dismiss();
                      },
                      child: const Text('揭走这张'),
                    ),
                  ],
                ]),
              ),
            ),
    );
  }
}
