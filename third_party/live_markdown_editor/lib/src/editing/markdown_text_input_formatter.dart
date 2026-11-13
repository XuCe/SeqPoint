import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../extensions/markdown_extension_error.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../parser/block_parser.dart';
import '../parser/markdown_node.dart';
import '../parser/table_scanner.dart';
import 'markdown_editing_behavior.dart';

final class MarkdownTextInputFormatter extends TextInputFormatter {
  const MarkdownTextInputFormatter({
    this.behavior = const MarkdownEditingBehavior(),
    this.extensionRules = const [],
    this.extensionErrorListener,
  });

  static const Map<String, String> _pairs = {
    '*': '*',
    '_': '_',
    '~': '~',
    '=': '=',
    '`': '`',
    '[': ']',
    '(': ')',
  };

  final MarkdownEditingBehavior behavior;

  /// Validated extension editing rules, already in dependency/registration
  /// order; run after core typing behavior.
  final List<({MarkdownEditingRule rule, String extensionId})> extensionRules;

  /// Host callback for guarded extension rule failures.
  final MarkdownExtensionErrorListener? extensionErrorListener;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed) return newValue;
    if (behavior.smartLists) {
      final backspaceResult = _emptyPrefixBackspace(oldValue, newValue);
      if (backspaceResult != null) return backspaceResult;
    }
    final inserted = _singleInserted(oldValue, newValue);
    if (inserted == '\n') {
      final tableEnter = _tableEnter(oldValue);
      if (tableEnter != null) return tableEnter;
      if (behavior.smartLists) return _continueBlock(oldValue, newValue);
    }

    if (inserted == null) {
      final guarded = _guardTableEdit(oldValue, newValue);
      if (guarded != null) return guarded;
      return newValue;
    } else if (oldValue.text.contains('|') &&
        _separatorTypingBlocked(oldValue)) {
      return oldValue;
    }

    if (inserted == '`' && behavior.autoCloseFences) {
      final caret = oldValue.selection.end;
      final lineStart =
          oldValue.text.lastIndexOf('\n', math.max(0, caret - 1)) + 1;
      if (oldValue.text.substring(lineStart, caret) == '``') {
        return TextEditingValue(
          text: oldValue.text.replaceRange(caret, caret, '`\n\n```'),
          selection: TextSelection.collapsed(offset: caret + 2),
        );
      }
    }

    final closing = _pairs[inserted];
    final oldSelection = oldValue.selection;
    if (!oldSelection.isValid) return newValue;

    if (oldSelection.isCollapsed &&
        oldSelection.end < oldValue.text.length &&
        oldValue.text[oldSelection.end] == inserted &&
        _pairs.containsValue(inserted)) {
      return _applyExtensionRules(
        oldValue.copyWith(
          selection: TextSelection.collapsed(offset: oldSelection.end + 1),
        ),
      );
    }

    if (closing == null) return _applyExtensionRules(newValue);

    if (!oldSelection.isCollapsed && behavior.wrapSelection) {
      final start = oldSelection.start;
      final end = oldSelection.end;
      final selected = oldValue.text.substring(start, end);
      final text = oldValue.text.replaceRange(
        start,
        end,
        '$inserted$selected$closing',
      );
      return TextEditingValue(
        text: text,
        selection: TextSelection(baseOffset: start + 1, extentOffset: end + 1),
      );
    }

    if (oldSelection.isCollapsed && behavior.autoPair) {
      final offset = oldSelection.end;
      final text = oldValue.text.replaceRange(
        offset,
        offset,
        '$inserted$closing',
      );
      return _applyExtensionRules(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: offset + inserted.length),
        ),
      );
    }
    return _applyExtensionRules(newValue);
  }

  /// Runs validated extension rules in order and applies the final value
  /// once. A throwing rule reports through [extensionErrorListener] and keeps
  /// the proposed value; an invalid result (out-of-range selection or
  /// composing) is rejected the same way.
  TextEditingValue _applyExtensionRules(TextEditingValue proposed) {
    if (extensionRules.isEmpty) return proposed;
    var value = proposed;
    for (final entry in extensionRules) {
      final rule = entry.rule;
      TextEditingValue? result;
      try {
        result = rule.apply(value);
      } catch (error) {
        extensionErrorListener?.call(
          MarkdownExtensionError(
            extensionId: entry.extensionId,
            phase: MarkdownExtensionPhase.editing,
            error: error,
          ),
        );
        continue;
      }
      if (result == null) continue;
      if (!_validResult(result, value)) {
        extensionErrorListener?.call(
          MarkdownExtensionError(
            extensionId: entry.extensionId,
            phase: MarkdownExtensionPhase.editing,
            error:
                'invalid editing result: ${result.selection} '
                'outside ${result.text.length}',
          ),
        );
        continue;
      }
      value = result;
    }
    return value;
  }

  static bool _validResult(TextEditingValue result, TextEditingValue base) {
    final selection = result.selection;
    if (selection.isValid &&
        (selection.start < 0 || selection.end > result.text.length)) {
      return false;
    }
    final composing = result.composing;
    return !composing.isValid ||
        (composing.start >= 0 &&
            composing.end <= result.text.length &&
            composing.start <= composing.end);
  }

  TextEditingValue indent(TextEditingValue value) =>
      _changeIndent(value, unindent: false);

  TextEditingValue unindent(TextEditingValue value) =>
      _changeIndent(value, unindent: true);

  String? _singleInserted(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selection = oldValue.selection;
    if (!selection.isValid) return null;
    final replacedLength = selection.end - selection.start;
    if (newValue.text.length != oldValue.text.length - replacedLength + 1) {
      return null;
    }
    final prefix = oldValue.text.substring(0, selection.start);
    final suffix = oldValue.text.substring(selection.end);
    if (!newValue.text.startsWith(prefix) || !newValue.text.endsWith(suffix)) {
      return null;
    }
    return newValue.text.substring(selection.start, selection.start + 1);
  }

  TextEditingValue? _emptyPrefixBackspace(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selection = oldValue.selection;
    if (!selection.isValid || !selection.isCollapsed || selection.end == 0) {
      return null;
    }
    if (newValue.text.length != oldValue.text.length - 1 ||
        newValue.selection.end != selection.end - 1) {
      return null;
    }
    final caret = selection.end;
    final lineStart =
        oldValue.text.lastIndexOf('\n', math.max(0, caret - 1)) + 1;
    final lineEndCandidate = oldValue.text.indexOf('\n', caret);
    final lineEnd = lineEndCandidate < 0
        ? oldValue.text.length
        : lineEndCandidate;
    if (caret != lineEnd) return null;
    final line = oldValue.text.substring(lineStart, caret);
    final emptyPrefix = RegExp(
      r'^(?:\s*[-+*]\s+(?:\[[ xX]\]\s*)?|'
      r'\s*\d+[.)]\s+(?:\[[ xX]\]\s*)?|'
      r'\s*>\s?)$',
    );
    if (!emptyPrefix.hasMatch(line)) return null;
    final text = oldValue.text.replaceRange(lineStart, caret, '');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: lineStart),
    );
  }

  TextEditingValue _continueBlock(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final caret = oldValue.selection.end;
    final lineStart =
        oldValue.text.lastIndexOf('\n', math.max(0, caret - 1)) + 1;
    final beforeCaret = oldValue.text.substring(lineStart, caret);

    final task = RegExp(r'^(\s*[-+*]\s+\[[ xX]\]\s*)(.*)$')
        .firstMatch(beforeCaret);
    final unordered = RegExp(r'^(\s*[-+*]\s+)(.*)$').firstMatch(beforeCaret);
    final ordered = RegExp(r'^(\s*)(\d+)([.)]\s+)(.*)$')
        .firstMatch(beforeCaret);
    final quote = RegExp(r'^(\s*>\s?)(.*)$').firstMatch(beforeCaret);
    final orderedTask = RegExp(r'^(\s*)(\d+)([.)]\s+\[[ xX]\]\s*)(.*)$')
        .firstMatch(beforeCaret);

    final content =
        orderedTask?.group(4) ??
        task?.group(2) ??
        unordered?.group(2) ??
        ordered?.group(4) ??
        quote?.group(2);
    if (content != null && content.isEmpty) {
      final text = oldValue.text.replaceRange(lineStart, caret, '');
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: lineStart),
      );
    }

    String? prefix;
    if (orderedTask != null) {
      prefix =
          '${orderedTask.group(1)}'
          '${int.parse(orderedTask.group(2)!) + 1}'
          '${orderedTask.group(3)!.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]')}';
    } else if (task != null) {
      prefix = task.group(1)!.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
    } else if (unordered != null) {
      prefix = unordered.group(1);
    } else if (ordered != null) {
      prefix =
          '${ordered.group(1)}${int.parse(ordered.group(2)!) + 1}${ordered.group(3)}';
    } else if (quote != null) {
      prefix = quote.group(1);
    }
    if (prefix == null) return newValue;

    final text = oldValue.text.replaceRange(caret, caret, '\n$prefix');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret + 1 + prefix.length),
    );
  }

  TextEditingValue _changeIndent(
    TextEditingValue value, {
    required bool unindent,
  }) {
    final selection = value.selection;
    if (!selection.isValid) return value;
    final lineStart =
        value.text.lastIndexOf('\n', math.max(0, selection.start - 1)) + 1;
    final nextNewline = value.text.indexOf('\n', selection.end);
    final lineEnd = nextNewline < 0 ? value.text.length : nextNewline;
    final lines = value.text.substring(lineStart, lineEnd).split('\n');
    final indent = ' ' * behavior.indentWidth;
    final changed = [
      for (final line in lines)
        if (unindent)
          line.replaceFirst(RegExp('^ {1,${behavior.indentWidth}}'), '')
        else
          '$indent$line',
    ].join('\n');
    final text = value.text.replaceRange(lineStart, lineEnd, changed);
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + changed.length,
      ),
    );
  }

  // ---- Table editing (Obsidian-compatible) -------------------------------

  /// Enter inside a table cell: split the row at the caret's column and
  /// insert a new row. Returns null when the caret is not in a table cell.
  TextEditingValue? _tableEnter(TextEditingValue oldValue) {
    final selection = oldValue.selection;
    if (!selection.isValid || !selection.isCollapsed) return null;
    final caret = selection.extentOffset;
    if (caret < 0 || !oldValue.text.contains('|')) return null;
    final document = const MarkdownBlockParser().parse(oldValue.text);
    for (final block in document.blocks) {
      if (block.type != MarkdownBlockType.table) continue;
      final data = block.tableData!;
      if (!block.range.contains(caret)) continue;
      if (data.separatorRange.contains(caret)) return oldValue;
      for (final row in data.rows) {
        if (!row.rowRange.contains(caret)) continue;
        return _splitRow(oldValue, row, caret);
      }
      return null;
    }
    return null;
  }

  TextEditingValue _splitRow(
    TextEditingValue oldValue,
    MarkdownTableRow row,
    int caret,
  ) {
    final text = oldValue.text;
    final rowEnd = row.rowRange.end;
    final rowText = text.substring(row.rowRange.start, rowEnd);
    final content = rowText.endsWith('\n')
        ? rowText.substring(0, rowText.length - 1)
        : rowText;
    final caretInRow = (caret - row.rowRange.start).clamp(0, content.length);
    final pipes = MarkdownTableScanner.pipePositions(content);
    var effective = pipes;
    if (pipes.isNotEmpty && content.substring(pipes.last + 1).trim().isEmpty) {
      effective = pipes.sublist(0, pipes.length - 1);
    }
    var count = 0;
    for (final pipe in effective) {
      if (pipe <= caretInRow) count++;
    }
    final leading = content.startsWith('|');
    final cellIndex = math.max(0, count - (leading ? 1 : 0));
    final suffix = content.substring(caretInRow);
    final newRow = '${leading ? '|' : ''}${' |' * cellIndex} $suffix';
    final caretInNewRow = (leading ? 2 : 0) + 2 * cellIndex;
    final newText =
        '${text.substring(0, caret)}\n$newRow\n'
        '${text.substring(rowEnd)}';
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: caret + 1 + caretInNewRow),
    );
  }

  /// Rewrites a deletion/replacement inside one table block so structural
  /// characters (pipes, row newlines, separator hyphens, and the spaces
  /// adjacent to them) survive. Returns null when the edit is not inside a
  /// single table block, or is a pure insertion.
  TextEditingValue? _guardTableEdit(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!oldValue.text.contains('|')) return null;
    final oldText = oldValue.text;
    final newText = newValue.text;
    var prefix = 0;
    final shared = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    while (prefix < shared && oldText[prefix] == newText[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shared - prefix &&
        oldText[oldText.length - 1 - suffix] ==
            newText[newText.length - 1 - suffix]) {
      suffix++;
    }
    final deletedEnd = oldText.length - suffix;
    if (prefix >= deletedEnd) return null; // Pure insertion.
    final table = _tableForRange(oldText, prefix, deletedEnd);
    if (table == null) return null;
    final data = table.tableData!;
    final kept = StringBuffer();
    for (var index = prefix; index < deletedEnd; index++) {
      if (_isTableStructural(oldText, index, data)) {
        kept.writeCharCode(oldText.codeUnitAt(index));
      }
    }
    final inserted = newText.substring(prefix, newText.length - suffix);
    final result =
        '${oldText.substring(0, prefix)}$kept$inserted'
        '${oldText.substring(deletedEnd)}';
    if (result == oldText) return oldValue;
    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(
        offset: prefix + kept.length + inserted.length,
      ),
    );
  }

  MarkdownBlockNode? _tableForRange(String text, int start, int end) {
    final document = const MarkdownBlockParser().parse(text);
    for (final block in document.blocks) {
      if (block.type != MarkdownBlockType.table) continue;
      if (start >= block.range.start && end <= block.range.end) return block;
    }
    return null;
  }

  bool _isTableStructural(String source, int index, MarkdownTableData data) {
    final c = source.codeUnitAt(index);
    if (c == 0x7C) return true; // Pipe.
    if (c == 0x0A) return true; // Row boundary.
    if (c == 0x2D && data.separatorRange.contains(index)) return true;
    if (c == 0x20) {
      final previous = index > 0 ? source.codeUnitAt(index - 1) : 0;
      final next = index + 1 < source.length ? source.codeUnitAt(index + 1) : 0;
      if (previous == 0x7C || next == 0x7C) return true;
      if (data.separatorRange.contains(index) &&
          (previous == 0x2D || next == 0x2D)) {
        return true;
      }
    }
    return false;
  }

  /// Typing in the separator row is a no-op: its content is structure.
  bool _separatorTypingBlocked(TextEditingValue oldValue) {
    final selection = oldValue.selection;
    if (!selection.isValid || !oldValue.text.contains('|')) return false;
    final document = const MarkdownBlockParser().parse(oldValue.text);
    for (final block in document.blocks) {
      if (block.type != MarkdownBlockType.table) continue;
      final data = block.tableData!;
      if (data.separatorRange.contains(selection.extentOffset)) return true;
    }
    return false;
  }
}
