import 'package:flutter/services.dart';

TextEditingValue asNoteChecklist(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) return value;
  final text = value.text;
  final start = text.substring(0, selection.start).lastIndexOf('\n') + 1;
  final newline = text.indexOf('\n', selection.end - 1);
  final end = newline < 0 ? text.length : newline;
  final marker = RegExp(r'^([ \t]*)(?:[-*+] |\d+[.)] )?');
  final replacement = text
      .substring(start, end)
      .split('\n')
      .map((line) {
        if (line.trim().isEmpty || RegExp(r'^\s*(?:[-*+]|\d+[.)]) \[[xX ]\] ').hasMatch(line)) {
          return line;
        }
        return line.replaceFirstMapped(marker, (m) => '${m[1]}- [ ] ');
      })
      .join('\n');
  final extent = start + replacement.length;
  final forward = selection.baseOffset < selection.extentOffset;
  return TextEditingValue(
    text: text.replaceRange(start, end, replacement),
    selection: TextSelection(
      baseOffset: forward ? start : extent,
      extentOffset: forward ? extent : start,
    ),
  );
}

/// Expand a line prefix only for typing or an IME commit at the caret.
TextEditingValue? noteShortcut(TextEditingValue before, TextEditingValue after) {
  if (!after.composing.isCollapsed || !after.selection.isValid || !after.selection.isCollapsed) {
    return null;
  }
  final composing = before.isComposingRangeValid && !before.composing.isCollapsed;
  if (!composing && before.text == after.text) return null;
  final range = composing ? before.composing : before.selection;
  if (!range.isValid) return null;
  final caret = after.selection.end;
  final start = range.start;
  if (caret <= start || (!composing && range.isCollapsed && caret != start + 1)) return null;
  if (before.text.substring(0, start) != after.text.substring(0, start) ||
      before.text.substring(range.end) != after.text.substring(caret)) {
    return null;
  }

  final typed = after.text.substring(start, caret);
  if (!composing && !range.isCollapsed) {
    final uri = Uri.tryParse(typed);
    final label = before.text.substring(start, range.end);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'[\s<>]').hasMatch(typed) ||
        label.contains('\n')) {
      return null;
    }
    final escaped = label.replaceAllMapped(RegExp(r'[\\\[\]]'), (m) => '\\${m[0]}');
    final url = typed.replaceAll('(', '%28').replaceAll(')', '%29');
    final link = '[$escaped]($url)';
    return TextEditingValue(
      text: after.text.replaceRange(start, caret, link),
      selection: TextSelection.collapsed(offset: start + link.length),
    );
  }
  final lineStart = start == 0 ? 0 : after.text.lastIndexOf('\n', start - 1) + 1;
  final prefix = after.text.substring(lineStart, start);
  String replacement;
  if (typed == '\n' &&
      RegExp(r'^ {0,3}\d{1,9}\.$').hasMatch(prefix) &&
      (start == before.text.length || before.text[start] == '\n')) {
    replacement = '';
  } else if (RegExp(r'^ {0,3}\d{1,9}\.$').hasMatch(prefix) &&
      RegExp(r'^\p{L}', unicode: true).hasMatch(typed)) {
    replacement = '$prefix $typed';
  } else if (RegExp(r'^ {0,3}\d{1,9}$').hasMatch(prefix) && typed == '、') {
    replacement = '$prefix. ';
  } else if (prefix == '[]' && typed == ' ') {
    replacement = '- [ ] ';
  } else {
    return null;
  }
  return TextEditingValue(
    text: after.text.replaceRange(lineStart, caret, replacement),
    selection: TextSelection.collapsed(offset: lineStart + replacement.length),
  );
}
