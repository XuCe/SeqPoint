import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../parser/markdown_node.dart';
import '../theme/markdown_table_style.dart';
import 'markdown_source_position_mapper.dart';
import 'markdown_text_projection.dart';

/// Package-owned text geometry for a projected editable document.
///
/// Each hard line is a separate Flutter paragraph. A paragraph has only one
/// bidi base direction, so a single [TextPainter] cannot correctly represent
/// an aware document containing both LTR and RTL source lines. Table rows go
/// one step further: every cell is its own paragraph with its own base
/// direction, so mixed-direction cells resolve independently. An RTL table
/// mirrors like an RTL paragraph: columns flow right-to-left and the row
/// sits at the right edge of the viewport.
final class MarkdownEditableLayout {
  MarkdownEditableLayout({
    required this.text,
    required this.textDirection,
    required this.mapper,
    this.textAlign = TextAlign.start,
    this.textScaler = TextScaler.noScaling,
    this.strutStyle,
    this.locale,
    this.textHeightBehavior,
    this.textWidthBasis = TextWidthBasis.parent,
    this.maxLines,
    this.cursorWidth = 1,
    List<PlaceholderDimensions> placeholderDimensions = const [],
    List<TextDirection> lineDirections = const [],
    List<double> paragraphStartInsets = const [],
    List<MarkdownProjectionTable> tables = const [],
    this.tableStyle = const MarkdownTableStyle(),
    List<MarkdownTableCellStyle?> tableCellStyles = const [],
  }) : assert(cursorWidth >= 0),
       placeholderDimensions = List.unmodifiable(placeholderDimensions),
       lineDirections = List.unmodifiable(lineDirections),
       paragraphStartInsets = List.unmodifiable(paragraphStartInsets),
       _tables = List.unmodifiable(tables),
       _tableCellStyles = List.unmodifiable(tableCellStyles);

  final TextSpan text;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final StrutStyle? strutStyle;
  final Locale? locale;
  final TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;
  final int? maxLines;
  final double cursorWidth;
  final List<PlaceholderDimensions> placeholderDimensions;
  final List<TextDirection> lineDirections;
  final List<double> paragraphStartInsets;
  final List<MarkdownProjectionTable> _tables;
  final List<MarkdownTableCellStyle?> _tableCellStyles;
  final MarkdownTableStyle tableStyle;
  final MarkdownSourcePositionMapper mapper;
  late final List<_MarkdownParagraph> _paragraphs = _buildParagraphs();
  late final Map<int, MarkdownProjectionTableRow> _rowsByVisualStart = () {
    final map = <int, MarkdownProjectionTableRow>{};
    for (final table in _tables) {
      for (final row in table.rows) {
        map[row.visualStart] = row;
      }
    }
    return map;
  }();
  late final Map<int, MarkdownProjectionTable> _tablesByVisualStart = () {
    final map = <int, MarkdownProjectionTable>{};
    for (final table in _tables) {
      for (final row in table.rows) {
        map[row.visualStart] = table;
      }
    }
    return map;
  }();
  double? _layoutWidth;
  double _contentWidth = 0;
  double _height = 0;
  List<_MarkdownLineLayout> _lines = const [];
  Map<Object, List<_MarkdownLineLayout>> _tableLines = const {};

  late final bool _usesStyledTableSlots =
      tableStyle.borderModel == MarkdownTableBorderModel.separated ||
      tableStyle.cellBorder.start.isVisible ||
      tableStyle.cellBorder.top.isVisible ||
      tableStyle.cellBorder.end.isVisible ||
      tableStyle.cellBorder.bottom.isVisible ||
      tableStyle.outerBorder.start.isVisible ||
      tableStyle.outerBorder.top.isVisible ||
      tableStyle.outerBorder.end.isVisible ||
      tableStyle.outerBorder.bottom.isVisible ||
      tableStyle.backgroundColor.a > 0 ||
      tableStyle.headerBackgroundColor.a > 0 ||
      tableStyle.bodyBackgroundColor.a > 0 ||
      tableStyle.oddRowBackgroundColor.a > 0 ||
      tableStyle.evenRowBackgroundColor.a > 0 ||
      tableStyle.cellPadding != EdgeInsetsDirectional.zero ||
      tableStyle.headerTextStyle != null ||
      tableStyle.bodyTextStyle != null ||
      _tableCellStyles.any((style) => style != null);

  MarkdownTableCellStyle? _cellStyle(_MarkdownParagraph paragraph) {
    final index = paragraph.tableCellIndex;
    return index == null || index >= _tableCellStyles.length
        ? null
        : _tableCellStyles[index];
  }

  EdgeInsets _cellPadding(
    MarkdownProjectionTable table,
    _MarkdownParagraph paragraph,
  ) => (_cellStyle(paragraph)?.padding ?? tableStyle.cellPadding).resolve(
    table.direction,
  );

  double get _tableColumnSpacing {
    if (!_usesStyledTableSlots) return 16;
    return tableStyle.borderModel == MarkdownTableBorderModel.collapsed
        ? 0
        : tableStyle.columnSpacing;
  }

  Size get size {
    _debugAssertLaidOut();
    return Size(_layoutWidth!, _height);
  }

  double get contentWidth {
    _debugAssertLaidOut();
    return _contentWidth;
  }

  double get preferredLineHeight {
    _debugAssertLaidOut();
    return _lines.first.painter.preferredLineHeight;
  }

  late final List<MarkdownLineRun> _lineRuns = List.unmodifiable([
    for (final line in _lines)
      MarkdownLineRun(
        visualStart: line.visualStart,
        top: line.top,
        height: line.height,
        tableId: line.tableId,
      ),
  ]);

  /// One entry per visual hard line, in paint order: its visual start offset
  /// and vertical band. Used by the gutter to place numbers and fold marks.
  List<MarkdownLineRun> get lineRuns => _lineRuns;

