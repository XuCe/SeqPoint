import 'package:flutter/services.dart';
import 'package:seqpoint_core/seqpoint_core.dart';

typedef EditorLine = ({String text, int index, int start, int end});

EditorLine? noteLineAtCaret(TextEditingValue value) {
  if (!value.composing.isCollapsed || !value.selection.isValid || !value.selection.isCollapsed) {
    return null;
  }
  final caret = value.selection.end;
  final before = value.text.substring(0, caret);
  final start = before.lastIndexOf('\n') + 1;
  final newline = value.text.indexOf('\n', caret);
  final end = newline < 0 ? value.text.length : newline;
  return (
    text: value.text.substring(start, end),
    index: '\n'.allMatches(before).length,
    start: start,
    end: end,
  );
}

class NoteReminder {
  const NoteReminder(this.index, this.start, this.end, this.title, this.due, this.command);
  final int index;
  final int start;
  final int end;
  final String title;
  final DateTime due;
  final bool command;

  static final _command = RegExp(r'^/(?:提|提醒(?:\s+(.*))?)?$');
  static NoteReminder? fromLine(EditorLine current, DateTime now) {
    final line = current.text.trim();
    final match = _command.firstMatch(line);
    if (line.startsWith('/') && match == null) return null;
    final title = match == null ? Note.lineTitle(line) : (match[1] ?? '').trim();
    final parsed = const TimeParser().parse(title, now);
    if (match == null && parsed == null) return null;
    final defaultTime = DateTime(now.year, now.month, now.day, now.hour + 1);
    return NoteReminder(
      current.index,
      current.start,
      current.end,
      title,
      parsed?.dateTime ?? defaultTime,
      match != null,
    );
  }

  String contentWithTitle(String text, String title) =>
      command ? text.replaceRange(start, end, title.trim()) : text;
}
