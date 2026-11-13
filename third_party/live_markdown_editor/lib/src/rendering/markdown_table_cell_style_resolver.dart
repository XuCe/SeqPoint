import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../direction/markdown_direction.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';
import '../theme/markdown_table_style.dart';

List<MarkdownTableCellStyle?> resolveMarkdownTableCellStyles({
  required MarkdownDocument document,
  required MarkdownTableStyle style,
  required MarkdownEditorMode mode,
  required TextDirection fallbackDirection,
}) {
  final resolver = style.cellStyleResolver;
  if (resolver == null) return const [];
  const directionResolver = MarkdownDirectionResolver();
  final result = <MarkdownTableCellStyle?>[];
  for (final block in document.blocks) {
    if (block.type != MarkdownBlockType.table) continue;
    final rows = block.tableData!.rows;
    final firstCellDirection = directionResolver.firstDirection(
      rows.first.cells.first.contentRange.slice(document.source),
    );
    final tableDirection = firstCellDirection ?? fallbackDirection;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      for (var column = 0; column < row.cells.length; column++) {
        final cellDirection =
            directionResolver.firstDirection(
              row.cells[column].contentRange.slice(document.source),
            ) ??
            tableDirection;
        result.add(
          resolver(
            MarkdownTableCellStyleContext(
              mode: mode,
              row: rowIndex,
              column: column,
              isHeader: rowIndex == 0,
              isOddBodyRow: rowIndex > 0 && rowIndex.isOdd,
              tableDirection: tableDirection,
              cellDirection: cellDirection,
            ),
          ),
        );
      }
    }
  }
  return List.unmodifiable(result);
}