  List<TextBox> get inlinePlaceholderBoxes {
    _debugAssertLaidOut();
    return [
      for (final line in _lines)
        for (var index = 0; index < line.paragraphs.length; index++)
          if (line.paragraphs[index].hasPlaceholders)
            for (final box
                in line.paragraphs[index].painter.inlinePlaceholderBoxes ??
                    const <TextBox>[])
              _translateBox(
                box,
                dx:
                    line.left +
                    line.xForParagraph(line.paragraphs[index]) -
                    (line.tableId == null ? 0.0 : tableScroll(line.tableId!)),
                dy: line.top + line.yForParagraph(line.paragraphs[index]),
              ),
    ];
  }

  void layout({required double maxWidth}) {
    assert(maxWidth >= 0 && maxWidth.isFinite);
    if (_layoutWidth == maxWidth) return;
    final nextContentWidth = maxWidth > cursorWidth
        ? maxWidth - cursorWidth
        : 0.0;
    final layouts = <_MarkdownLineLayout>[];
    final tableColumnWidths = <Object, List<double>>{};
    var scan = 0;
    while (scan < _paragraphs.length) {
      final first = _paragraphs[scan];
      var scanEnd = scan + 1;
      while (scanEnd < _paragraphs.length &&
          _paragraphs[scanEnd].lineIndex == first.lineIndex) {
        scanEnd++;
      }
      final table = _tablesByVisualStart[first.visualStart];
      if (table != null) {
        final widths = tableColumnWidths.putIfAbsent(table.id, () => []);
        for (final paragraph in _paragraphs.sublist(scan, scanEnd)) {
          paragraph.painter.layout(maxWidth: double.infinity);
          final padding = _cellPadding(table, paragraph);
          final column = paragraph.column!;
          while (widths.length <= column) {
            widths.add(0);
          }
          widths[column] = math.max(
            widths[column],
            paragraph.painter.width + padding.horizontal,
          );
        }
      }
      scan = scanEnd;
    }
    var top = 0.0;
    var index = 0;
    while (index < _paragraphs.length) {
      final firstParagraph = _paragraphs[index];
      var end = index + 1;
      while (end < _paragraphs.length &&
          _paragraphs[end].lineIndex == firstParagraph.lineIndex) {
        end++;
      }
      final group = _paragraphs.sublist(index, end);
      final table = _tablesByVisualStart[firstParagraph.visualStart];
      // Whole-row chunks (active tables) are single paragraphs but still own
      // the table's horizontal viewport.
      final isTableRow = group.length > 1 || table != null;
      var height = 0.0;
      var groupWidth = 0.0;
      for (final paragraph in group) {
        if (isTableRow) {
          // Cells never wrap; padding widgets carry the column widths.
          paragraph.painter.layout(maxWidth: double.infinity);
        } else {
          final startInset = paragraph.startInset.clamp(0.0, nextContentWidth);
          final paragraphWidth = nextContentWidth - startInset;
          paragraph.painter.layout(
            minWidth: paragraphWidth,
            maxWidth: paragraphWidth,
          );
        }
        final paragraphHeight = paragraph.painter.height > 0
            ? paragraph.painter.height
            : paragraph.painter.preferredLineHeight;
        final paragraphPadding = table == null
            ? EdgeInsets.zero
            : _cellPadding(table, paragraph);
        final paddedHeight = paragraphHeight + paragraphPadding.vertical;
        if (paddedHeight > height) height = paddedHeight;
        groupWidth += paragraph.painter.width;
      }
      final columnWidths = table == null
          ? const <double>[]
          : tableColumnWidths[table.id]!;
      if (table != null) {
        groupWidth = 0;
        for (final paragraph in group) {
          groupWidth += columnWidths[paragraph.column!];
        }
      }
      if (isTableRow && group.length > 1) {
        groupWidth += _tableColumnSpacing * (group.length - 1);
      }
      // An RTL table mirrors like an RTL paragraph: its columns flow
      // right-to-left, so the first source column sits at the row's right
      // edge. Only the row's placement follows the line direction.
      final columnsReversed =
          table != null && table.direction == TextDirection.rtl;
      final cellXs = <double>[];
      final cellTops = <double>[];
      final slotXs = <double>[];
      final slotWidths = <double>[];
      if (columnsReversed) {
        var right = groupWidth;
        for (final paragraph in group) {
          final padding = _cellPadding(table, paragraph);
          final slotWidth = columnWidths[paragraph.column!];
          right -= slotWidth;
          slotXs.add(right);
          slotWidths.add(slotWidth);
          cellXs.add(
            right +
                _tableAlignmentOffset(
                  slotWidth - padding.horizontal,
                  paragraph.painter.width,
                  paragraph.tableAlignment!,
                  table.direction,
                ),
          );
          cellXs[cellXs.length - 1] += padding.left;
          cellTops.add(padding.top);
          right -= _tableColumnSpacing;
        }
      } else {
        var x = 0.0;
        for (final paragraph in group) {
          final padding = table == null
              ? EdgeInsets.zero
              : _cellPadding(table, paragraph);
          final slotWidth = table == null
              ? paragraph.painter.width
              : columnWidths[paragraph.column!];
          if (table != null) {
            slotXs.add(x);
            slotWidths.add(slotWidth);
          }
          cellXs.add(
            x +
                (table == null
                    ? 0
                    : _tableAlignmentOffset(
                        slotWidth - padding.horizontal,
                        paragraph.painter.width,
                        paragraph.tableAlignment!,
                        table.direction,
                      )),
          );
          if (table != null) {
            cellXs[cellXs.length - 1] += padding.left;
            cellTops.add(padding.top);
          }
          x += slotWidth + _tableColumnSpacing;
        }
      }
      final rowDirection = isTableRow
          ? (lineDirections.isEmpty
                ? textDirection
                : index < lineDirections.length
                ? lineDirections[index]
                : lineDirections.last)
          : null;
      final rowOverflow = nextContentWidth - groupWidth;
      final double left;
      if (isTableRow) {
        left = rowDirection == TextDirection.rtl
            ? (rowOverflow > 0 ? rowOverflow : 0.0)
            : firstParagraph.startInset;
      } else {
        left = firstParagraph.direction == TextDirection.ltr
            ? firstParagraph.startInset
            : 0.0;
      }
      layouts.add(
        _MarkdownLineLayout(
          paragraphs: List.unmodifiable(group),
          top: top,
          height: height,
          left: left,
          alignment: firstParagraph.alignment,
          tableId: table?.id,
          cellXs: List.unmodifiable(cellXs),
          cellTops: List.unmodifiable(cellTops),
          slotXs: List.unmodifiable(slotXs),
          slotWidths: List.unmodifiable(slotWidths),
          computeLineMetrics: !isTableRow,
        ),
      );
      top += height;
      final row = table == null
          ? null
          : _rowsByVisualStart[firstParagraph.visualStart];
      if (table != null &&
          row != null &&
          row.row < table.rows.last.row &&
          tableStyle.borderModel == MarkdownTableBorderModel.separated) {
        top += tableStyle.rowSpacing;
      }
      index = end;
    }
    _layoutWidth = maxWidth;
    _contentWidth = nextContentWidth;
    _height = top;
    _lines = List.unmodifiable(layouts);
    final tableLines = <Object, List<_MarkdownLineLayout>>{};
    for (final line in _lines) {
      final id = line.tableId;
      if (id != null) (tableLines[id] ??= []).add(line);
    }
    _tableLines = {
      for (final entry in tableLines.entries)
        entry.key: List<_MarkdownLineLayout>.unmodifiable(entry.value),
    };
  }

