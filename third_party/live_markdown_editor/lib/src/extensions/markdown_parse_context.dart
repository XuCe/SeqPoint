import '../model/source_range.dart';
import '../parser/markdown_node.dart';

/// One open emphasis-style delimiter run visible to an inline recognizer.
///
/// Offsets are absolute UTF-16 positions into the document source. The
/// snapshot is immutable: recognizers observe state and can never mutate the
/// engine's delimiter stack.
final class MarkdownInlineDelimiterInfo {
  const MarkdownInlineDelimiterInfo({
    required this.marker,
    required this.start,
    required this.end,
  });

  /// The delimiter character code unit (`*` or `_` for core delimiters).
  final int marker;

  /// Absolute start offset of the still-open run.
  final int start;

  /// Absolute end offset of the still-open run (may shrink as emphasis
  /// resolves, so this is only the value at recognition time).
  final int end;
}

/// Bounded, read-only state offered to an inline recognizer.
///
/// The context exposes the source, the absolute cursor at which a match must
/// start, the enclosing inline range, a snapshot of active delimiters, and a
/// safe child-inline parser. Recognizers return immutable
/// [MarkdownInlineMatch]es; they can never mutate parser state or source.
final class MarkdownInlineParseContext {
  const MarkdownInlineParseContext({
    required this.source,
    required this.cursor,
    required this.enclosingRange,
    required this.parseChildren,
    this.activeDelimiters = const [],
  });

  /// The exact document source being parsed. Never mutate it.
  final String source;

  /// Absolute UTF-16 offset at which a match must start.
  final int cursor;

  /// The absolute range currently being parsed as inline content. Matches
  /// must stay inside it.
  final SourceRange enclosingRange;

  /// Snapshot of delimiter runs still open at [cursor], oldest first.
  final List<MarkdownInlineDelimiterInfo> activeDelimiters;

  /// Parses `range` (which must lie inside [enclosingRange]) as inline
  /// content and returns its immutable nodes. The engine enforces the
  /// maximum child recursion depth and literalizes on violation.
  final List<MarkdownInlineNode> Function(SourceRange) parseChildren;

  /// Whether [cursor] is at the end of [enclosingRange].
  bool get isAtEnd => cursor >= enclosingRange.end;
}

/// The immutable result of an inline rule match at the context cursor.
///
/// [childRanges] must be ordered and non-overlapping; the engine parses each
/// range with [MarkdownInlineParseContext.parseChildren] and attaches the
/// nodes as [MarkdownInlineNode.children] of [node].
final class MarkdownInlineMatch {
  const MarkdownInlineMatch({required this.node, this.childRanges = const []});

  final MarkdownInlineNode node;

  /// Content ranges the engine must parse as child inline nodes.
  final List<SourceRange> childRanges;
}

/// Bounded, read-only state offered to a block recognizer.
///
/// Lines are indexed from the current parse range. [contentRangeAt] returns
/// the line after active container prefixes; [lineRangeAt] returns the full
/// physical line including its terminator. Matches must start at the current
/// line and consume whole lines.
final class MarkdownBlockParseContext {
  const MarkdownBlockParseContext({
    required this.source,
    required this.lineIndex,
    required this.lineCount,
    required this.depth,
    required this.lineRangeAt,
    required this.contentRangeAt,
    required this.parseChildren,
  });

  /// The exact document source being parsed. Never mutate it.
  final String source;

  /// Index of the line at which a match must start.
  final int lineIndex;

  /// Number of lines available to this context.
  final int lineCount;

  /// Current extension child recursion depth (0 at the top level).
  final int depth;

  /// Full physical line range (including its terminator) for [lineIndex].
  final SourceRange Function(int lineIndex) lineRangeAt;

  /// Content range (after container prefixes, excluding the terminator).
  final SourceRange Function(int lineIndex) contentRangeAt;

  /// Parses `range` (which must lie inside the current container) as child
  /// blocks. The engine enforces the maximum child recursion depth.
  final List<MarkdownBlockNode> Function(SourceRange) parseChildren;

  /// The content text of [lineIndex] after container prefixes.
  String textAt(int lineIndex) => contentRangeAt(lineIndex).slice(source);
}

/// The immutable result of a block rule match at the current line.
///
/// [node] must span whole lines starting at the offered line. [childRanges]
/// must be ordered and non-overlapping; the engine parses each range with
/// [MarkdownBlockParseContext.parseChildren] and attaches the nodes as
/// [MarkdownBlockNode.children] of [node].
final class MarkdownBlockMatch {
  const MarkdownBlockMatch({required this.node, this.childRanges = const []});

  final MarkdownBlockNode node;

  /// Content ranges the engine must parse as child blocks.
  final List<SourceRange> childRanges;
}
