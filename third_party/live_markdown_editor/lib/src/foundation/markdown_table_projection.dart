import 'package:flutter/widgets.dart';

import '../model/source_range.dart';
import '../direction/markdown_direction.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';
import 'markdown_source_position_mapper.dart';
import 'markdown_text_projection.dart';

/// Builds per-table layout metadata (chunk ranges, directions) from a
/// projection's segment list. Shared by the Live and Read projections.
///
/// Chunk ranges cover each source-indexed cell and its structural delimiters.
final class MarkdownTableProjection {
  const MarkdownTableProjection();

  static const MarkdownDirectionResolver _resolver =
      MarkdownDirectionResolver();

  static List<MarkdownProjectionTable> build({
    required MarkdownDocument document,
    required MarkdownSourcePositionMapper mapper,
    required TextDirection fallbackDirection,
    List<SourceRange> hiddenRanges = const [],
  }) {
    final tables = <MarkdownProjectionTable>[];
    for (final block in document.blocks) {
      if (block.type != MarkdownBlockType.table) continue;
      // A table inside a folded range has no visible rows: mapping it through
      // the collapsed offsets would leave degenerate cell squares behind.
      if (_isHidden(block.range, hiddenRanges)) continue;
      final data = block.tableData!;
      final tableDirection =
          _cellDirection(data.rows.first.cells.first, document.source) ??
          fallbackDirection;
      final rows = <MarkdownProjectionTableRow>[];
      for (var rowIndex = 0; rowIndex < data.rows.length; rowIndex++) {
        final row = data.rows[rowIndex];
        final cellInfo = <MarkdownProjectionTableCell>[];
        final rowContentEnd = _rowContentEnd(document.source, row.rowRange);
        for (var c = 0; c < row.cells.length; c++) {
          final cell = row.cells[c];
          // Chunks cover the whole row: leading gaps (pipes, visible in
          // active mode) attach to the first cell, inter-cell separators to
          // the following cell, and the trailing part to the last cell.
          // Padding widgets widen chunks at the cell edges.
          final start = c == 0
              ? mapper.sourceToVisual(
                  row.rowRange.start,
                  affinity: TextAffinity.upstream,
                )
              : mapper.sourceToVisual(
                  row.cells[c - 1].contentRange.end,
                  affinity: TextAffinity.upstream,
                );
          final end = c == row.cells.length - 1
              ? mapper.sourceToVisual(
                  rowContentEnd,
                  affinity: TextAffinity.upstream,
                )
              : mapper.sourceToVisual(
                  cell.contentRange.end,
                  affinity: TextAffinity.upstream,
                );
          cellInfo.add(
            MarkdownProjectionTableCell(
              chunkStart: start,
              chunkEnd: end,
              direction:
                  _cellDirection(cell, document.source) ?? tableDirection,
              column: c,
              alignment: c < data.alignments.length
                  ? data.alignments[c]
                  : MarkdownTableAlignment.start,
            ),
          );
        }
        rows.add(
          MarkdownProjectionTableRow(
            row: rowIndex,
            visualStart: cellInfo.first.chunkStart,
            visualEnd: cellInfo.last.chunkEnd,
            cells: List.unmodifiable(cellInfo),
          ),
        );
      }
      tables.add(
        MarkdownProjectionTable(
          id: block.range.start,
          direction: tableDirection,
          separatorVisualStart: mapper.sourceToVisual(
            data.separatorRange.start,
            affinity: TextAffinity.downstream,
          ),
          separatorVisualEnd: mapper.sourceToVisual(
            data.separatorRange.end,
            affinity: TextAffinity.upstream,
          ),
          rows: List.unmodifiable(rows),
        ),
      );
    }
    return List.unmodifiable(tables);
  }

  static bool _isHidden(SourceRange range, List<SourceRange> hiddenRanges) {
    for (final hidden in hiddenRanges) {
      if (hidden.start <= range.start && range.end <= hidden.end) return true;
    }
    return false;
  }

  static TextDirection? _cellDirection(MarkdownTableCell cell, String source) =>
      _resolver.firstDirection(cell.contentRange.slice(source));

  static int _rowContentEnd(String source, SourceRange rowRange) {
    final end = rowRange.end;
    if (end > rowRange.start && source.codeUnitAt(end - 1) == 0x0A) {
      return end - 1;
    }
    return end;
  }
}
