import 'package:flutter/material.dart';
import 'package:seqpoint_core/seqpoint_core.dart';
import 'package:window_manager/window_manager.dart';

import '../../app/app_scope.dart';
import '../../shared/item_editor_page.dart';
import '../../shared/organize_button.dart';
import '../../shared/note_search.dart';
import '../../theme/seq_tokens.dart';
import 'item_row.dart';
import 'note_editor.dart';
import 'sticky_shortcuts.dart';

/// 桌面便签窗：贴在屏幕上的那张纸。
///
/// 形态：小窗、可拖动、大小与位置记忆、可选置顶、可多开、可选底色。
/// 右上角三个入口：✨ 整理、置顶、关闭。底部显示完成进度与提醒时间。
class StickyWindow extends StatefulWidget {
  const StickyWindow({super.key, required this.noteId, this.onClose});

  final String noteId;
  final VoidCallback? onClose;

  @override
  State<StickyWindow> createState() => _StickyWindowState();
}

class _StickyWindowState extends State<StickyWindow> with WindowListener {
  Note? _note;
  List<Item> _items = const [];
  bool _pinned = false;
  bool _pinning = false;
  int _currentRow = 0;

  Future<void> _search() async {
    await openNoteSearch(context);
    if (mounted) _reload();
  }

  void _activateCurrent({bool complete = false}) {
    final note = _note;
    if (note == null) return;
    final byLine = _itemsByLine(note.lines);
    final rows = [
      for (var i = 0; i < note.lines.length; i++) byLine[i],
      ..._items.where((i) => byLine[i.lineIndex]?.id != i.id),
    ];
    if (_currentRow >= rows.length) return;
    final item = rows[_currentRow];
    if (item != null) {
      if (!complete || !item.isDone) _toggle(item);
    } else if (!complete && note.lines[_currentRow].trim().isNotEmpty) {
      _convert(_currentRow);
    }
  }

  void _archive() {
    try {
      AppScope.of(context).noteService.close(widget.noteId);
      _reload();
      widget.onClose?.call();
    } catch (_) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('归档失败，请重试。')));
    }
  }

  void _trash() {
    try {
      AppScope.of(context).noteService.trash(widget.noteId);
      _reload();
      widget.onClose?.call();
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('移入回收站失败，请重试。')));
    }
  }

  Future<void> _togglePin() async {
    final windows = AppScope.of(context).windows;
    if (windows == null || _pinning) return;
    setState(() => _pinning = true);
    try {
      await windows.setAlwaysOnTop(!_pinned);
      if (mounted) setState(() => _pinned = !_pinned);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('置顶设置失败，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    _reload();
  }

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

  /// 行号 → 事项，用于把勾选状态回显到便签正文那一行。
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
  }

  void _convert(int lineIndex) {
    AppScope.of(context).noteService.lineToItem(widget.noteId, lineIndex);
    _reload();
  }

  Future<void> _edit() async {
    await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => NoteEditor(noteId: widget.noteId)),
    );
    if (mounted) _reload();
  }

  Future<void> _editItem(Item item) async {
    await ItemEditorPage.open(context, item.id);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    if (note == null) {
      return const Scaffold(
        backgroundColor: SeqTokens.noteYellow,
        body: Center(child: Text('便签不存在')),
      );
    }

    final lines = note.lines;
    final byLine = _itemsByLine(lines);
    final standalone = _items
        .where((i) => byLine[i.lineIndex]?.id != i.id)
        .toList();
    final doneCount = _items.where((i) => i.isDone).length;

    final view = Scaffold(
      backgroundColor: SeqTokens.noteYellow,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TitleBar(
            title: note.title ?? '便签',
            onEdit: _edit,
            onArchive: _archive,
            onTrash: _trash,
            organizeButton: OrganizeButton(noteId: widget.noteId, onApplied: _reload, compact: true),
            pinned: _pinned,
            onPin: _pinning || AppScope.of(context).windows == null
                ? null
                : _togglePin,
            onClose: widget.onClose,
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              itemCount: lines.length + standalone.length,
              itemBuilder: (context, index) {
                final extra = index >= lines.length;
                final item = extra
                    ? standalone[index - lines.length]
                    : byLine[index];
                return ItemRow(
                  onFocusChange: (focused) {
                    if (focused) _currentRow = index;
                  },
                  text: extra ? item!.title : lines[index],
                  isItem: item != null,
                  isDone: item?.isDone ?? false,
                  onToggle: item == null
                      ? null
                      : () {
                          _currentRow = index;
                          _toggle(item);
                        },
                  onEdit: item == null ? null : () => _editItem(item),
                  onConvert:
                      extra || item != null || lines[index].trim().isEmpty
                      ? null
                      : () {
                          _currentRow = index;
                          _convert(index);
                        },
                );
              },
            ),
          ),
          if (_items.isNotEmpty)
            _FooterBar(done: doneCount, total: _items.length),
        ],
      ),
    );
    return StickyShortcuts(
      actions: {
        StickyIntent.toggleItem: () => _activateCurrent(),
        StickyIntent.complete: () => _activateCurrent(complete: true),
        StickyIntent.pin: _togglePin,
        StickyIntent.close: _archive,
        StickyIntent.search: _search,
        if (widget.onClose case final close?) StickyIntent.dismiss: close,
      },
      child: view,
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    required this.onEdit,
    required this.onArchive,
    required this.onTrash,
    required this.organizeButton,
    required this.pinned,
    this.onPin,
    this.onClose,
  });

  final String title;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onTrash;
  final Widget organizeButton;
  final bool pinned;
  final VoidCallback? onPin;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.only(left: 14, right: 8),
      color: SeqTokens.noteInk.withValues(alpha: 0.06),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 12,
                letterSpacing: 0.6,
                color: Color(0xFF7A6620),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _TitleAction(
            icon: Icons.edit_outlined,
            tooltip: '编辑便签',
            onPressed: onEdit,
          ),
          organizeButton,
          _TitleAction(
            icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
            tooltip: pinned ? '取消置顶' : '置顶',
            onPressed: onPin,
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_horiz, size: 18),
            padding: EdgeInsets.zero,
            onSelected: (action) => action == 'archive' ? onArchive() : onTrash(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'archive', child: Text('归档')),
              PopupMenuItem(value: 'trash', child: Text('移入回收站')),
            ],
          ),
          _TitleAction(icon: Icons.close, tooltip: '关闭', onPressed: onClose),
        ],
      ),
    );
  }
}

class _TitleAction extends StatelessWidget {
  const _TitleAction({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 15),
      color: const Color(0xFF7A6620),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}

class _FooterBar extends StatelessWidget {
  const _FooterBar({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final allDone = done == total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: [
          Text(
            allDone ? '全部完成 · 可以关闭了' : '$done / $total 完成',
            style: const TextStyle(fontSize: 12, color: Color(0xFF8A7A45)),
          ),
        ],
      ),
    );
  }
}
