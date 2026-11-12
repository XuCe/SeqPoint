import 'package:flutter/material.dart';
import 'package:live_markdown_editor/live_markdown_editor.dart';

import 'note_reminder.dart';

List<Widget> noteSlashActions(
  EditorLine line,
  MarkdownEditorController editor,
  DateTime now,
  void Function(String, int, DateTime?) saveItem,
) {
  final match = RegExp(r'^/(\S*)(?:\s+(.*))?$').firstMatch(line.text.trimLeft());
  if (match == null) return [];
  final query = match[1]!;
  final argument = (match[2] ?? '').trim();
  final actions = <Widget>[];
  for (final command in ['待办', '今天日期', '引用']) {
    if (!command.startsWith(query)) continue;
    final save = command == '待办' && argument.isNotEmpty;
    actions.add(
      TextButton(
        child: Text(save ? '保存为待办' : command),
        onPressed: () {
          final replacement = switch (command) {
            '待办' => save ? argument : '/待办 ',
            '引用' => '> $argument',
            _ => '${now.toIso8601String().substring(0, 10)} $argument',
          };
          final text = editor.text.replaceRange(line.start, line.end, replacement);
          if (save) {
            saveItem(text, line.index, null);
          } else {
            editor.applyEditingValue(
              TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: line.start + replacement.length),
              ),
            );
          }
        },
      ),
    );
  }
  return actions;
}
