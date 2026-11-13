import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../model/source_range.dart';
import '../parser/markdown_node.dart';
import 'markdown_projection_segment.dart';
import 'markdown_source_position_mapper.dart';

/// Immutable inputs used to build one source-to-visual projection.
final class MarkdownProjectionContext {
  const MarkdownProjectionContext({
    required this.value,
    required this.mode,
    required this.constraints,
    required this.style,
    required this.fallbackDirection,
  });

  final TextEditingValue value;
  final MarkdownEditorMode mode;
  final BoxConstraints constraints;
  final TextStyle style;
  final TextDirection fallbackDirection;
}

/// Builds an immutable visual representation without changing Markdown source.
abstract interface class MarkdownTextProjection {
  MarkdownProjectionSnapshot project(MarkdownProjectionContext context);
}

/// A source block and the half-open range of segment indexes that render it.
final class MarkdownProjectionBlock {
  const MarkdownProjectionBlock({
    required this.sourceRange,
    required this.segmentRange,
    required this.direction,
    this.id,
  });

  final SourceRange sourceRange;
  final SourceRange segmentRange;
  final TextDirection direction;
  final Object? id;
}

/// Per-table layout metadata consumed by the layout.
///
/// [MarkdownProjectionTableCell.chunkStart] and
/// [MarkdownProjectionTableCell.chunkEnd] are visual offsets of the cell's
/// layout chunk (cell text plus its padding widgets); the layout splits a
/// table row's span at chunk boundaries so each cell renders as its own
/// paragraph with its own base direction.
final class MarkdownProjectionTable {
  const MarkdownProjectionTable({
    required this.id,
    required this.direction,
    required this.separatorVisualStart,
    required this.separatorVisualEnd,
    required this.rows,
  });

  /// Stable per-table key (the block's source start offset) used for scroll
  /// offsets and semantics.
  final Object id;
  final TextDirection direction;
  final int separatorVisualStart;
  final int separatorVisualEnd;
  final List<MarkdownProjectionTableRow> rows;
}

final class MarkdownProjectionTableRow {
  const MarkdownProjectionTableRow({
    required this.row,
    required this.visualStart,
    required this.visualEnd,
    required this.cells,
  });

  /// Zero-based parser row identity; source column ordering never changes.
  final int row;
  final int visualStart;
  final int visualEnd;
  final List<MarkdownProjectionTableCell> cells;
}

final class MarkdownProjectionTableCell {
  const MarkdownProjectionTableCell({
    required this.chunkStart,
    required this.chunkEnd,
    required this.direction,
    required this.column,
    required this.alignment,
  });

  /// Visual range of the cell's layout chunk, including its padding widgets.
  final int chunkStart;
  final int chunkEnd;
  final TextDirection direction;
  final int column;
  final MarkdownTableAlignment alignment;
}

/// One validated, immutable projection consumed by layout and hit testing.
final class MarkdownProjectionSnapshot {
  MarkdownProjectionSnapshot({
    required this.source,
    required this.selection,
    required this.composing,
    required List<MarkdownProjectionSegment> segments,
    required List<MarkdownProjectionBlock> blocks,
    this.visualText,
    this.invalidationKey,
    List<MarkdownProjectionTable> tables = const [],
  }) : segments = List.unmodifiable(segments),
       blocks = List.unmodifiable(blocks),
       tables = List.unmodifiable(tables),
       mapper = MarkdownSourcePositionMapper(segments, source: source) {
    _validate();
  }

  final String source;
  final TextSelection selection;
  final TextRange composing;
  final List<MarkdownProjectionSegment> segments;
  final List<MarkdownProjectionBlock> blocks;

  /// Optional projected span tree rendered for these exact [segments].
  ///
  /// When absent, the editable surface uses its controller's span tree.
  final TextSpan? visualText;
  final MarkdownSourcePositionMapper mapper;
  final Object? invalidationKey;

  /// Per-table layout metadata (chunk ranges, directions) for table rows.
  final List<MarkdownProjectionTable> tables;