  Rect caretRectForSourceOffset(
    int sourceOffset, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    _debugAssertLaidOut();
    final visualOffset = mapper.sourceToVisual(
      sourceOffset,
      affinity: affinity,
    );
    final line = _lineForVisualOffset(visualOffset, affinity: affinity);
    final cell = line.paragraphForVisualOffset(visualOffset);
    final localOffset = (visualOffset - cell.visualStart).clamp(
      0,
      cell.visualLength,
    );
    final caretOffset = cell.painter.getOffsetForCaret(
      TextPosition(offset: localOffset, affinity: affinity),
      Rect.fromLTWH(0, 0, cursorWidth, cell.painter.preferredLineHeight),
    );
    final cellX = line.xForParagraph(cell);
    final fallbackLeft = line.left + cellX + cell.logicalStartForEmptyParagraph;
    final unclampedLeft = line.visualLength == 0 || !caretOffset.dx.isFinite
        ? fallbackLeft
        : line.left + cellX + caretOffset.dx;
    final left = line.tableId == null
        ? unclampedLeft.clamp(0.0, _contentWidth)
        : unclampedLeft - tableScroll(line.tableId!);
    final effectiveCursorWidth = cursorWidth.clamp(0.0, _layoutWidth!);
    final (caretTop, caretHeight) = _caretGeometry(line, cell, visualOffset);
    return Rect.fromLTWH(
      left,
      line.top + line.yForParagraph(cell) + caretTop,
      effectiveCursorWidth,
      caretHeight,
    );
  }

  /// Matches the caret to the selection highlight: the tight glyph box of
  /// the character at the caret, exactly as selection boxes render. The
  /// caret is therefore as tall as selected text, never the full line box.
  (double, double) _caretGeometry(
    _MarkdownLineLayout line,
    _MarkdownParagraph cell,
    int visualOffset,
  ) {
    final localOffset = (visualOffset - cell.visualStart).clamp(
      0,
      cell.visualLength,
    );
    TextSelection charSelection;
    if (localOffset < cell.visualLength) {
      charSelection = TextSelection(
        baseOffset: localOffset,
        extentOffset: localOffset + 1,
      );
    } else if (localOffset > 0) {
      charSelection = TextSelection(
        baseOffset: localOffset - 1,
        extentOffset: localOffset,
      );
    } else {
      return (0, _lineBoxHeight(line, cell, 0));
    }
    final boxes = cell.painter.getBoxesForSelection(charSelection);
    if (boxes.isEmpty) return (0, _lineBoxHeight(line, cell, 0));
    final box = boxes.first.toRect();
    return (box.top, box.height);
  }

  /// Height of the visual line containing [localDy] inside [line]'s
  /// paragraph, used for empty lines where no glyph box exists. Flutter's
  /// `preferredLineHeight` reports the root style's height even when a child
  /// run (a heading) is much larger, so the real per-line metrics win.
  double _lineBoxHeight(
    _MarkdownLineLayout line,
    _MarkdownParagraph cell,
    double localDy,
  ) {
    final metrics = line.lineMetrics;
    if (metrics.isEmpty) return cell.painter.preferredLineHeight;
    var height = metrics.first.height;
    var cumulative = 0.0;
    for (final metric in metrics) {
      if (localDy < cumulative) break;
      height = metric.height;
      cumulative += metric.height;
    }
    return height;
  }

  TextPosition sourcePositionForOffset(Offset offset) {
    _debugAssertLaidOut();
    final line = _lineForY(offset.dy);
    final scroll = line.tableId == null ? 0.0 : tableScroll(line.tableId!);
    final cell = line.paragraphForLocalX(offset.dx + scroll - line.left);
    final local = cell.painter.getPositionForOffset(
      offset.translate(
        -(line.left + line.xForParagraph(cell)) + scroll,
        -(line.top + line.yForParagraph(cell)),
      ),
    );
    return TextPosition(
      offset: mapper.visualToSource(
        cell.visualStart + local.offset,
        affinity: local.affinity,
      ),
      affinity: local.affinity,
    );
  }

