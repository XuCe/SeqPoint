import '../extensions/markdown_parse_context.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../model/source_range.dart';
import 'markdown_node.dart';
import 'table_scanner.dart';

/// Built-in GFM table grammar installed by the editor-default profile.
final class MarkdownBuiltinTableExtension extends MarkdownSyntaxExtension {
  const MarkdownBuiltinTableExtension();

  @override
  final String id = 'live_markdown_editor.table';

  @override
  final int apiVersion = MarkdownSyntaxExtension.apiVersion1;

  @override
  final List<String> dependencies = const [];

  @override
  final List<MarkdownSyntaxRule> rules = const [MarkdownBuiltinTableRule()];
}

/// Built-in task-list decoration installed by the editor-default profile.
final class MarkdownBuiltinTaskListExtension extends MarkdownSyntaxExtension {
  const MarkdownBuiltinTaskListExtension();

  @override
  final String id = 'live_markdown_editor.taskList';

  @override
  final int apiVersion = MarkdownSyntaxExtension.apiVersion1;

  @override
  final List<String> dependencies = const [];

  @override
  final List<MarkdownSyntaxRule> rules = const [MarkdownBuiltinTaskListRule()];
}

/// Built-in strikethrough delimiters installed by the editor-default profile.
final class MarkdownBuiltinStrikethroughExtension
    extends MarkdownSyntaxExtension {
  const MarkdownBuiltinStrikethroughExtension();

  @override
  final String id = 'live_markdown_editor.strikethrough';

  @override
  final int apiVersion = MarkdownSyntaxExtension.apiVersion1;

  @override
  final List<String> dependencies = const [];

  @override
  final List<MarkdownSyntaxRule> rules = const [
    MarkdownBuiltinStrikethroughRule(),
  ];
}

/// Built-in highlight delimiters installed by the editor-default profile.
final class MarkdownBuiltinHighlightExtension extends MarkdownSyntaxExtension {
  const MarkdownBuiltinHighlightExtension();

  @override
  final String id = 'live_markdown_editor.highlight';

  @override
  final int apiVersion = MarkdownSyntaxExtension.apiVersion1;

  @override
  final List<String> dependencies = const [];

  @override
  final List<MarkdownSyntaxRule> rules = const [MarkdownBuiltinHighlightRule()];
}

/// The built-in task-list rule ID, shared with the syntax configuration so
/// the task slot can be identified without a runtime type check.
const MarkdownSyntaxRuleId markdownBuiltinTaskListRuleId = MarkdownSyntaxRuleId(
  'live_markdown_editor.block.taskList',
);

/// All built-in descriptors installed by editorDefaults, in profile order.
const List<MarkdownSyntaxExtension> markdownBuiltinExtensions = [
  MarkdownBuiltinTableExtension(),
  MarkdownBuiltinTaskListExtension(),
  MarkdownBuiltinStrikethroughExtension(),
  MarkdownBuiltinHighlightExtension(),
];

/// Recognizes GFM tables: a pipe-containing header row followed by a matching
/// separator row. Produces the identical node/range/tableData structure the
/// flat editor parser always produced.
final class MarkdownBuiltinTableRule implements MarkdownBlockRule {
  const MarkdownBuiltinTableRule();

  static const MarkdownSyntaxRuleId _id = MarkdownSyntaxRuleId(
    'live_markdown_editor.block.table',
  );

  @override
  MarkdownSyntaxRuleId get id => _id;

  @override
  MarkdownExtensionInvalidationScope get invalidationScope =>
      MarkdownExtensionInvalidationScope.forward;

  static final RegExp _separatorCell = RegExp(r'^:?-+:?$');

