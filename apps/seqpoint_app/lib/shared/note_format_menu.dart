import 'package:flutter/material.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';

import 'note_shortcuts.dart';
import 'note_list_edit.dart';

enum _Action { checklist, promote, bold, indent, outdent, undo, redo }

class NoteFormatMenu extends StatelessWidget {
  const NoteFormatMenu({super.key, required this.controller, required this.onPromote});
  final MarkdownEditorController controller;
  final ValueChanged<int> onPromote;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_Action>(
    tooltip: '编辑操作',
    icon: const Icon(Icons.more_horiz),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: _Action.promote,
        enabled:
            controller.selection.isValid &&
            controller.selection.isCollapsed &&
            controller.text.split('\n')[_currentLine()].trim().isNotEmpty,
        child: const Text('保存并将当前行转为待办'),
      ),
      PopupMenuItem(
        value: _Action.checklist,
        enabled: controller.selection.isValid && !controller.selection.isCollapsed,
        child: const Text('选中行转为勾选清单'),
      ),
      PopupMenuItem(
        value: _Action.bold,
        enabled: controller.selection.isValid && !controller.selection.isCollapsed,
        child: const Text('加粗选中文字'),
      ),
      PopupMenuItem(value: _Action.undo, enabled: controller.canUndo, child: const Text('撤销')),
      if (editNoteList(controller.value, NoteListAction.indent) != null)
        const PopupMenuItem(value: _Action.indent, child: Text('增加列表缩进')),
      if (editNoteList(controller.value, NoteListAction.outdent) != null)
        const PopupMenuItem(value: _Action.outdent, child: Text('减少列表缩进')),
      PopupMenuItem(value: _Action.redo, enabled: controller.canRedo, child: const Text('重做')),
    ],
    onSelected: (action) {
      switch (action) {
        case _Action.promote:
          onPromote(_currentLine());
        case _Action.checklist:
          controller.applyEditingValue(asNoteChecklist(controller.value));
        case _Action.bold:
          controller.execute(MarkdownCommand.bold);
        case _Action.indent:
        case _Action.outdent:
          final edit = editNoteList(controller.value,
              action == _Action.indent ? NoteListAction.indent : NoteListAction.outdent);
          if (edit != null) controller.applyEditingValue(edit);
        case _Action.undo:
          controller.undo();
        case _Action.redo:
          controller.redo();
      }
    },
  );

  int _currentLine() =>
      '\n'.allMatches(controller.text.substring(0, controller.selection.end)).length;
}
