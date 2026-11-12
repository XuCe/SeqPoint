import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';

import '../theme/seq_tokens.dart';
import 'note_shortcuts.dart';
import 'note_list_edit.dart';
import 'note_reminder.dart';
import 'note_reminder_dialog.dart';
import 'note_slash_actions.dart';

class NoteMarkdownField extends StatefulWidget {
  const NoteMarkdownField({super.key, required this.controller, this.onSaveItem});
  final MarkdownEditorController controller;
  final void Function(String text, int index, DateTime? due)? onSaveItem;

  @override
  State<NoteMarkdownField> createState() => _NoteMarkdownFieldState();
}

class _NoteMarkdownFieldState extends State<NoteMarkdownField> {
  final _focus = FocusNode();
  late TextEditingValue _previous;
  @override
  void initState() {
    super.initState();
    _previous = widget.controller.value;
    widget.controller.addListener(_onEdit);
    FocusManager.instance.addEarlyKeyEventHandler(_listKey);
    _focus.requestFocus();
  }

  void _onEdit() {
    final editor = widget.controller;
    final before = _previous;
    _previous = editor.value;
    final result = noteShortcut(before, _previous);
    if (result == null) return;
    final offset = _previous.selection.end - 1;
    if (_inCode(offset)) return;
    editor.applyEditingValue(result);
  }

  bool _inCode(int offset) => widget.controller.document.semanticBlocks.any(
    (block) =>
        block.range.contains(offset) &&
        (block.type == MarkdownBlockType.fencedCode ||
            block.type == MarkdownBlockType.indentedCode),
  );

  KeyEventResult _listKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (!_focus.hasPrimaryFocus ||
        event is! KeyDownEvent ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final action = key == LogicalKeyboardKey.tab
        ? (keyboard.isShiftPressed ? NoteListAction.outdent : NoteListAction.indent)
        : key == LogicalKeyboardKey.enter && keyboard.isShiftPressed
        ? NoteListAction.lineBreak
        : null;
    if (action == null) return KeyEventResult.ignored;
    final value = widget.controller.value;
    if (_inCode(value.selection.end - 1)) return KeyEventResult.ignored;
    final result = editNoteList(value, action);
    if (result == null) return KeyEventResult.ignored;
    widget.controller.applyEditingValue(result);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onEdit);
    FocusManager.instance.removeEarlyKeyEventHandler(_listKey);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: CallbackShortcuts(
          bindings: {
            for (final activator in const [
              SingleActivator(LogicalKeyboardKey.keyB, control: true),
              SingleActivator(LogicalKeyboardKey.keyB, meta: true),
            ])
              activator: () {
                if (widget.controller.value.composing.isCollapsed) {
                  widget.controller.execute(MarkdownCommand.bold);
                }
              },
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              LiveMarkdownEditor(
                controller: widget.controller,
                focusNode: _focus,
                theme: MarkdownEditorThemeData.light().copyWith(
                  contentPadding: EdgeInsets.zero,
                  maxContentWidth: double.infinity,
                  backgroundColor: Colors.transparent,
                  textColor: SeqTokens.noteInk,
                  caretColor: SeqTokens.noteInk,
                  bodyStyle: const TextStyle(color: SeqTokens.noteInk, fontSize: 16, height: 1.6),
                ),
              ),
              IgnorePointer(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (_, value, _) => value.text.isEmpty
                      ? const Text(
                          '想到什么就写什么，一行一件事',
                          style: TextStyle(color: Color(0xFF796837), fontSize: 16, height: 1.6),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
      if (widget.onSaveItem != null)
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            final line = noteLineAtCaret(value);
            if (line == null || _inCode(line.start)) return const SizedBox.shrink();
            final now = DateTime.now();
            final draft = NoteReminder.fromLine(line, now);
            final actions = noteSlashActions(line, widget.controller, now, widget.onSaveItem!);
            if (draft != null) {
              final date = draft.due
                  .toLocal()
                  .toIso8601String()
                  .replaceFirst('T', ' ')
                  .substring(0, 16);
              actions.insert(
                0,
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  icon: const Icon(Icons.alarm_add, size: 17),
                  label: Text(draft.command ? '设提醒…' : '设提醒 · $date'),
                  onPressed: () async {
                    final result = await showNoteReminder(context, draft);
                    if (!mounted || result == null || widget.controller.text != value.text) return;
                    widget.onSaveItem?.call(
                      draft.contentWithTitle(value.text, result.title),
                      draft.index,
                      result.due,
                    );
                  },
                ),
              );
            }
            if (actions.isEmpty) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: actions),
              ),
            );
          },
        ),
    ],
  );
}
