import '../model/source_range.dart';

/// Splits Markdown source into physical lines without normalizing its text.
///
/// All ranges use UTF-16 offsets so they can be used directly with Flutter's
/// [TextEditingValue] selection coordinates. A line's [MarkdownSourceLine.range]
/// includes its original line ending; its content ranges do not.
final class MarkdownSourceScanner {
  MarkdownSourceScanner(this.source);

  final String source;

  late final List<MarkdownSourceLine> lines = List.unmodifiable(_scan());

  List<MarkdownSourceLine> _scan() {
    final result = <MarkdownSourceLine>[];
    var start = 0;
    while (start < source.length) {
      var contentEnd = start;
      while (contentEnd < source.length) {
        final codeUnit = source.codeUnitAt(contentEnd);
        if (codeUnit == 0x0A || codeUnit == 0x0D) break;
        contentEnd++;
      }

      var end = contentEnd;
      if (end < source.length) {
        if (source.codeUnitAt(end) == 0x0D &&
            end + 1 < source.length &&
            source.codeUnitAt(end + 1) == 0x0A) {
          end += 2;
        } else {
          end++;
        }
      }

      var contentStart = start;
      var column = 0;
      while (contentStart < contentEnd) {
        final codeUnit = source.codeUnitAt(contentStart);
        if (codeUnit == 0x20) {
          column++;
        } else if (codeUnit == 0x09) {
          column += 4 - (column % 4);
        } else {
          break;
        }
        contentStart++;
      }

      result.add(
        MarkdownSourceLine(
          range: SourceRange(start, end),
          rawContentRange: SourceRange(start, contentEnd),
          contentRange: SourceRange(contentStart, contentEnd),
          columnAfterIndent: column,
        ),
      );
      start = end;
    }
    return result;
  }
}

/// A physical source line with both raw and indentation-trimmed content ranges.
final class MarkdownSourceLine {
  const MarkdownSourceLine({
    required this.range,
    required this.rawContentRange,
    required this.contentRange,
    required this.columnAfterIndent,
  });

  /// The entire line, including its original CR, LF, or CRLF terminator.
  final SourceRange range;

  /// The line excluding its terminator, but retaining its indentation.
  final SourceRange rawContentRange;

  /// The line content after leading spaces and tabs, excluding its terminator.
  final SourceRange contentRange;

  /// The display column occupied by the leading indentation, using tab stops
  /// every four columns.
  final int columnAfterIndent;

  int get start => range.start;
  int get contentEnd => rawContentRange.end;
  int get end => range.end;

  /// Returns this line without its terminator while preserving indentation.
  String textFor(String source) => rawContentRange.slice(source);
}
