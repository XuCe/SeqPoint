import '../model/source_range.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';

/// One foldable block and the source range that collapses when it is folded.
///
/// [start] is the fold identity: the block's start offset, which is what the
/// controller stores. [hiddenRange] never includes the block's first hard line,
/// so a folded heading, list item, blockquote, or fence always keeps its own
/// line (and its marker, language, or task control) visible.
final class MarkdownFoldRange {
  const MarkdownFoldRange({
    required this.start,
    required this.hiddenRange,
    required this.type,
  });

  final int start;
  final SourceRange hiddenRange;
  final MarkdownBlockType type;
}

/// Every block in [document] that can be folded, in document order.
///
/// Foldable constructs: headings (their whole section), list items (their
/// children), blockquotes (their children), and fenced code blocks (their
/// content). Single-line blocks are omitted because folding them would change
/// nothing.
List<MarkdownFoldRange> markdownFoldableBlocks(MarkdownDocument document) {
  final folds = <MarkdownFoldRange>[];

  void visit(List<MarkdownBlockNode> blocks) {
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      final hiddenStart = _firstLineEnd(document.source, block.range.start);
      switch (block.type) {
        case MarkdownBlockType.heading:
          final sectionEnd = _sectionEnd(blocks, index);
          if (sectionEnd > hiddenStart &&
              !_isBlankRange(document.source, hiddenStart, sectionEnd)) {
            folds.add(
              MarkdownFoldRange(
                start: block.range.start,
                hiddenRange: SourceRange(hiddenStart, sectionEnd),
                type: block.type,
              ),
            );
          }
        case MarkdownBlockType.listItem ||
            MarkdownBlockType.blockquote ||
            MarkdownBlockType.fencedCode:
          if (block.range.end > hiddenStart &&
              !_isBlankRange(document.source, hiddenStart, block.range.end)) {
            folds.add(
              MarkdownFoldRange(
                start: block.range.start,
                hiddenRange: SourceRange(hiddenStart, block.range.end),
                type: block.type,
              ),
            );
          }
        default:
          break;
      }
      if (block.children.isNotEmpty) visit(block.children);
    }
  }

  visit(document.blocks);
  return List.unmodifiable(folds);
}

/// The subset of [foldedStarts] that still matches a foldable block.
///
/// Stored offsets that no longer sit on a foldable block start are inert, so
/// edits, undo, and mode switches never produce stale folds.
List<MarkdownFoldRange> resolveMarkdownFolds(
  MarkdownDocument document,
  Set<int> foldedStarts,
) {
  if (foldedStarts.isEmpty) return const [];
  return List.unmodifiable([
    for (final fold in markdownFoldableBlocks(document))
      if (foldedStarts.contains(fold.start)) fold,
  ]);
}

/// End offset of a heading's section: the last following sibling before the
/// next heading whose level is the same or higher (shallower).
int _sectionEnd(List<MarkdownBlockNode> siblings, int headingIndex) {
  final heading = siblings[headingIndex];
  final level = heading.level ?? 1;
  var end = heading.range.end;
  for (var index = headingIndex + 1; index < siblings.length; index++) {
    final sibling = siblings[index];
    if (sibling.type == MarkdownBlockType.heading &&
        (sibling.level ?? 1) <= level) {
      break;
    }
    end = sibling.range.end;
  }
  return end;
}

/// Whether [start] to [end] holds nothing but whitespace.
bool _isBlankRange(String source, int start, int end) {
  for (var index = start; index < end; index++) {
    final unit = source.codeUnitAt(index);
    if (unit != 0x20 && unit != 0x09 && unit != 0x0A && unit != 0x0D) {
      return false;
    }
  }
  return true;
}

/// Offset immediately after the first hard line starting at [start].
int _firstLineEnd(String source, int start) {
  if (start >= source.length) return source.length;
  final newline = source.indexOf('\n', start);
  return newline == -1 ? source.length : newline + 1;
}
