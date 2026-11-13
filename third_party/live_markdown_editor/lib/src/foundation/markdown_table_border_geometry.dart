import 'package:flutter/widgets.dart';

import '../theme/markdown_table_style.dart';

typedef MarkdownTableBorderSegment = ({
  Offset start,
  Offset end,
  MarkdownTableBorderSide side,
});

typedef _EdgeKey = ({
  bool vertical,
  double coordinate,
  double start,
  double end,
});

List<MarkdownTableBorderSegment> resolveCollapsedTableBorderSegments(
  List<Rect> cells,
  MarkdownResolvedTableBorder border, {
  List<MarkdownResolvedTableBorder?> cellBorders = const [],
}) {
  final winners = <_EdgeKey, ({MarkdownTableBorderSide side, int order})>{};

  void add(_EdgeKey key, MarkdownTableBorderSide side, int order) {
    final previous = winners[key];
    if (previous == null ||
        !previous.side.isVisible ||
        (side.isVisible && side.width >= previous.side.width)) {
      winners[key] = (side: side, order: order);
    }
  }

  for (var index = 0; index < cells.length; index++) {
    final cell = cells[index];
    final resolved = index < cellBorders.length
        ? cellBorders[index] ?? border
        : border;
    add(
      (
        vertical: true,
        coordinate: cell.left,
        start: cell.top,
        end: cell.bottom,
      ),
      resolved.left,
      index,
    );
    add(
      (
        vertical: false,
        coordinate: cell.top,
        start: cell.left,
        end: cell.right,
      ),
      resolved.top,
      index,
    );
    add(
      (
        vertical: true,
        coordinate: cell.right,
        start: cell.top,
        end: cell.bottom,
      ),
      resolved.right,
      index,
    );
    add(
      (
        vertical: false,
        coordinate: cell.bottom,
        start: cell.left,
        end: cell.right,
      ),
      resolved.bottom,
      index,
    );
  }

  final edges =
      [
        for (final entry in winners.entries)
          (
            vertical: entry.key.vertical,
            coordinate: entry.key.coordinate,
            start: entry.key.start,
            end: entry.key.end,
            side: entry.value.side,
            order: entry.value.order,
          ),
      ]..sort((a, b) {
        final orientation = (a.vertical ? 0 : 1).compareTo(b.vertical ? 0 : 1);
        if (orientation != 0) return orientation;
        final coordinate = a.coordinate.compareTo(b.coordinate);
        if (coordinate != 0) return coordinate;
        final start = a.start.compareTo(b.start);
        if (start != 0) return start;
        return a.order.compareTo(b.order);
      });

  final merged =
      <
        ({
          bool vertical,
          double coordinate,
          double start,
          double end,
          MarkdownTableBorderSide side,
        })
      >[];
  for (final edge in edges) {
    if (merged.isNotEmpty) {
      final previous = merged.last;
      if (previous.vertical == edge.vertical &&
          previous.coordinate == edge.coordinate &&
          previous.end == edge.start &&
          previous.side == edge.side) {
        merged[merged.length - 1] = (
          vertical: previous.vertical,
          coordinate: previous.coordinate,
          start: previous.start,
          end: edge.end,
          side: previous.side,
        );
        continue;
      }
    }
    merged.add((
      vertical: edge.vertical,
      coordinate: edge.coordinate,
      start: edge.start,
      end: edge.end,
      side: edge.side,
    ));
  }

  return List.unmodifiable([
    for (final edge in merged)
      if (edge.vertical)
        (
          start: Offset(edge.coordinate, edge.start),
          end: Offset(edge.coordinate, edge.end),
          side: edge.side,
        )
      else
        (
          start: Offset(edge.start, edge.coordinate),
          end: Offset(edge.end, edge.coordinate),
          side: edge.side,
        ),
  ]);
}