  @override
  MarkdownBlockMatch? matchBlock(MarkdownBlockParseContext context) {
    if (context.lineCount < 2) return null;
    final source = context.source;
    final headerRange = context.contentRangeAt(0);
    final separatorRange = context.contentRangeAt(1);
    final headerCells = MarkdownTableScanner.scanRow(
      source,
      headerRange.start,
      headerRange.end,
    );
    if (!headerCells.hasPipe) return null;
    if (!_isSeparatorRow(source, separatorRange)) return null;
    final separatorCells = MarkdownTableScanner.scanRow(
      source,
      separatorRange.start,
      separatorRange.end,
    );
    if (headerCells.cells.length != separatorCells.cells.length) return null;

    final alignments = [
      for (final cell in separatorCells.cells)
        MarkdownTableScanner.alignmentForCell(cell, source),
    ];
    final columns = headerCells.cells.length > alignments.length
        ? headerCells.cells.length
        : alignments.length;
    final rows = <MarkdownTableRow>[
      _row(context, 0, headerCells.cells, columns, source),
    ];
    var last = 1;
    var lineIndex = 2;
    while (lineIndex < context.lineCount) {
      final rowRange = context.contentRangeAt(lineIndex);
      final scanned = MarkdownTableScanner.scanRow(
        source,
        rowRange.start,
        rowRange.end,
      );
      if (!scanned.hasPipe) break;
      rows.add(_row(context, lineIndex, scanned.cells, columns, source));
      last = lineIndex;
      lineIndex++;
    }
    final firstLine = context.lineRangeAt(0);
    final lastLine = context.lineRangeAt(last);
    final separatorLine = context.lineRangeAt(1);
    return MarkdownBlockMatch(
      node: MarkdownBlockNode(
        type: MarkdownBlockType.table,
        range: SourceRange(firstLine.start, lastLine.end),
        contentRange: SourceRange(
          headerRange.start,
          context.contentRangeAt(last).end,
        ),
        tableData: MarkdownTableData(
          columns: columns,
          alignments: List.unmodifiable(alignments),
          rows: List.unmodifiable(rows),
          separatorRange: SourceRange(separatorLine.start, separatorLine.end),
        ),
      ),
    );
  }

  bool _isSeparatorRow(String source, SourceRange range) {
    final scanned = MarkdownTableScanner.scanRow(
      source,
      range.start,
      range.end,
    );
    final cells = scanned.cells;
    if (cells.isEmpty) return false;
    for (final cell in cells) {
      if (!_separatorCell.hasMatch(cell.slice(source).trim())) return false;
    }
    return true;
  }

  MarkdownTableRow _row(
    MarkdownBlockParseContext context,
    int lineIndex,
    List<SourceRange> cells,
    int columns,
    String source,
  ) {
    final contentEnd = context.contentRangeAt(lineIndex).end;
    final line = context.lineRangeAt(lineIndex);
    return MarkdownTableRow(
      rowRange: SourceRange(line.start, line.end),
      cells: List.unmodifiable([
        for (var column = 0; column < columns; column++)
          MarkdownTableCell(
            contentRange: column < cells.length
                ? cells[column]
                : SourceRange(contentEnd, contentEnd),
          ),
      ]),
    );
  }
}

/// Recognizes `- [ ] item` / `1. [x] done` list decoration at the task-list
/// slot (before generic list recognition), producing the identical
/// taskListItem node/range structure the flat editor parser always produced.
final class MarkdownBuiltinTaskListRule implements MarkdownBlockRule {
  const MarkdownBuiltinTaskListRule();

  @override
  MarkdownSyntaxRuleId get id => markdownBuiltinTaskListRuleId;

  @override
  MarkdownExtensionInvalidationScope get invalidationScope =>
      MarkdownExtensionInvalidationScope.localBlock;

  static final RegExp _task = RegExp(
    r'^(\s*)([-+*]|\d+[.)])[ \t]+\[([ xX])\][ \t]+',
  );

