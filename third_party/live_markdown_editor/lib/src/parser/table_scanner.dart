import '../model/source_range.dart';
import 'markdown_node.dart';

/// Splits table rows into cells using GFM rules.
///
/// A pipe splits cells unless it is escaped (`\|`) or sits inside a backtick
/// code span (a run of N backticks opens a span, a run of N closes it).
/// Cell ranges are trimmed of surrounding spaces/tabs.
final class MarkdownTableScanner {
  const MarkdownTableScanner();

  static ({List<SourceRange> cells, bool hasPipe}) scanRow(
    String source,
    int start,
    int end,
  ) {
    final cells = <SourceRange>[];
    var cellStart = start;
    var hasPipe = false;
    var escaped = false;
    var inCode = false;
    var tickRun = 0;
    var index = start;
    while (index < end) {
      final c = source.codeUnitAt(index);
      if (c == 0x5C) {
        escaped = !escaped;
        index++;
        continue;
      }
      if (c == 0x60) {
        var runEnd = index + 1;
        while (runEnd < end && source.codeUnitAt(runEnd) == 0x60) {
          runEnd++;
        }
        final run = runEnd - index;
        if (!inCode) {
          inCode = true;
          tickRun = run;
        } else if (run == tickRun) {
          inCode = false;
        }
        index = runEnd;
        escaped = false;
        continue;
      }
      if (c == 0x7C && !escaped && !inCode) {
        hasPipe = true;
        cells.add(_trimmedRange(source, cellStart, index));
        cellStart = index + 1;
      }
      escaped = false;
      index++;
    }
    cells.add(_trimmedRange(source, cellStart, end));
    return (cells: _contentCells(cells), hasPipe: hasPipe);
  }

  /// Positions of cell-splitting pipes in [text].
  static List<int> pipePositions(String text) {
    final result = <int>[];
    var escaped = false;
    var inCode = false;
    var tickRun = 0;
    var index = 0;
    while (index < text.length) {
      final c = text.codeUnitAt(index);
      if (c == 0x5C) {
        escaped = !escaped;
        index++;
        continue;
      }
      if (c == 0x60) {
        var runEnd = index + 1;
        while (runEnd < text.length && text.codeUnitAt(runEnd) == 0x60) {
          runEnd++;
        }
        final run = runEnd - index;
        if (!inCode) {
          inCode = true;
          tickRun = run;
        } else if (run == tickRun) {
          inCode = false;
        }
        index = runEnd;
        escaped = false;
        continue;
      }
      if (c == 0x7C && !escaped && !inCode) result.add(index);
      escaped = false;
      index++;
    }
    return result;
  }

  /// Whether [start, end) is a table separator row: every content cell
  /// (slicing on unescaped pipes, dropping empty leading/trailing fields)
  /// matches `:?-+:?`.
  static bool isSeparatorRow(String source, int start, int end) {
    final scanned = scanRow(source, start, end);
    final cells = _contentCells(scanned.cells);
    if (cells.isEmpty) return false;
    for (final cell in cells) {
      if (!_separatorCell.hasMatch(cell.slice(source).trim())) return false;
    }
    return true;
  }

  static final RegExp _separatorCell = RegExp(r'^:?-+:?$');

  static MarkdownTableAlignment alignmentForCell(
    SourceRange cell,
    String source,
  ) {
    final text = cell.slice(source).trim();
    final leading = text.startsWith(':');
    final trailing = text.endsWith(':');
    if (leading && trailing) return MarkdownTableAlignment.center;
    if (trailing) return MarkdownTableAlignment.end;
    return MarkdownTableAlignment.start;
  }

  /// Drops empty leading/trailing fields so `| --- |` yields one cell.
  static List<SourceRange> _contentCells(List<SourceRange> fields) {
    var first = 0;
    var last = fields.length;
    while (first < last && fields[first].length == 0) {
      first++;
    }
    while (last > first && fields[last - 1].length == 0) {
      last--;
    }
    return fields.sublist(first, last);
  }

  static SourceRange _trimmedRange(String source, int start, int end) {
    while (start < end &&
        (source.codeUnitAt(start) == 0x20 ||
            source.codeUnitAt(start) == 0x09)) {
      start++;
    }
    while (end > start &&
        (source.codeUnitAt(end - 1) == 0x20 ||
            source.codeUnitAt(end - 1) == 0x09)) {
      end--;
    }
    return SourceRange(start, end);
  }
}