  InlineSpan? spanForOffset(Offset offset) {
    _debugAssertLaidOut();
    final line = _lineForY(offset.dy);
    final scroll = line.tableId == null ? 0.0 : tableScroll(line.tableId!);
    final cell = line.paragraphForLocalX(offset.dx + scroll - line.left);
    final position = cell.painter.getPositionForOffset(
      offset.translate(
        -(line.left + line.xForParagraph(cell)) + scroll,
        -(line.top + line.yForParagraph(cell)),
      ),
    );
    return cell.painter.text?.getSpanForPosition(position);
  }

  TextRange wordBoundaryForSourcePosition(TextPosition position) {
    _debugAssertLaidOut();
    final visualOffset = mapper.sourceToVisual(
      position.offset,
      affinity: position.affinity,
    );
    final line = _lineForVisualOffset(
      visualOffset,
      affinity: position.affinity,
    );
    final cell = line.paragraphForVisualOffset(visualOffset);
    final localOffset = (visualOffset - cell.visualStart).clamp(
      0,
      cell.visualLength,
    );
    final range = cell.painter.getWordBoundary(
      TextPosition(offset: localOffset, affinity: position.affinity),
    );
    return _sourceRangeForLocalRange(cell, range);
  }

  TextRange lineBoundaryForSourcePosition(TextPosition position) {
    _debugAssertLaidOut();
    final visualOffset = mapper.sourceToVisual(
      position.offset,
      affinity: position.affinity,
    );
    final line = _lineForVisualOffset(
      visualOffset,
      affinity: position.affinity,
    );
    if (line.paragraphs.length > 1) {
      // A table row is one hard line: the whole row is the line boundary.
      return TextRange(
        start: mapper.visualToSource(
          line.visualStart,
          affinity: TextAffinity.downstream,
        ),
        end: mapper.visualToSource(
          line.visualEnd,
          affinity: TextAffinity.upstream,
        ),
      );
    }
    final localOffset = (visualOffset - line.visualStart).clamp(
      0,
      line.visualLength,
    );
    final range = line.painter.getLineBoundary(
      TextPosition(offset: localOffset, affinity: position.affinity),
    );
    return _sourceRangeForLocalRange(line.paragraph, range);
  }

  List<TextBox> selectionBoxesForSourceRange(TextSelection selection) {
    _debugAssertLaidOut();
    final visualStart = mapper.sourceToVisual(
      selection.start,
      affinity: TextAffinity.downstream,
    );
    final visualEnd = mapper.sourceToVisual(
      selection.end,
      affinity: TextAffinity.upstream,
    );
    return selectionBoxesForVisualRange(
      TextRange(start: visualStart, end: visualEnd),
    );
  }

  List<TextBox> selectionBoxesForVisualRange(TextRange range) {
    _debugAssertLaidOut();
    final boxes = <TextBox>[];
    for (final line in _lines) {
      final scroll = line.tableId == null ? 0.0 : tableScroll(line.tableId!);
      for (final cell in line.paragraphs) {
        final start = range.start.clamp(cell.visualStart, cell.visualEnd);
        final end = range.end.clamp(cell.visualStart, cell.visualEnd);
        if (start >= end) continue;
        boxes.addAll(
          cell.painter
              .getBoxesForSelection(
                TextSelection(
                  baseOffset: start - cell.visualStart,
                  extentOffset: end - cell.visualStart,
                ),
              )
              .map(
                (box) => _translateBox(
                  box,
                  dx: line.left + line.xForParagraph(cell) - scroll,
                  dy: line.top + line.yForParagraph(cell),
                ),
              ),
        );
      }
    }
    return boxes;
  }

  /// Returns the full paragraph rectangles touched by a canonical source range.
  ///
  /// A paragraph rectangle includes all of its soft-wrapped visual lines.
  /// Adjacent hard-line rectangles are coalesced so continuous renderer-owned
  /// decorations do not acquire seams at source newlines.
  List<Rect> blockRectsForSourceRange(int sourceStart, {int? sourceEnd}) {
    _debugAssertLaidOut();
    final firstVisual = mapper.sourceToVisual(
      sourceStart,
      affinity: TextAffinity.downstream,
    );
    final firstIndex = _lineIndexForVisualOffset(
      firstVisual,
      affinity: TextAffinity.downstream,
    );
    var lastIndex = firstIndex;
    if (sourceEnd != null && sourceEnd > sourceStart) {
      final lastVisual = mapper.sourceToVisual(
        sourceEnd - 1,
        affinity: TextAffinity.downstream,
      );
      lastIndex = _lineIndexForVisualOffset(
        lastVisual,
        affinity: TextAffinity.downstream,
      );
      if (lastIndex < firstIndex) lastIndex = firstIndex;
    }
    final rects = <Rect>[];
    for (var index = firstIndex; index <= lastIndex; index++) {
      final line = _lines[index];
      final rect = Rect.fromLTWH(0, line.top, _contentWidth, line.height);
      if (rects.isNotEmpty &&
          rects.last.left == rect.left &&
          rects.last.right == rect.right &&
          rects.last.bottom == rect.top) {
        rects[rects.length - 1] = Rect.fromLTRB(
          rect.left,
          rects.last.top,
          rect.right,
          rect.bottom,
        );
      } else {
        rects.add(rect);
      }
    }
    return List.unmodifiable(rects);
  }

  List<({TextSpan span, TextRange range})> get recognizedSpans {
    final result = <({TextSpan span, TextRange range})>[];
    var offset = 0;
    void visit(InlineSpan span) {
      if (span is WidgetSpan) {
        offset += 1;
        return;
      }
      if (span is! TextSpan) return;
      final start = offset;
      offset += span.text?.length ?? 0;
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
      if (span.recognizer != null && offset > start) {
        result.add((span: span, range: TextRange(start: start, end: offset)));
      }
    }

    visit(text);
    return result;
  }