  @override
  MarkdownBlockMatch? matchBlock(MarkdownBlockParseContext context) {
    final text = context.textAt(0);
    final match = _task.firstMatch(text);
    if (match == null) return null;
    final line = context.lineRangeAt(0);
    final contentEnd = context.contentRangeAt(0).end;
    final prefixEnd = context.contentRangeAt(0).start + match.end;
    return MarkdownBlockMatch(
      node: MarkdownBlockNode(
        type: MarkdownBlockType.taskListItem,
        range: SourceRange(line.start, line.end),
        prefixRange: SourceRange(line.start, prefixEnd),
        contentRange: SourceRange(prefixEnd, contentEnd),
        indent: match.group(1)!.length,
        checked: match.group(3)!.toLowerCase() == 'x',
      ),
    );
  }
}

/// Recognizes `~~content~~` as a strikethrough delimiter node with the same
/// ranges the inline parser always produced.
final class MarkdownBuiltinStrikethroughRule implements MarkdownInlineRule {
  const MarkdownBuiltinStrikethroughRule();

  static const MarkdownSyntaxRuleId _id = MarkdownSyntaxRuleId(
    'live_markdown_editor.inline.strikethrough',
  );

  @override
  MarkdownSyntaxRuleId get id => _id;

  @override
  MarkdownExtensionInvalidationScope get invalidationScope =>
      MarkdownExtensionInvalidationScope.localBlock;

  @override
  Set<int> get triggerCodeUnits => const {0x7E};

  @override
  MarkdownInlineMatch? matchInline(MarkdownInlineParseContext context) =>
      _matchDelimiter(context, 0x7E, MarkdownInlineType.strikethrough);
}

/// Recognizes `==content==` as a highlight delimiter node with the same
/// ranges the inline parser always produced.
final class MarkdownBuiltinHighlightRule implements MarkdownInlineRule {
  const MarkdownBuiltinHighlightRule();

  static const MarkdownSyntaxRuleId _id = MarkdownSyntaxRuleId(
    'live_markdown_editor.inline.highlight',
  );

  @override
  MarkdownSyntaxRuleId get id => _id;

  @override
  MarkdownExtensionInvalidationScope get invalidationScope =>
      MarkdownExtensionInvalidationScope.localBlock;

  @override
  Set<int> get triggerCodeUnits => const {0x3D};

  @override
  MarkdownInlineMatch? matchInline(MarkdownInlineParseContext context) =>
      _matchDelimiter(context, 0x3D, MarkdownInlineType.highlight);
}

MarkdownInlineMatch? _matchDelimiter(
  MarkdownInlineParseContext context,
  int codeUnit,
  MarkdownInlineType type,
) {
  final source = context.source;
  final cursor = context.cursor;
  final end = context.enclosingRange.end;
  if (cursor + 1 >= end) return null;
  if (source.codeUnitAt(cursor) != codeUnit) return null;
  if (source.codeUnitAt(cursor + 1) != codeUnit) return null;
  final delimiter = String.fromCharCode(codeUnit) * 2;
  final closing = _findClosingDelimiter(source, delimiter, cursor + 2, end);
  if (closing == null || closing == cursor + 2) return null;
  final rangeEnd = closing + 2;
  return MarkdownInlineMatch(
    node: MarkdownInlineNode(
      type: type,
      range: SourceRange(cursor, rangeEnd),
      contentRange: SourceRange(cursor + 2, closing),
      openingRange: SourceRange(cursor, cursor + 2),
      closingRange: SourceRange(closing, rangeEnd),
    ),
    childRanges: [SourceRange(cursor + 2, closing)],
  );
}

int? _findClosingDelimiter(
  String source,
  String delimiter,
  int start,
  int end,
) {
  var candidate = source.indexOf(delimiter, start);
  while (candidate >= 0 && candidate + delimiter.length <= end) {
    if (!_isEscaped(source, candidate)) return candidate;
    candidate = source.indexOf(delimiter, candidate + 1);
  }
  return null;
}

bool _isEscaped(String source, int offset) {
  var slashes = 0;
  for (
    var index = offset - 1;
    index >= 0 && source.codeUnitAt(index) == 0x5C;
    index--
  ) {
    slashes++;
  }
  return slashes.isOdd;
}
