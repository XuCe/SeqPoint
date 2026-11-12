import 'package:flutter/services.dart';

enum NoteListAction { indent, outdent, lineBreak }

final _marker = RegExp(r'^( *)(?:[-+*]|\d+[.)]) +');

TextEditingValue? editNoteList(TextEditingValue value, NoteListAction action) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed || !value.composing.isCollapsed) return null;
  final caret = selection.end;
  final before = value.text.substring(0, caret).split('\n');
  final line = before.last;
  final marker = _marker.firstMatch(line);
  if (marker == null) return null;
  final start = caret - line.length;
  final indent = marker[1]!.length;
  if (action == NoteListAction.lineBreak) {
    final continuation = '  \n${' ' * marker.end}';
    return TextEditingValue(
      text: value.text.replaceRange(caret, caret, continuation),
      selection: TextSelection.collapsed(offset: caret + continuation.length),
    );
  }
  var spaces = 0;
  for (var i = before.length - 2; i >= 0; i--) {
    final previous = _marker.firstMatch(before[i]);
    if (previous == null) break;
    final depth = previous[1]!.length;
    if (action == NoteListAction.indent) {
      if (depth >= indent) spaces = depth == indent ? previous.end : depth;
      break;
    }
    if (depth < indent) {
      spaces = depth;
      break;
    }
  }
  if ((action == NoteListAction.indent && spaces <= indent) || spaces == indent) return null;
  return TextEditingValue(
    text: value.text.replaceRange(start, start + indent, ' ' * spaces),
    selection: TextSelection.collapsed(offset: caret + spaces - indent),
  );
}