  void paint(Canvas canvas, Offset offset) {
    _debugAssertLaidOut();
    for (final line in _lines) {
      final tableId = line.tableId;
      if (tableId == null) {
        line.paint(canvas, offset);
        continue;
      }
      final scroll = tableScroll(tableId);
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(
          offset.dx,
          offset.dy + line.top,
          _contentWidth,
          line.height,
        ),
      );
      canvas.translate(-scroll, 0);
      line.paint(canvas, offset);
      canvas.restore();
    }
  }

  List<_MarkdownParagraph> _buildParagraphs() {
    final splitLines = _splitAtHardBreaks(text, placeholderDimensions);
    final paragraphs = <_MarkdownParagraph>[];
    for (var index = 0; index < splitLines.length; index++) {
      final split = splitLines[index];
      final row = _rowsByVisualStart[split.visualStart];
      if (row == null && _isHiddenTableSeparator(split)) continue;
      if (row == null) {
        paragraphs.add(_singleParagraph(split, index));
      } else {
        paragraphs.addAll(_cellParagraphs(split, row, index));
      }
    }
    return List.unmodifiable(paragraphs);
  }

  /// Visual start to end of every separator the styled table layout hides.
  ///
  /// A hidden separator spans at most one visual line, so the split line
  /// describing it starts exactly at its visual start.
  late final Map<int, int> _hiddenSeparatorVisualEnds = {
    for (final table in _tables)
      if (table.separatorVisualEnd - table.separatorVisualStart <= 1)
        table.separatorVisualStart: table.separatorVisualEnd,
  };

  bool _isHiddenTableSeparator(_SplitLine split) {
    if (!_usesStyledTableSlots) return false;
    final separatorEnd = _hiddenSeparatorVisualEnds[split.visualStart];
    return separatorEnd != null && split.visualEnd <= separatorEnd;
  }

  _MarkdownParagraph _singleParagraph(_SplitLine split, int lineIndex) {
    final direction = lineDirections.isEmpty
        ? textDirection
        : lineIndex < lineDirections.length
        ? lineDirections[lineIndex]
        : lineDirections.last;
    final alignment = _resolveLogicalAlignment(textAlign, direction);
    final painter = TextPainter(
      text: split.span,
      textDirection: direction,
      textAlign: alignment,
      textScaler: textScaler,
      strutStyle: strutStyle,
      locale: locale,
      textHeightBehavior: textHeightBehavior,
      textWidthBasis: textWidthBasis,
      maxLines: maxLines,
    )..setPlaceholderDimensions(split.placeholderDimensions);
    return _MarkdownParagraph(
      painter: painter,
      hasPlaceholders: split.placeholderDimensions.isNotEmpty,
      visualStart: split.visualStart,
      visualEnd: split.visualEnd,
      direction: direction,
      alignment: alignment,
      startInset: lineIndex < paragraphStartInsets.length
          ? paragraphStartInsets[lineIndex]
          : 0,
      lineIndex: lineIndex,
    );
  }

  /// First cell-style index of every table row, in table order.
  late final Map<int, int> _cellStyleStartByRowVisualStart = () {
    final starts = <int, int>{};
    var styleIndex = 0;
    for (final table in _tables) {
      for (final row in table.rows) {
        starts[row.visualStart] = styleIndex;
        styleIndex += row.cells.length;
      }
    }
    return starts;
  }();

  List<_MarkdownParagraph> _cellParagraphs(
    _SplitLine split,
    MarkdownProjectionTableRow row,
    int lineIndex,
  ) {
    final chunks = _splitAtVisualChunks(
      split.span,
      split.visualStart,
      row.cells,
      split.placeholderDimensions,
    );
    final styleIndex = _cellStyleStartByRowVisualStart[row.visualStart] ?? 0;
    return [
      for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++)
        _MarkdownParagraph(
          hasPlaceholders: chunks[chunkIndex].placeholderDimensions.isNotEmpty,
          painter: TextPainter(
            text: chunks[chunkIndex].span,
            textDirection: chunks[chunkIndex].direction,
            textAlign: _resolveLogicalAlignment(
              textAlign,
              chunks[chunkIndex].direction,
            ),
            textScaler: textScaler,
            strutStyle: strutStyle,
            locale: locale,
            textHeightBehavior: textHeightBehavior,
            textWidthBasis: textWidthBasis,
            maxLines: maxLines,
          )..setPlaceholderDimensions(chunks[chunkIndex].placeholderDimensions),
          visualStart: chunks[chunkIndex].start,
          visualEnd: chunks[chunkIndex].end,
          direction: chunks[chunkIndex].direction,
          alignment: _resolveLogicalAlignment(
            textAlign,
            chunks[chunkIndex].direction,
          ),
          startInset: 0,
          lineIndex: lineIndex,
          column: chunks[chunkIndex].column,
          tableAlignment: chunks[chunkIndex].alignment,
          tableCellIndex: styleIndex + chunkIndex,
        ),
    ];
  }

  TextRange _sourceRangeForLocalRange(
    _MarkdownParagraph cell,
    TextRange range,
  ) => TextRange(
    start: mapper.visualToSource(
      cell.visualStart + range.start,
      affinity: TextAffinity.downstream,
    ),
    end: mapper.visualToSource(
      cell.visualStart + range.end,
      affinity: TextAffinity.upstream,
    ),
  );

  _MarkdownLineLayout _lineForVisualOffset(
    int visualOffset, {
    required TextAffinity affinity,
  }) => _lines[_lineIndexForVisualOffset(visualOffset, affinity: affinity)];

  int _lineIndexForVisualOffset(
    int visualOffset, {
    required TextAffinity affinity,
  }) {
    final clamped = visualOffset.clamp(0, mapper.visualLength);
    for (var index = 0; index < _lines.length; index++) {
      final line = _lines[index];
      if (clamped < line.visualEnd) return index;
      if (clamped == line.visualEnd) {
        final next = index + 1 < _lines.length ? _lines[index + 1] : null;
        if (affinity == TextAffinity.downstream &&
            next != null &&
            next.visualStart == clamped) {
          return index + 1;
        }
        return index;
      }
      final nextStart = index + 1 < _lines.length
          ? _lines[index + 1].visualStart
          : mapper.visualLength + 1;
      if (clamped < nextStart) return index;
    }
    return _lines.length - 1;
  }

  _MarkdownLineLayout _lineForY(double y) {
    for (final line in _lines) {
      if (y < line.top + line.height) return line;
    }
    return _lines.last;
  }

  TextBox _translateBox(TextBox box, {double dx = 0, required double dy}) =>
      TextBox.fromLTRBD(
        box.left + dx,
        box.top + dy,
        box.right + dx,
        box.bottom + dy,
        box.direction,
      );

  void _debugAssertLaidOut() {
    assert(_layoutWidth != null, 'Call layout before reading text geometry.');
  }

  // ---- Table viewport -----------------------------------------------------

  double tableScroll(Object id) => _tableScroll[id] ?? 0;

  double tableWidth(Object id) {
    var max = 0.0;
    for (final line in _tableLines[id] ?? const <_MarkdownLineLayout>[]) {
      final width = _rowWidth(line);
      if (width > max) max = width;
    }
    return max;
  }

  double tableMaxScroll(Object id) =>
      math.max(0, tableWidth(id) - _contentWidth);

  /// Sets the horizontal scroll of [id]'s table, clamped to its extent.
  void setTableScroll(Object id, double value) {
    final clamped = value.clamp(0.0, tableMaxScroll(id));
    if ((_tableScroll[id] ?? 0) == clamped) return;
    _tableScroll[id] = clamped;
  }

  /// Adjusts the scroll so the viewport-space x is visible; returns whether
  /// the scroll changed.
  bool revealTableOffset(Object id, double x) {
    const padding = 20.0;
    final current = tableScroll(id);
    var target = current;
    if (x < padding) {
      target = current + x - padding;
    }
    if (x > _contentWidth - padding) {
      target = current + x - (_contentWidth - padding);
    }
    setTableScroll(id, target);
    return tableScroll(id) != current;
  }

  Set<Object> get tableIds => _tableLines.keys.toSet();

  /// The table owning the line at [offset], if any.
  Object? tableIdForOffset(Offset offset) {
    _debugAssertLaidOut();
    if (_lines.isEmpty) return null;
    return _lineForY(offset.dy).tableId;
  }

  /// Viewport-space rectangles of [id]'s rows (already translated by the
  /// table's scroll offset).
  List<Rect> tableRowRects(Object id) {
    final scroll = tableScroll(id);
    return List.unmodifiable([
      for (final line in _tableLines[id] ?? const <_MarkdownLineLayout>[])
        Rect.fromLTWH(
          line.left - scroll,
          line.top,
          _rowWidth(line),
          line.height,
        ),
    ]);
  }

  /// Viewport-space rectangles for [id]'s source-indexed table cells.
  ///
  /// The rectangles use the same slots as text painting, carets, selection,
  /// hit testing, and horizontal scrolling. Their returned order is parser
  /// row order followed by parser source-column order, even for RTL tables.
  List<Rect> tableCellRects(Object id) {
    _debugAssertLaidOut();
    final scroll = tableScroll(id);
    final result = <Rect>[];
    for (final line in _tableLines[id] ?? const <_MarkdownLineLayout>[]) {
      for (var index = 0; index < line.paragraphs.length; index++) {
        final left =
            line.left +
            (line.slotXs.isEmpty ? line.cellXs[index] : line.slotXs[index]) -
            scroll;
        final width = line.slotWidths.isEmpty
            ? line.paragraphs[index].painter.width
            : line.slotWidths[index];
        result.add(Rect.fromLTWH(left, line.top, width, line.height));
      }
    }
    return List.unmodifiable(result);
  }

  Rect? tableBounds(Object id) {
    final rects = tableRowRects(id);
    if (rects.isEmpty) return null;
    var rect = rects.first;
    for (final r in rects.skip(1)) {
      rect = rect.expandToInclude(r);
    }
    return rect;
  }

  double _rowWidth(_MarkdownLineLayout line) {
    if (line.slotXs.isNotEmpty) {
      var width = 0.0;
      for (var index = 0; index < line.slotXs.length; index++) {
        width = math.max(width, line.slotXs[index] + line.slotWidths[index]);
      }
      return width;
    }
    var width = 0.0;
    for (var index = 0; index < line.paragraphs.length; index++) {
      final cell = line.paragraphs[index];
      final right = line.cellXs.isEmpty
          ? cell.painter.width
          : line.cellXs[index] + cell.painter.width;
      if (right > width) width = right;
    }
    return width;
  }

  final Map<Object, double> _tableScroll = {};
}

