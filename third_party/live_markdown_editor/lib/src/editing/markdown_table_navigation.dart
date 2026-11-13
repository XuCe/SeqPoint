import 'dart:math' as math;

import '../parser/markdown_node.dart';

/// Pure table-navigation helpers used by the editor's Tab handling.
final class MarkdownTableNavigation {
  const MarkdownTableNavigation();

  /// Source offset of the next cell's content start; null when [offset] is
  /// in the last cell of the last row (callers append a row).
  static int? nextCell(MarkdownTableData data, int offset) {
    final location = cellAt(data, offset);
    if (location == null) return null;
    final (rowIndex, cellIndex) = location;
    final row = data.rows[rowIndex];
    if (cellIndex + 1 < row.cells.length) {
      return row.cells[cellIndex + 1].contentRange.start;
    }
    if (rowIndex + 1 < data.rows.length) {
      final next = data.rows[rowIndex + 1];
      return next.cells.isEmpty ? null : next.cells.first.contentRange.start;
    }
    return null;
  }

  /// Source offset of the previous cell's content start; null when [offset]
  /// is in the first cell of the first row.
  static int? previousCell(MarkdownTableData data, int offset) {
    final location = cellAt(data, offset);
    if (location == null) return null;
    final (rowIndex, cellIndex) = location;
    final row = data.rows[rowIndex];
    if (cellIndex > 0) {
      return row.cells[cellIndex - 1].contentRange.start;
    }
    if (rowIndex > 0) {
      final previous = data.rows[rowIndex - 1];
      return previous.cells.isEmpty
          ? null
          : previous.cells.last.contentRange.start;
    }
    return null;
  }

  /// Locates the (row, cell) containing [offset]; null outside the table's
  /// content rows. Offsets between cells snap forward.
  static (int, int)? cellAt(MarkdownTableData data, int offset) {
    for (var r = 0; r < data.rows.length; r++) {
      final row = data.rows[r];
      if (!row.rowRange.contains(offset)) continue;
      for (var c = 0; c < row.cells.length; c++) {
        if (row.cells[c].contentRange.contains(offset)) return (r, c);
      }
      for (var c = 0; c < row.cells.length; c++) {
        if (offset < row.cells[c].contentRange.start) return (r, c);
      }
      return (r, row.cells.length - 1);
    }
    return null;
  }

  /// Appends an empty row after the last row, mirroring its pipe style.
  static ({String text, int caret}) appendRowText(
    MarkdownTableData data,
    String source,
  ) {
    final last = data.rows.last;
    final rowText = last.rowRange.slice(source);
    final rowEndsWithNewline = rowText.endsWith('\n');
    final content = rowEndsWithNewline
        ? rowText.substring(0, rowText.length - 1)
        : rowText;
    final leading = content.startsWith('|');
    final trailing = content.trimRight().endsWith('|');
    final newRow =
        (leading ? '|' : '') +
        ' |' * (data.columns - 1) +
        (trailing ? ' |' : '');
    // When the header is the only content row, append after the separator.
    final insertAt = math.max(last.rowRange.end, data.separatorRange.end);
    final hasNewline = source.codeUnitAt(insertAt - 1) == 0x0A;
    final text =
        '${source.substring(0, insertAt)}'
        '${hasNewline ? '' : '\n'}$newRow\n'
        '${source.substring(insertAt)}';
    return (
      text: text,
      caret: insertAt + (hasNewline ? 0 : 1) + (leading ? 2 : 0),
    );
  }
}