  void _validate() {
    final sourceLength = source.length;
    if ((selection.isValid && !_rangeWithin(selection, sourceLength)) ||
        (composing.isValid && !_rangeWithin(composing, sourceLength))) {
      throw ArgumentError('Selection and composing ranges must be in source.');
    }

    final projectedText = visualText?.toPlainText(
      includeSemanticsLabels: false,
    );
    if (projectedText != null && projectedText.length != mapper.visualLength) {
      throw ArgumentError.value(
        visualText,
        'visualText',
        'Visual text length must match the projected segment length.',
      );
    }

    var coveredSourceEnd = 0;
    for (final segment in segments) {
      final range = segment.sourceRange;
      if (range.start < 0 ||
          range.end < range.start ||
          range.end > sourceLength ||
          range.start != coveredSourceEnd) {
        throw ArgumentError.value(
          segments,
          'segments',
          'Segments must cover the source in order without gaps or overlaps.',
        );
      }
      coveredSourceEnd = range.end;
    }
    if (coveredSourceEnd != sourceLength) {
      throw ArgumentError.value(
        segments,
        'segments',
        'Segments must cover the complete source.',
      );
    }

    var previousEnd = 0;
    for (final block in blocks) {
      final sourceRange = block.sourceRange;
      final segmentRange = block.segmentRange;
      if (sourceRange.start < 0 ||
          sourceRange.end < sourceRange.start ||
          sourceRange.end > sourceLength ||
          sourceRange.start != previousEnd ||
          segmentRange.start < 0 ||
          segmentRange.end < segmentRange.start ||
          segmentRange.end > segments.length) {
        throw ArgumentError.value(
          blocks,
          'blocks',
          'Blocks must cover the source in order and refer to valid segments.',
        );
      }
      previousEnd = sourceRange.end;
    }
    if (blocks.isNotEmpty && previousEnd != sourceLength) {
      throw ArgumentError.value(
        blocks,
        'blocks',
        'Non-empty block lists must cover the complete source.',
      );
    }

    for (final table in tables) {
      if (table.separatorVisualStart < 0 ||
          table.separatorVisualEnd < table.separatorVisualStart ||
          table.separatorVisualEnd > mapper.visualLength) {
        throw ArgumentError.value(tables, 'tables', 'Invalid separator range.');
      }
      for (final row in table.rows) {
        if (row.row < 0 ||
            row.visualStart < 0 ||
            row.visualEnd < row.visualStart ||
            row.visualEnd > mapper.visualLength ||
            row.cells.isEmpty) {
          throw ArgumentError.value(tables, 'tables', 'Invalid table rows.');
        }
        for (final cell in row.cells) {
          if (cell.chunkStart < row.visualStart ||
              cell.chunkEnd < cell.chunkStart ||
              cell.chunkEnd > row.visualEnd) {
            throw ArgumentError.value(tables, 'tables', 'Invalid table cells.');
          }
        }
      }
    }
  }

  static bool _rangeWithin(TextRange range, int sourceLength) =>
      range.start >= 0 && range.end >= range.start && range.end <= sourceLength;
}

/// A projection with no hidden or replaced source positions.
final class IdentityMarkdownTextProjection implements MarkdownTextProjection {
  const IdentityMarkdownTextProjection();

  @override
  MarkdownProjectionSnapshot project(MarkdownProjectionContext context) {
    final source = context.value.text;
    final segments = <MarkdownProjectionSegment>[
      MarkdownProjectionSegment.text(
        sourceRange: SourceRange(0, source.length),
        text: source,
      ),
    ];
    final blocks = <MarkdownProjectionBlock>[];
    var start = 0;
    for (var index = 0; index < source.length; index += 1) {
      if (source.codeUnitAt(index) != 0x0A) continue;
      blocks.add(
        MarkdownProjectionBlock(
          sourceRange: SourceRange(start, index + 1),
          segmentRange: const SourceRange(0, 1),
          direction: context.fallbackDirection,
        ),
      );
      start = index + 1;
    }
    blocks.add(
      MarkdownProjectionBlock(
        sourceRange: SourceRange(start, source.length),
        segmentRange: const SourceRange(0, 1),
        direction: context.fallbackDirection,
      ),
    );
    return MarkdownProjectionSnapshot(
      source: source,
      selection: context.value.selection,
      composing: context.value.composing,
      segments: segments,
      blocks: blocks,
      invalidationKey: Object.hash(
        source,
        context.value.selection,
        context.value.composing,
        context.constraints.maxWidth,
        context.style,
        context.fallbackDirection,
      ),
    );
  }
}