TextAlign _resolveLogicalAlignment(
  TextAlign alignment,
  TextDirection direction,
) => switch (alignment) {
  TextAlign.start =>
    direction == TextDirection.rtl ? TextAlign.right : TextAlign.left,
  TextAlign.end =>
    direction == TextDirection.rtl ? TextAlign.left : TextAlign.right,
  TextAlign.left ||
  TextAlign.right ||
  TextAlign.center ||
  TextAlign.justify => alignment,
};

double _tableAlignmentOffset(
  double slotWidth,
  double contentWidth,
  MarkdownTableAlignment alignment,
  TextDirection tableDirection,
) {
  final remaining = math.max(0.0, slotWidth - contentWidth);
  return switch (alignment) {
    MarkdownTableAlignment.center => remaining / 2,
    MarkdownTableAlignment.start =>
      tableDirection == TextDirection.rtl ? remaining : 0,
    MarkdownTableAlignment.end =>
      tableDirection == TextDirection.rtl ? 0 : remaining,
  };
}

/// One visual hard line's geometry: visual start offset and band.
final class MarkdownLineRun {
  const MarkdownLineRun({
    required this.visualStart,
    required this.top,
    required this.height,
    this.tableId,
  });

  final int visualStart;
  final double top;
  final double height;
  final Object? tableId;
}

final class _MarkdownParagraph {
  const _MarkdownParagraph({
    required this.painter,
    required this.hasPlaceholders,
    required this.visualStart,
    required this.visualEnd,
    required this.direction,
    required this.alignment,
    required this.startInset,
    this.lineIndex = 0,
    this.column,
    this.tableAlignment,
    this.tableCellIndex,
  });

  final TextPainter painter;

  /// Whether [painter] owns inline placeholder boxes (task/media widgets).
  final bool hasPlaceholders;
  final int visualStart;
  final int visualEnd;
  final TextDirection direction;
  final TextAlign alignment;
  final double startInset;

  /// Index of the hard source line this paragraph belongs to.
  final int lineIndex;
  final int? column;
  final MarkdownTableAlignment? tableAlignment;
  final int? tableCellIndex;

  int get visualLength => visualEnd - visualStart;

  double get logicalStartForEmptyParagraph => switch (alignment) {
    TextAlign.right => painter.width,
    TextAlign.center => painter.width / 2,
    TextAlign.left || TextAlign.justify => 0,
    TextAlign.start || TextAlign.end => 0,
  };
}

final class _MarkdownLineLayout {
  _MarkdownLineLayout({
    required this.paragraphs,
    required this.top,
    required this.height,
    required this.left,
    required this.alignment,
    this.tableId,
    this.cellXs = const [],
    this.cellTops = const [],
    this.slotXs = const [],
    this.slotWidths = const [],
    required this.computeLineMetrics,
  });

  /// One paragraph per hard line, or one per cell for table rows.
  final List<_MarkdownParagraph> paragraphs;
  final double top;
  final double height;
  final double left;
  final TextAlign alignment;

  /// The table owning this row, when this is a table row.
  final Object? tableId;

  /// x offset of each paragraph within a table row. Left-to-right rows
  /// accumulate from the row's left edge; RTL rows from its right edge.
  final List<double> cellXs;
  final List<double> cellTops;
  final List<double> slotXs;
  final List<double> slotWidths;

  /// Whether [lineMetrics] can be derived from the paragraph painter.
  final bool computeLineMetrics;
  List<LineMetrics>? _lineMetrics;

  /// Per-visual-line metrics of the paragraph; empty when unavailable.
  ///
  /// Computed on first use because the engine call is only needed for the
  /// empty-line caret height.
  List<LineMetrics> get lineMetrics => _lineMetrics ??= computeLineMetrics
      ? paragraphs.first.painter.computeLineMetrics()
      : const <LineMetrics>[];

  _MarkdownParagraph get paragraph => paragraphs.first;
  TextPainter get painter => paragraph.painter;
  int get visualStart => paragraphs.first.visualStart;
  int get visualEnd => paragraphs.last.visualEnd;
  int get visualLength => visualEnd - visualStart;

  double get logicalStartForEmptyParagraph => switch (alignment) {
    TextAlign.right => painter.width,
    TextAlign.center => painter.width / 2,
    TextAlign.left || TextAlign.justify => 0,
    TextAlign.start || TextAlign.end => 0,
  };

  _MarkdownParagraph paragraphForVisualOffset(int visualOffset) {
    if (paragraphs.length == 1) return paragraph;
    for (final cell in paragraphs) {
      if (visualOffset < cell.visualEnd) return cell;
    }
    return paragraphs.last;
  }

  _MarkdownParagraph paragraphForLocalX(double localX) {
    if (paragraphs.length == 1) return paragraph;
    if (slotXs.isNotEmpty) {
      var nearestIndex = 0;
      var nearestDistance = double.infinity;
      for (var index = 0; index < paragraphs.length; index++) {
        final left = slotXs[index];
        final right = left + slotWidths[index];
        if (localX >= left && localX <= right) return paragraphs[index];
        final distance = localX < left ? left - localX : localX - right;
        if (distance < nearestDistance) {
          nearestIndex = index;
          nearestDistance = distance;
        }
      }
      return paragraphs[nearestIndex];
    }
    for (var index = 0; index < paragraphs.length; index++) {
      final cell = paragraphs[index];
      final x = cellXs.isEmpty ? 0.0 : cellXs[index];
      if (localX < x + cell.painter.width || index == paragraphs.length - 1) {
        return cell;
      }
    }
    return paragraphs.last;
  }

  double xForParagraph(_MarkdownParagraph cell) {
    if (cellXs.isEmpty) return 0;
    final index = paragraphs.indexOf(cell);
    if (index < 0 || index >= cellXs.length) return 0;
    return cellXs[index];
  }

  double yForParagraph(_MarkdownParagraph cell) {
    if (cellTops.isEmpty) return 0;
    final index = paragraphs.indexOf(cell);
    if (index < 0 || index >= cellTops.length) return 0;
    return cellTops[index];
  }

  void paint(Canvas canvas, Offset offset) {
    for (var index = 0; index < paragraphs.length; index++) {
      final cell = paragraphs[index];
      final x = cellXs.isEmpty ? 0.0 : cellXs[index];
      final y = cellTops.isEmpty ? 0.0 : cellTops[index];
      cell.painter.paint(canvas, offset.translate(left + x, top + y));
    }
  }
}

final class _SplitLine {
  const _SplitLine({
    required this.span,
    required this.visualStart,
    required this.visualEnd,
    required this.placeholderDimensions,
  });

  final TextSpan span;
  final int visualStart;
  final int visualEnd;
  final List<PlaceholderDimensions> placeholderDimensions;
}

final class _Chunk {
  const _Chunk({
    required this.span,
    required this.start,
    required this.end,
    required this.direction,
    required this.column,
    required this.alignment,
    required this.placeholderDimensions,
  });

  final TextSpan span;
  final int start;
  final int end;
  final TextDirection direction;
  final int column;
  final MarkdownTableAlignment alignment;
  final List<PlaceholderDimensions> placeholderDimensions;
}

/// Splits a table row's span at cell chunk boundaries, assigning every atom
/// (text run or padding widget) to the chunk whose `[chunkStart, chunkEnd)`
/// contains its visual offset. Text runs straddling a boundary are sliced.
List<_Chunk> _splitAtVisualChunks(
  TextSpan root,
  int baseVisualOffset,
  List<MarkdownProjectionTableCell> cells,
  List<PlaceholderDimensions> placeholderDimensions,
) {
  final chunks = <_Chunk>[];
  final children = <InlineSpan>[];
  final dims = <PlaceholderDimensions>[];
  var visualOffset = baseVisualOffset;
  var chunkIndex = 0;
  var placeholderIndex = 0;

  void finishChunk() {
    chunks.add(
      _Chunk(
        span: TextSpan(
          style: root.style,
          children: List.unmodifiable(children),
        ),
        start: cells[chunkIndex].chunkStart,
        end: cells[chunkIndex].chunkEnd,
        direction: cells[chunkIndex].direction,
        column: cells[chunkIndex].column,
        alignment: cells[chunkIndex].alignment,
        placeholderDimensions: List.unmodifiable(dims),
      ),
    );
    children.clear();
    dims.clear();
    chunkIndex++;
  }

  void pushText(TextSpan original, String value, TextStyle? style) {
    var start = 0;
    while (start < value.length) {
      while (chunkIndex < cells.length &&
          visualOffset >= cells[chunkIndex].chunkEnd) {
        finishChunk();
      }
      if (chunkIndex >= cells.length) return;
      final space = cells[chunkIndex].chunkEnd - visualOffset;
      if (space <= 0) {
        finishChunk();
        continue;
      }
      final take = math.min(space, value.length - start);
      if (take > 0) {
        children.add(
          TextSpan(
            text: value.substring(start, start + take),
            style: style,
            recognizer: original.recognizer,
            mouseCursor: original.mouseCursor,
            onEnter: original.onEnter,
            onExit: original.onExit,
            semanticsLabel: original.semanticsLabel,
            locale: original.locale,
            spellOut: original.spellOut,
          ),
        );
        visualOffset += take;
        start += take;
      }
      if (visualOffset >= cells[chunkIndex].chunkEnd) finishChunk();
    }
  }

  void pushWidget(WidgetSpan span, TextStyle? style) {
    while (chunkIndex < cells.length &&
        visualOffset >= cells[chunkIndex].chunkEnd) {
      finishChunk();
    }
    if (chunkIndex >= cells.length) return;
    children.add(
      WidgetSpan(
        child: span.child,
        alignment: span.alignment,
        baseline: span.baseline,
        style: style,
      ),
    );
    if (placeholderIndex < placeholderDimensions.length) {
      dims.add(placeholderDimensions[placeholderIndex]);
    }
    placeholderIndex++;
    visualOffset += 1;
    if (visualOffset >= cells[chunkIndex].chunkEnd) finishChunk();
  }

  void visit(InlineSpan span, TextStyle? inheritedStyle) {
    final effectiveStyle = inheritedStyle == null
        ? span.style
        : inheritedStyle.merge(span.style);
    if (span is WidgetSpan) {
      pushWidget(span, effectiveStyle);
      return;
    }
    if (span is! TextSpan) return;
    if (span.text case final value?) pushText(span, value, effectiveStyle);
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, effectiveStyle);
    }
  }

  visit(root, null);
  while (chunkIndex < cells.length) {
    finishChunk();
  }
  return List.unmodifiable(chunks);
}

List<_SplitLine> _splitAtHardBreaks(
  TextSpan root,
  List<PlaceholderDimensions> placeholderDimensions,
) {
  final lines = <_SplitLine>[];
  var children = <InlineSpan>[];
  var dimensions = <PlaceholderDimensions>[];
  var lineStart = 0;
  var visualOffset = 0;
  var placeholderIndex = 0;

  void finishLine() {
    lines.add(
      _SplitLine(
        span: TextSpan(style: root.style, children: children),
        visualStart: lineStart,
        visualEnd: visualOffset,
        placeholderDimensions: List.unmodifiable(dimensions),
      ),
    );
    children = <InlineSpan>[];
    dimensions = <PlaceholderDimensions>[];
  }

  void addText(TextSpan original, String value, TextStyle? style) {
    var start = 0;
    while (true) {
      final newline = value.indexOf('\n', start);
      final end = newline < 0 ? value.length : newline;
      if (start < end) {
        children.add(
          TextSpan(
            text: value.substring(start, end),
            style: style,
            recognizer: original.recognizer,
            mouseCursor: original.mouseCursor,
            onEnter: original.onEnter,
            onExit: original.onExit,
            semanticsLabel: original.semanticsLabel,
            locale: original.locale,
            spellOut: original.spellOut,
          ),
        );
        visualOffset += end - start;
      }
      if (newline < 0) return;
      finishLine();
      visualOffset += 1;
      lineStart = visualOffset;
      start = newline + 1;
    }
  }

  void visit(InlineSpan span, TextStyle? inheritedStyle) {
    final effectiveStyle = inheritedStyle == null
        ? span.style
        : inheritedStyle.merge(span.style);
    if (span is WidgetSpan) {
      children.add(
        WidgetSpan(
          child: span.child,
          alignment: span.alignment,
          baseline: span.baseline,
          style: effectiveStyle,
        ),
      );
      if (placeholderIndex < placeholderDimensions.length) {
        dimensions.add(placeholderDimensions[placeholderIndex]);
      }
      placeholderIndex += 1;
      visualOffset += 1;
      return;
    }
    if (span is! TextSpan) return;
    if (span.text case final value?) addText(span, value, effectiveStyle);
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child, effectiveStyle);
    }
  }

  visit(root, null);
  finishLine();
  return List.unmodifiable(lines);
}
