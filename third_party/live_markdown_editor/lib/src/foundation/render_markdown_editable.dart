// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../theme/markdown_table_style.dart';
import 'markdown_gutter.dart';
import 'markdown_line_index.dart';
import 'markdown_editable_layout.dart';
import 'markdown_source_position_mapper.dart';
import 'markdown_table_border_geometry.dart';
import 'markdown_text_projection.dart';

enum MarkdownBlockDecorationKind { blockquote, horizontalRule, extension }

final class MarkdownBlockDecoration {
  const MarkdownBlockDecoration({
    required this.kind,
    required this.sourceOffset,
    required this.color,
    this.sourceEnd,
    this.textDirection = TextDirection.ltr,
    this.thickness = 1,
    this.radius = Radius.zero,
    this.backgroundColor,
    this.nestingLevel = 1,
    this.padding = 12,
  }) : assert(sourceEnd == null || sourceEnd >= sourceOffset),
       assert(thickness >= 0),
       assert(nestingLevel > 0),
       assert(padding >= 0);

  final MarkdownBlockDecorationKind kind;
  final int sourceOffset;

  /// Exclusive source end for a decoration spanning multiple hard lines.
  ///
  /// When omitted, the decoration owns the paragraph containing
  /// [sourceOffset], including all of that paragraph's soft wraps.
  final int? sourceEnd;
  final Color color;
  final TextDirection textDirection;
  final double thickness;
  final Radius radius;
  final Color? backgroundColor;

  /// One-based logical nesting level for blockquote geometry.
  final int nestingLevel;

  /// Logical-start space reserved for each blockquote nesting level.
  final double padding;
}

/// Render-object widget for projected editable text geometry and painting.
final class MarkdownEditableRenderWidget extends MultiChildRenderObjectWidget {
  const MarkdownEditableRenderWidget({
    required this.text,
    required this.mapper,
    required this.textDirection,
    required this.selection,
    required this.cursorColor,
    required this.selectionColor,
    required this.showCursor,
    this.cursorWidth = 1,
    required this.sourceText,
    required this.readOnly,
    required this.focused,
    this.onTap,
    this.onSelectionChanged,
    this.onCopy,
    this.onCut,
    this.onPaste,
    this.onHoverInteractiveChanged,
    List<Widget> inlineChildren = const [],
    this.textAlign = TextAlign.start,
    this.textScaler = TextScaler.noScaling,
    this.strutStyle,
    this.locale,
    this.textHeightBehavior,
    this.textWidthBasis = TextWidthBasis.parent,
    this.maxLines,
    this.blockDecorations = const [],
    this.lineDirections = const [],
    this.tables = const [],
    this.tableStyle = const MarkdownTableStyle(),
    this.tableCellStyles = const [],
    this.mode = MarkdownEditorMode.raw,
    this.gutter = const MarkdownGutterConfiguration(),
    this.gutterStyle = const MarkdownGutterStyle(),
    this.foldableStarts = const [],
    this.foldedStarts = const {},
    this.onToggleFold,
    super.key,
  }) : super(children: inlineChildren);

  final TextSpan text;
  final MarkdownSourcePositionMapper mapper;
  final TextDirection textDirection;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final StrutStyle? strutStyle;
  final Locale? locale;
  final TextHeightBehavior? textHeightBehavior;
  final TextWidthBasis textWidthBasis;
  final int? maxLines;
  final List<MarkdownBlockDecoration> blockDecorations;
  final List<TextDirection> lineDirections;
  final List<MarkdownProjectionTable> tables;
  final MarkdownTableStyle tableStyle;
  final List<MarkdownTableCellStyle?> tableCellStyles;
  final MarkdownEditorMode mode;
  final MarkdownGutterConfiguration gutter;
  final MarkdownGutterStyle gutterStyle;
  final List<int> foldableStarts;
  final Set<int> foldedStarts;
  final ValueChanged<int>? onToggleFold;
  final TextSelection selection;
  final Color cursorColor;
  final Color selectionColor;
  final bool showCursor;
  final double cursorWidth;
  final String sourceText;
  final bool readOnly;
  final bool focused;
  final VoidCallback? onTap;
  final ValueChanged<TextSelection>? onSelectionChanged;
  final VoidCallback? onCopy;
  final VoidCallback? onCut;
  final VoidCallback? onPaste;
  final ValueChanged<bool>? onHoverInteractiveChanged;

  @override
  RenderMarkdownEditable createRenderObject(BuildContext context) =>
      RenderMarkdownEditable(
        text: text,
        mapper: mapper,
        textDirection: textDirection,
        textAlign: textAlign,
        textScaler: textScaler,
        strutStyle: strutStyle,
        locale: locale,
        textHeightBehavior: textHeightBehavior,
        textWidthBasis: textWidthBasis,
        maxLines: maxLines,
        blockDecorations: blockDecorations,
        lineDirections: lineDirections,
        tables: tables,
        tableStyle: tableStyle,
        tableCellStyles: tableCellStyles,
        mode: mode,
        gutter: gutter,
        gutterStyle: gutterStyle,
        foldableStarts: foldableStarts,
        foldedStarts: foldedStarts,
        onToggleFold: onToggleFold,
        selection: selection,
        cursorColor: cursorColor,
        selectionColor: selectionColor,
        showCursor: showCursor,
        cursorWidth: cursorWidth,
        sourceText: sourceText,
        readOnly: readOnly,
        focused: focused,
        onTap: onTap,
        onSelectionChanged: onSelectionChanged,
        onCopy: onCopy,
        onCut: onCut,
        onPaste: onPaste,
        onHoverInteractiveChanged: onHoverInteractiveChanged,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderMarkdownEditable renderObject,
  ) {
    renderObject
      ..text = text
      ..mapper = mapper
      ..textDirection = textDirection
      ..textAlign = textAlign
      ..textScaler = textScaler
      ..strutStyle = strutStyle
      ..locale = locale
      ..textHeightBehavior = textHeightBehavior
      ..textWidthBasis = textWidthBasis
      ..maxLines = maxLines
      ..blockDecorations = blockDecorations
      ..lineDirections = lineDirections
      ..tables = tables
      ..tableStyle = tableStyle
      ..tableCellStyles = tableCellStyles
      ..mode = mode
      ..gutter = gutter
      ..gutterStyle = gutterStyle
      ..foldableStarts = foldableStarts
      ..foldedStarts = foldedStarts
      ..onToggleFold = onToggleFold
      ..selection = selection
      ..cursorColor = cursorColor
      ..selectionColor = selectionColor
      ..showCursor = showCursor
      ..cursorWidth = cursorWidth;
    renderObject
      ..sourceText = sourceText
      ..readOnly = readOnly
      ..focused = focused
      ..onTap = onTap
      ..onSelectionChanged = onSelectionChanged
      ..onCopy = onCopy
      ..onCut = onCut
      ..onPaste = onPaste
      ..onHoverInteractiveChanged = onHoverInteractiveChanged;
  }
}

/// Paints projected text, its selection, and its caret from source offsets.
final class MarkdownEditableParentData
    extends ContainerBoxParentData<RenderBox> {}

final class RenderMarkdownEditable extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MarkdownEditableParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MarkdownEditableParentData> {
  RenderMarkdownEditable({
    required TextSpan text,
    required MarkdownSourcePositionMapper mapper,
    required TextDirection textDirection,
    required TextAlign textAlign,
    required TextScaler textScaler,
    required StrutStyle? strutStyle,
    required Locale? locale,
    required TextHeightBehavior? textHeightBehavior,
    required TextWidthBasis textWidthBasis,
    required int? maxLines,
    required List<MarkdownBlockDecoration> blockDecorations,
    required List<TextDirection> lineDirections,
    required List<MarkdownProjectionTable> tables,
    required MarkdownTableStyle tableStyle,
    List<MarkdownTableCellStyle?> tableCellStyles = const [],
    required MarkdownEditorMode mode,
    MarkdownGutterConfiguration gutter = const MarkdownGutterConfiguration(),
    MarkdownGutterStyle gutterStyle = const MarkdownGutterStyle(),
    List<int> foldableStarts = const [],
    Set<int> foldedStarts = const {},
    ValueChanged<int>? onToggleFold,
    required TextSelection selection,
    required Color cursorColor,
    required Color selectionColor,
    required bool showCursor,
    double cursorWidth = 1,
    required String sourceText,
    required bool readOnly,
    required bool focused,
    VoidCallback? onTap,
    ValueChanged<TextSelection>? onSelectionChanged,
    VoidCallback? onCopy,
    VoidCallback? onCut,
    VoidCallback? onPaste,
    ValueChanged<bool>? onHoverInteractiveChanged,
  }) : assert(cursorWidth >= 0),
       _gutter = gutter,
       _gutterStyle = gutterStyle,
       _foldableStarts = List.unmodifiable(foldableStarts),
       _foldedStarts = Set.unmodifiable(foldedStarts),
       onToggleFold = onToggleFold,
       _text = text,
       _mapper = mapper,
       _textDirection = textDirection,
       _textAlign = textAlign,
       _textScaler = textScaler,
       _strutStyle = strutStyle,
       _locale = locale,
       _textHeightBehavior = textHeightBehavior,
       _textWidthBasis = textWidthBasis,
       _maxLines = maxLines,
       _blockDecorations = List.unmodifiable(blockDecorations),
       _lineDirections = List.unmodifiable(lineDirections),
       _tables = List.unmodifiable(tables),
       _tableStyle = tableStyle,
       _providedTableCellStyles = List.unmodifiable(tableCellStyles),
       _mode = mode,
       _selection = selection,
       _cursorColor = cursorColor,
       _selectionColor = selectionColor,
       _showCursor = showCursor,
       _cursorWidth = cursorWidth,
       _sourceText = sourceText,
       _readOnly = readOnly,
       _focused = focused,
       _onTap = onTap,
       _onSelectionChanged = onSelectionChanged,
       _onCopy = onCopy,
       _onCut = onCut,
       _onPaste = onPaste,
       onHoverInteractiveChanged = onHoverInteractiveChanged;

  TextSpan _text;
  MarkdownSourcePositionMapper _mapper;
  TextDirection _textDirection;
  TextAlign _textAlign;
  TextScaler _textScaler;
  StrutStyle? _strutStyle;
  Locale? _locale;
  TextHeightBehavior? _textHeightBehavior;
  TextWidthBasis _textWidthBasis;
  int? _maxLines;
  List<MarkdownBlockDecoration> _blockDecorations;
  List<TextDirection> _lineDirections;
  List<MarkdownProjectionTable> _tables;
  MarkdownTableStyle _tableStyle;
  List<MarkdownTableCellStyle?> _providedTableCellStyles;
  MarkdownEditorMode _mode;
  bool _tableStyleContextsDirty = true;
  List<MarkdownTableCellStyle?> _resolvedTableCellStyles = const [];

  @visibleForTesting
  List<MarkdownTableCellStyle?> get debugResolvedTableCellStyles =>
      _resolvedTableCellStyles;

  /// The current hover scrollbar thumb in render-local coordinates.
  @visibleForTesting
  Rect? get debugTableScrollbarThumbRect => _tableScrollbarThumbRect();

  MarkdownTableStyle get tableStyle => _tableStyle;
  set tableStyle(MarkdownTableStyle value) {
    if (value == _tableStyle) return;
    _tableStyle = value;
    _tableStyleContextsDirty = true;
    _markNeedsTextLayout();
  }

  List<MarkdownTableCellStyle?> get tableCellStyles => _providedTableCellStyles;
  set tableCellStyles(List<MarkdownTableCellStyle?> value) {
    if (listEquals(value, _providedTableCellStyles)) return;
    _providedTableCellStyles = List.unmodifiable(value);
    _tableStyleContextsDirty = true;
    _markNeedsTextLayout();
  }

  MarkdownEditorMode get mode => _mode;
  set mode(MarkdownEditorMode value) {
    if (value == _mode) return;
    _mode = value;
    _tableStyleContextsDirty = true;
    _markNeedsTextLayout();
  }

  TextSelection _selection;
  Color _cursorColor;
  Color _selectionColor;
  bool _showCursor;
  double _cursorWidth;
  String _sourceText;
  bool _readOnly;
  bool _focused;
  VoidCallback? _onTap;
  ValueChanged<TextSelection>? _onSelectionChanged;
  VoidCallback? _onCopy;
  VoidCallback? _onCut;
  VoidCallback? _onPaste;
  MarkdownEditableLayout? _layout;
  bool _layoutDirty = true;
  double? _cachedLayoutWidth;
  List<Size> _cachedPlaceholderSizes = const [];
  List<_PaintedBlockDecoration> _paintedBlockDecorations = const [];

  List<MarkdownBlockDecoration> get blockDecorations => _blockDecorations;
  set blockDecorations(List<MarkdownBlockDecoration> value) {
    if (listEquals(value, _blockDecorations)) return;
    _blockDecorations = List.unmodifiable(value);
    _markNeedsTextLayout();
  }

  List<TextDirection> get lineDirections => _lineDirections;
  set lineDirections(List<TextDirection> value) {
    if (listEquals(value, _lineDirections)) return;
    _lineDirections = List.unmodifiable(value);
    _markNeedsTextLayout();
  }

  List<MarkdownProjectionTable> get tables => _tables;
  set tables(List<MarkdownProjectionTable> value) {
    if (listEquals(value, _tables)) return;
    _tables = List.unmodifiable(value);
    _tableStyleContextsDirty = true;
    _markNeedsTextLayout();
  }

  void _resolveTableCellStyles() {
    if (!_tableStyleContextsDirty) return;
    final resolver = _tableStyle.cellStyleResolver;
    _resolvedTableCellStyles = _providedTableCellStyles.isNotEmpty
        ? _providedTableCellStyles
        : resolver == null
        ? const []
        : List.unmodifiable([
            for (final table in _tables)
              for (final row in table.rows)
                for (final cell in row.cells)
                  resolver(
                    MarkdownTableCellStyleContext(
                      mode: _mode,
                      row: row.row,
                      column: cell.column,
                      isHeader: row.row == 0,
                      isOddBodyRow: row.row > 0 && row.row.isOdd,
                      tableDirection: table.direction,
                      cellDirection: cell.direction,
                    ),
                  ),
          ]);
    _tableStyleContextsDirty = false;
  }

  TextSpan get text => _text;
  set text(TextSpan value) {
    if (value == _text) return;
    _text = value;
    _markNeedsTextLayout();
  }

  MarkdownSourcePositionMapper get mapper => _mapper;
  set mapper(MarkdownSourcePositionMapper value) {
    if (identical(value, _mapper)) return;
    _mapper = value;
    _markNeedsTextLayout();
  }

  TextDirection get textDirection => _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    _markNeedsTextLayout();
  }

  TextAlign get textAlign => _textAlign;
  set textAlign(TextAlign value) {
    if (value == _textAlign) return;
    _textAlign = value;
    _markNeedsTextLayout();
  }

  TextScaler get textScaler => _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _markNeedsTextLayout();
  }

  StrutStyle? get strutStyle => _strutStyle;
  set strutStyle(StrutStyle? value) {
    if (value == _strutStyle) return;
    _strutStyle = value;
    _markNeedsTextLayout();
  }

  Locale? get locale => _locale;
  set locale(Locale? value) {
    if (value == _locale) return;
    _locale = value;
    _markNeedsTextLayout();
  }

  TextHeightBehavior? get textHeightBehavior => _textHeightBehavior;
  set textHeightBehavior(TextHeightBehavior? value) {
    if (value == _textHeightBehavior) return;
    _textHeightBehavior = value;
    _markNeedsTextLayout();
  }

  TextWidthBasis get textWidthBasis => _textWidthBasis;
  set textWidthBasis(TextWidthBasis value) {
    if (value == _textWidthBasis) return;
    _textWidthBasis = value;
    _markNeedsTextLayout();
  }

  int? get maxLines => _maxLines;
  set maxLines(int? value) {
    if (value == _maxLines) return;
    _maxLines = value;
    _markNeedsTextLayout();
  }

  TextSelection get selection => _selection;
  set selection(TextSelection value) {
    if (value == _selection) return;
    _selection = value;
    markNeedsPaint();
  }

  Color get cursorColor => _cursorColor;
  set cursorColor(Color value) {
    if (value == _cursorColor) return;
    _cursorColor = value;
    markNeedsPaint();
  }

  Color get selectionColor => _selectionColor;
  set selectionColor(Color value) {
    if (value == _selectionColor) return;
    _selectionColor = value;
    markNeedsPaint();
  }

  bool get showCursor => _showCursor;
  set showCursor(bool value) {
    if (value == _showCursor) return;
    _showCursor = value;
    markNeedsPaint();
  }

  double get cursorWidth => _cursorWidth;
  set cursorWidth(double value) {
    assert(value >= 0);
    if (value == _cursorWidth) return;
    _cursorWidth = value;
    _markNeedsTextLayout();
  }

  String get sourceText => _sourceText;
  set sourceText(String value) {
    if (value == _sourceText) return;
    _sourceText = value;
    _markNeedsTextLayout();
    markNeedsSemanticsUpdate();
  }

  bool get readOnly => _readOnly;
  set readOnly(bool value) {
    if (value == _readOnly) return;
    _readOnly = value;
    markNeedsSemanticsUpdate();
  }

  bool get focused => _focused;
  set focused(bool value) {
    if (value == _focused) return;
    _focused = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback? get onTap => _onTap;
  set onTap(VoidCallback? value) {
    if (value == _onTap) return;
    _onTap = value;
    markNeedsSemanticsUpdate();
  }

  ValueChanged<TextSelection>? get onSelectionChanged => _onSelectionChanged;
  set onSelectionChanged(ValueChanged<TextSelection>? value) {
    if (value == _onSelectionChanged) return;
    _onSelectionChanged = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback? get onCopy => _onCopy;
  set onCopy(VoidCallback? value) {
    if (value == _onCopy) return;
    _onCopy = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback? get onCut => _onCut;
  set onCut(VoidCallback? value) {
    if (value == _onCut) return;
    _onCut = value;
    markNeedsSemanticsUpdate();
  }

  VoidCallback? get onPaste => _onPaste;
  set onPaste(VoidCallback? value) {
    if (value == _onPaste) return;
    _onPaste = value;
    markNeedsSemanticsUpdate();
  }

  MarkdownGutterConfiguration _gutter = const MarkdownGutterConfiguration();
  MarkdownGutterStyle _gutterStyle = const MarkdownGutterStyle();
  double _gutterWidth = 0;
  double _contentLeft = 0;
  double? _cachedGutterWidth;

  /// Gutter feature switches; changing them re-lays out the surface.
  MarkdownGutterConfiguration get gutter => _gutter;
  set gutter(MarkdownGutterConfiguration value) {
    if (value == _gutter) return;
    _gutter = value;
    _markNeedsTextLayout();
  }

  /// Gutter visual tokens; changing them re-lays out the surface.
  MarkdownGutterStyle get gutterStyle => _gutterStyle;
  set gutterStyle(MarkdownGutterStyle value) {
    if (value == _gutterStyle) return;
    _gutterStyle = value;
    _markNeedsTextLayout();
  }

  /// Horizontal offset of the projected content (past the gutter).
  Offset get _contentOrigin => Offset(_contentLeft, 0);

  /// Width the gutter currently reserves (0 when disabled).
  double get gutterWidth => _gutterWidth;

  List<int> _foldableStarts;
  Set<int> _foldedStarts;
  int? _hoveredGutterStart;

  /// Called when a gutter tap activates a fold affordance.
  ValueChanged<int>? onToggleFold;

  /// Source offsets where a foldable block starts (gutter chevrons).
  List<int> get foldableStarts => _foldableStarts;
  set foldableStarts(List<int> value) {
    if (listEquals(value, _foldableStarts)) return;
    _foldableStarts = List.unmodifiable(value);
    markNeedsPaint();
  }

  /// Source offsets whose blocks are currently folded.
  Set<int> get foldedStarts => _foldedStarts;
  set foldedStarts(Set<int> value) {
    if (setEquals(value, _foldedStarts)) return;
    _foldedStarts = Set.unmodifiable(value);
    markNeedsPaint();
  }

  Offset? _lastGutterHoverGlobal;

  /// Re-evaluates the hovered fold row after the content moved under a
  /// stationary pointer (scrolling), so the chevron never keeps a stale line.
  ///
  /// The pointer's global position is re-projected because scrolling changes
  /// which content sits under it without producing pointer events.
  void refreshGutterHover() {
    final global = _lastGutterHoverGlobal;
    if (global == null || !hasSize) return;
    _updateHoveredGutter(globalToLocal(global));
  }

  /// Fold affordance currently under the pointer, if any.
  @visibleForTesting
  int? get debugHoveredFoldStart => _hoveredGutterStart;

  /// Tracks the fold affordance under the pointer.
  void _updateHoveredGutter(Offset? position) {
    _lastGutterHoverGlobal = position == null || !hasSize
        ? null
        : localToGlobal(position);
    final layout = _layout;
    if (position == null || layout == null || !_gutter.folding) {
      if (_hoveredGutterStart == null) return;
      _hoveredGutterStart = null;
      markNeedsPaint();
      return;
    }
    final local = position - _contentOrigin;
    final onGutterSide = _textDirection == TextDirection.rtl
        ? local.dx >= layout.size.width - _gutterWidth
        : local.dx <= 0;
    final next = onGutterSide ? _foldStartAtGutterOffset(local) : null;
    if (next == _hoveredGutterStart) return;
    _hoveredGutterStart = next;
    markNeedsPaint();
  }

  /// Foldable block start whose gutter row contains [local] (content space).
  int? _foldStartAtGutterOffset(Offset local) {
    final layout = _layout;
    if (layout == null) return null;
    final lineStarts = markdownLineStarts(_sourceText);
    for (final run in layout.lineRuns) {
      if (local.dy < run.top || local.dy >= run.top + run.height) continue;
      final sourceOffset = _mapper.visualToSource(
        run.visualStart,
        affinity: TextAffinity.downstream,
      );
      final lineIndex = markdownLineIndexFor(lineStarts, sourceOffset);
      final lineStart = lineStarts[lineIndex];
      return _foldableStarts.contains(lineStart) ? lineStart : null;
    }
    return null;
  }

  /// Foldable block start for a gutter tap at [local] (render space).
  int? foldStartForGutterOffset(Offset local) =>
      _foldStartAtGutterOffset(local - _contentOrigin);

  Rect caretRectForSourceOffset(
    int sourceOffset, {
    TextAffinity affinity = TextAffinity.downstream,
  }) => _layout!
      .caretRectForSourceOffset(sourceOffset, affinity: affinity)
      .shift(_contentOrigin);

  /// Renderer-owned geometry for a block decoration.
  List<Rect> blockRectsForDecoration(MarkdownBlockDecoration decoration) {
    final rects = _layout!.blockRectsForSourceRange(
      decoration.sourceOffset,
      sourceEnd: decoration.sourceEnd,
    );
    final shifted = [for (final rect in rects) rect.shift(_contentOrigin)];
    if (decoration.kind != MarkdownBlockDecorationKind.blockquote) {
      return List.unmodifiable(shifted);
    }
    return List.unmodifiable([
      for (final rect in shifted) _insetRectForBlockquote(rect, decoration),
    ]);
  }

  double get preferredLineHeight => _layout!.preferredLineHeight;

  List<TextBox> selectionBoxesForSourceRange(TextSelection selection) {
    final origin = _contentOrigin;
    if (origin == Offset.zero) {
      return _layout!.selectionBoxesForSourceRange(selection);
    }
    return List.unmodifiable([
      for (final box in _layout!.selectionBoxesForSourceRange(selection))
        TextBox.fromLTRBD(
          box.left + origin.dx,
          box.top + origin.dy,
          box.right + origin.dx,
          box.bottom + origin.dy,
          box.direction,
        ),
    ]);
  }

  void _markNeedsTextLayout() {
    _layoutDirty = true;
    markNeedsLayout();
  }

  Rect getLocalRectForCaret(TextPosition position) =>
      caretRectForSourceOffset(position.offset, affinity: position.affinity);

  // ---- Table viewport -----------------------------------------------------

  final Map<Object, double> _tableScrollOffsets = {};

  double tableScroll(Object id) => _layout?.tableScroll(id) ?? 0;

  void setTableScroll(Object id, double value) {
    _tableScrollOffsets[id] = value;
    _layout?.setTableScroll(id, value);
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  void revealTable(Object id, double x) {
    final layout = _layout;
    if (layout == null) return;
    if (layout.revealTableOffset(id, x - _contentLeft)) {
      _tableScrollOffsets[id] = layout.tableScroll(id);
      markNeedsPaint();
      markNeedsSemanticsUpdate();
    }
  }

  Object? tableIdForOffset(Offset local) =>
      _layout?.tableIdForOffset(local - _contentOrigin);

  Rect? tableBounds(Object id) => _layout?.tableBounds(id);

  /// Returns the hovered table whose horizontal scrollbar thumb contains
  /// [local], if any.
  Object? tableScrollbarIdForOffset(Offset local) {
    final id = _hoveredTableId;
    final thumb = _tableScrollbarThumbRect();
    return id != null && thumb != null && thumb.contains(local) ? id : null;
  }

  /// Moves a table scrollbar thumb by [pointerDelta] logical pixels.
  void dragTableScrollbar(Object id, double pointerDelta) {
    final layout = _layout;
    final track = _tableScrollbarTrackRectFor(id);
    final thumb = _tableScrollbarThumbRectFor(id);
    if (layout == null || track == null || thumb == null) return;
    final travel = track.width - thumb.width;
    final maxScroll = layout.tableMaxScroll(id);
    if (travel <= 0 || maxScroll <= 0) return;
    setTableScroll(id, tableScroll(id) + pointerDelta * maxScroll / travel);
  }

  void clearTableHover() => _updateHoveredTable(null);

  void _applyTableScrolls() {
    for (final entry in _tableScrollOffsets.entries) {
      _layout?.setTableScroll(entry.key, entry.value);
    }
  }

  TextPosition sourcePositionForOffset(Offset offset) =>
      _layout!.sourcePositionForOffset(offset - _contentOrigin);

  TextRange wordBoundaryForSourcePosition(TextPosition position) =>
      _layout!.wordBoundaryForSourcePosition(position);

  TextRange lineBoundaryForSourcePosition(TextPosition position) =>
      _layout!.lineBoundaryForSourcePosition(position);

  @override
  bool hitTestSelf(Offset position) => true;

  /// Reports when the pointer hovers over an interactive part (a link span
  /// with an active tap recognizer, or an inline widget such as a task
  /// toggle) so the owning surface can present the click cursor there.
  ValueChanged<bool>? onHoverInteractiveChanged;

  bool _hoveringInteractive = false;
  Object? _hoveredTableId;

  void _updateHoveredTable(Offset? position) {
    final layout = _layout;
    var next = position == null || layout == null
        ? null
        : layout.tableIdForOffset(position - _contentOrigin);
    if (next != null && layout!.tableMaxScroll(next) <= 0) next = null;
    if (next == _hoveredTableId) return;
    _hoveredTableId = next;
    markNeedsPaint();
  }

  Rect? _tableScrollbarTrackRect() {
    final id = _hoveredTableId;
    return id == null ? null : _tableScrollbarTrackRectFor(id);
  }

  Rect? _tableScrollbarTrackRectFor(Object id) {
    final layout = _layout;
    if (layout == null || layout.tableMaxScroll(id) <= 0) return null;
    final bounds = layout.tableBounds(id);
    if (bounds == null) return null;
    const horizontalInset = 4.0;
    const height = 4.0;
    final width = layout.contentWidth - horizontalInset * 2;
    if (width <= 0) return null;
    return Rect.fromLTWH(
      horizontalInset + _contentLeft,
      bounds.bottom - height - 2,
      width,
      height,
    );
  }

  Rect? _tableScrollbarThumbRect() {
    final id = _hoveredTableId;
    return id == null ? null : _tableScrollbarThumbRectFor(id);
  }

  Rect? _tableScrollbarThumbRectFor(Object id) {
    final layout = _layout;
    final track = _tableScrollbarTrackRectFor(id);
    if (layout == null || track == null) return null;
    final tableWidth = layout.tableWidth(id);
    final maxScroll = layout.tableMaxScroll(id);
    if (tableWidth <= 0 || maxScroll <= 0) return null;
    final minimumWidth = track.width < 24 ? track.width : 24.0;
    final thumbWidth = (track.width * layout.contentWidth / tableWidth)
        .clamp(minimumWidth, track.width)
        .toDouble();
    final travel = track.width - thumbWidth;
    final left = track.left + travel * layout.tableScroll(id) / maxScroll;
    return Rect.fromLTWH(left, track.top, thumbWidth, track.height);
  }

  bool _isInteractiveAt(Offset position) {
    final contentPosition = position - _contentOrigin;
    final span = _layout?.spanForOffset(contentPosition);
    if (span case TextSpan(:final recognizer?)
        when recognizer is TapGestureRecognizer && recognizer.onTap != null) {
      return true;
    }
    // Inline controls (task toggles) are hosted as widget spans whose
    // placeholder bounds the layout exposes in render-local coordinates.
    final boxes = _layout?.inlinePlaceholderBoxes ?? const <TextBox>[];
    for (final box in boxes) {
      if (box.toRect().shift(_contentOrigin).contains(position)) return true;
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      final span = _layout?.spanForOffset(entry.localPosition);
      if (span case TextSpan(:final recognizer?)) {
        recognizer.addPointer(event);
      }
      return;
    }
    if (event is PointerHoverEvent || event is PointerExitEvent) {
      _updateHoveredTable(
        event is PointerHoverEvent ? entry.localPosition : null,
      );
      _updateHoveredGutter(
        event is PointerHoverEvent ? entry.localPosition : null,
      );
      final interactive =
          event is PointerHoverEvent && _isInteractiveAt(entry.localPosition);
      if (interactive != _hoveringInteractive) {
        _hoveringInteractive = interactive;
        onHoverInteractiveChanged?.call(interactive);
      }
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MarkdownEditableParentData) {
      child.parentData = MarkdownEditableParentData();
    }
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..isTextField = true
      ..isReadOnly = _readOnly
      ..isFocused = _focused
      ..value = _sourceText
      ..explicitChildNodes = true
      ..textDirection = _textDirection
      ..textSelection = _selection;
    if (_onTap case final callback?) config.onTap = callback;
    if (_onSelectionChanged case final callback?) {
      config.onSetSelection = callback;
    }
    if (_onCopy case final callback?) config.onCopy = callback;
    if (!_readOnly) {
      if (_onCut case final callback?) config.onCut = callback;
      if (_onPaste case final callback?) config.onPaste = callback;
    }
  }

  @override
  void assembleSemanticsNode(
    SemanticsNode node,
    SemanticsConfiguration config,
    Iterable<SemanticsNode> children,
  ) {
    final linkNodes = <SemanticsNode>[];
    for (final entry in _layout?.recognizedSpans ?? const []) {
      final recognizer = entry.span.recognizer;
      if (recognizer is! TapGestureRecognizer || recognizer.onTap == null) {
        continue;
      }
      final boxes = _layout!.selectionBoxesForVisualRange(entry.range);
      if (boxes.isEmpty) continue;
      var rect = boxes.first.toRect();
      for (final box in boxes.skip(1)) {
        rect = rect.expandToInclude(box.toRect());
      }
      final child = SemanticsNode()
        ..rect = rect
        ..updateWith(
          config: (SemanticsConfiguration()
            ..label = entry.span.toPlainText()
            ..isLink = true
            ..textDirection = _textDirection
            ..onTap = recognizer.onTap),
        );
      linkNodes.add(child);
    }
    final tableNodes = <SemanticsNode>[];
    for (final id in _layout?.tableIds ?? const <Object>{}) {
      final bounds = _layout!.tableBounds(id);
      if (bounds == null) continue;
      final child = SemanticsNode()
        ..rect = bounds
        ..updateWith(
          config: (SemanticsConfiguration()
            ..onScrollLeft = () {
              setTableScroll(id, tableScroll(id) - 40);
            }
            ..onScrollRight = () {
              setTableScroll(id, tableScroll(id) + 40);
            }),
        );
      tableNodes.add(child);
    }
    node.updateWith(
      config: config,
      childrenInInversePaintOrder: [...children, ...linkNodes, ...tableNodes],
    );
  }

  List<double> _blockquoteStartInsets() {
    final sourceLineStarts = markdownLineStarts(_sourceText);
    final sourceInsets = List<double>.filled(sourceLineStarts.length, 0);
    for (final decoration in _blockDecorations) {
      if (decoration.kind != MarkdownBlockDecorationKind.blockquote) continue;
      final start = decoration.sourceOffset.clamp(0, _sourceText.length);
      final end = (decoration.sourceEnd ?? start).clamp(
        start,
        _sourceText.length,
      );
      final firstLine = _sourceLineForOffset(start, sourceLineStarts);
      final lastLine = end > start
          ? _sourceLineForOffset(end - 1, sourceLineStarts)
          : firstLine;
      final inset = decoration.padding * decoration.nestingLevel;
      for (var line = firstLine; line <= lastLine; line++) {
        if (inset > sourceInsets[line]) sourceInsets[line] = inset;
      }
    }
    final visualText = _text.toPlainText(includeSemanticsLabels: false);
    final visualLineStarts = markdownLineStarts(visualText);
    return List.unmodifiable([
      for (final visualStart in visualLineStarts)
        sourceInsets[_sourceLineForOffset(
          _mapper.visualToSource(
            visualStart,
            affinity: TextAffinity.downstream,
          ),
          sourceLineStarts,
        )],
    ]);
  }

  List<_PaintedBlockDecoration> _buildPaintedBlockDecorations(
    MarkdownEditableLayout layout,
  ) {
    final result = <_PaintedBlockDecoration>[];
    for (final decoration in _blockDecorations) {
      final blockRects = layout.blockRectsForSourceRange(
        decoration.sourceOffset,
        sourceEnd: decoration.sourceEnd,
      );
      for (final blockRect in blockRects) {
        final rect = decoration.kind == MarkdownBlockDecorationKind.blockquote
            ? _insetRectForBlockquote(blockRect, decoration)
            : blockRect;
        final next = _PaintedBlockDecoration(
          decoration: decoration,
          rect: rect,
        );
        if (result.isNotEmpty && result.last.canMerge(next)) {
          result[result.length - 1] = result.last.merge(next);
        } else {
          result.add(next);
        }
      }
    }
    return List.unmodifiable(result);
  }

  int _sourceLineForOffset(int offset, List<int> lineStarts) {
    var low = 0;
    var high = lineStarts.length;
    while (low + 1 < high) {
      final middle = (low + high) >> 1;
      if (lineStarts[middle] <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// Gutter width for the current source: the widest number string decides.
  double _resolveGutterWidth() {
    if (!_gutter.isEnabled) return 0;
    final lastLine =
        markdownLineIndexFor(
          markdownLineStarts(_sourceText),
          _sourceText.length,
        ) +
        1;
    return markdownGutterWidth(
      configuration: _gutter,
      style: _gutterStyle,
      textScaler: _textScaler,
      widestNumber: '$lastLine',
    );
  }

  @override
  void performLayout() {
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.constrainWidth(_text.toPlainText().length * 16.0);
    final gutterWidth = _resolveGutterWidth();
    _gutterWidth = gutterWidth;
    _contentLeft = _textDirection == TextDirection.rtl ? 0.0 : gutterWidth;
    final contentWidth = width - gutterWidth > 0 ? width - gutterWidth : 0.0;
    final childMaxWidth = contentWidth > _cursorWidth
        ? contentWidth - _cursorWidth
        : 0.0;
    final placeholderDimensions = <PlaceholderDimensions>[];
    final placeholderSizes = <Size>[];
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(
        BoxConstraints(maxWidth: childMaxWidth),
        parentUsesSize: true,
      );
      placeholderSizes.add(child.size);
      placeholderDimensions.add(
        PlaceholderDimensions(
          size: child.size,
          alignment: PlaceholderAlignment.middle,
        ),
      );
      child = (child.parentData! as MarkdownEditableParentData).nextSibling;
    }
    final rebuildLayout =
        _layout == null ||
        _layoutDirty ||
        _cachedLayoutWidth != width ||
        _cachedGutterWidth != gutterWidth ||
        !listEquals(_cachedPlaceholderSizes, placeholderSizes);
    if (rebuildLayout) {
      _resolveTableCellStyles();
      final layout = MarkdownEditableLayout(
        text: _text,
        textDirection: _textDirection,
        textAlign: _textAlign,
        textScaler: _textScaler,
        strutStyle: _strutStyle,
        locale: _locale,
        textHeightBehavior: _textHeightBehavior,
        textWidthBasis: _textWidthBasis,
        maxLines: _maxLines,
        cursorWidth: _cursorWidth,
        mapper: _mapper,
        placeholderDimensions: placeholderDimensions,
        lineDirections: _lineDirections,
        paragraphStartInsets: _blockquoteStartInsets(),
        tables: _tables,
        tableStyle: _tableStyle,
        tableCellStyles: _resolvedTableCellStyles,
      )..layout(maxWidth: contentWidth);
      _layout = layout;
      _paintedBlockDecorations = _buildPaintedBlockDecorations(layout);
      _cachedLayoutWidth = width;
      _cachedGutterWidth = gutterWidth;
      _cachedPlaceholderSizes = List.unmodifiable(placeholderSizes);
      _layoutDirty = false;
      _applyTableScrolls();
    }
    final layout = _layout!;
    size = constraints.constrain(Size(width, layout.size.height));
    final boxes = layout.inlinePlaceholderBoxes;
    child = firstChild;
    var childIndex = 0;
    while (child != null) {
      final parentData = child.parentData! as MarkdownEditableParentData;
      if (childIndex < boxes.length) {
        parentData.offset = boxes[childIndex].toRect().topLeft + _contentOrigin;
      }
      childIndex += 1;
      child = parentData.nextSibling;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final contentOffset = offset + _contentOrigin;
    for (final geometry in _paintedBlockDecorations) {
      final decoration = geometry.decoration;
      final rect = geometry.rect.shift(contentOffset);
      final paint = Paint()..color = decoration.color;
      switch (decoration.kind) {
        case MarkdownBlockDecorationKind.horizontalRule:
          canvas.drawRect(
            Rect.fromLTWH(
              rect.left,
              rect.center.dy - decoration.thickness / 2,
              rect.width,
              decoration.thickness,
            ),
            paint,
          );
        case MarkdownBlockDecorationKind.blockquote:
          if (decoration.backgroundColor case final background?) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(rect, decoration.radius),
              Paint()..color = background,
            );
          }
          final borderWidth = decoration.thickness.clamp(0.0, rect.width);
          final borderLeft = decoration.textDirection == TextDirection.ltr
              ? rect.left
              : rect.right - borderWidth;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(borderLeft, rect.top, borderWidth, rect.height),
              decoration.radius,
            ),
            paint,
          );
          break;
        case MarkdownBlockDecorationKind.extension:
          if (decoration.backgroundColor case final background?) {
            canvas.drawRRect(
              RRect.fromRectAndRadius(rect, decoration.radius),
              Paint()..color = background,
            );
          }
          // A logical-side border mirrors the blockquote inset painter so
          // extension decorations are visibly distinct from plain content.
          final extensionWidth = decoration.thickness.clamp(0.0, rect.width);
          final extensionLeft = decoration.textDirection == TextDirection.ltr
              ? rect.left
              : rect.right - extensionWidth;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                extensionLeft,
                rect.top,
                extensionWidth,
                rect.height,
              ),
              decoration.radius,
            ),
            Paint()..color = decoration.color,
          );
          break;
      }
    }
    _paintTableBackgrounds(canvas, contentOffset);
    if (_selection.isValid && !_selection.isCollapsed) {
      final selectionPaint = Paint()..color = _selectionColor;
      final tableRows = <Rect>[];
      for (final id in _layout!.tableIds) {
        tableRows.addAll(_layout!.tableRowRects(id));
      }
      for (final box in _layout!.selectionBoxesForSourceRange(_selection)) {
        final rect = box.toRect().shift(contentOffset);
        var drawn = false;
        for (final row in tableRows) {
          final clipped = rect.intersect(row.shift(contentOffset));
          if (clipped.width > 0 && clipped.height > 0) {
            canvas.drawRect(clipped, selectionPaint);
            drawn = true;
          }
        }
        if (!drawn) {
          canvas.drawRect(rect, selectionPaint);
        }
      }
    }
    _paintTableBorders(canvas, contentOffset);
    _layout!.paint(canvas, contentOffset);
    defaultPaint(context, offset);
    if (_showCursor && _selection.isValid && _selection.isCollapsed) {
      final caret = caretRectForSourceOffset(
        _selection.extentOffset,
        affinity: _selection.affinity,
      ).shift(offset);
      canvas.drawRect(caret, Paint()..color = _cursorColor);
    }
    _paintTableScrollbar(canvas, offset);
    _paintGutter(canvas, offset, context.estimatedBounds);
  }

  void _paintGutter(Canvas canvas, Offset offset, Rect estimatedBounds) {
    final layout = _layout;
    if (!_gutter.isEnabled || _gutterWidth <= 0 || layout == null) return;
    final runs = layout.lineRuns;
    if (runs.isEmpty) return;
    final lineStarts = markdownLineStarts(_sourceText);
    final top = estimatedBounds.top - offset.dy;
    final bottom = estimatedBounds.bottom - offset.dy;
    final gutterLeft = _textDirection == TextDirection.rtl
        ? size.width - _gutterWidth
        : 0.0;
    for (final run in runs) {
      if (run.top + run.height < top || run.top > bottom) continue;
      final sourceOffset = _mapper.visualToSource(
        run.visualStart,
        affinity: TextAffinity.downstream,
      );
      final lineIndex = markdownLineIndexFor(lineStarts, sourceOffset);
      final lineStart = lineStarts[lineIndex];
      final folded = _foldedStarts.contains(lineStart);
      if (_gutter.lineNumbers) {
        final painter = TextPainter(
          text: TextSpan(
            text: '${lineIndex + 1}',
            style: _gutterStyle.numberStyle.copyWith(
              color: folded ? _gutterStyle.foldedColor : _gutterStyle.color,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: _textScaler,
          maxLines: 1,
        )..layout();
        // Numbers stay adjacent to the fold slot (their inner edge), so a
        // one-digit number does not float away from the arrow when the column
        // is sized for three-digit line numbers.
        final reserved = _gutter.folding
            ? _gutterStyle.chevronSize + _gutterStyle.gap
            : 0.0;
        final left = _textDirection == TextDirection.rtl
            ? gutterLeft + _gutterStyle.padding + reserved
            : gutterLeft +
                  _gutterWidth -
                  _gutterStyle.padding -
                  reserved -
                  painter.width;
        painter.paint(
          canvas,
          offset + Offset(left, run.top + (run.height - painter.height) / 2),
        );
        painter.dispose();
      }
      final foldable = _gutter.folding && _foldableStarts.contains(lineStart);
      if (foldable && (folded || _hoveredGutterStart == lineStart)) {
        _paintFoldChevron(
          canvas,
          offset,
          run,
          folded: folded,
          gutterLeft: gutterLeft,
        );
      }
    }
  }

  void _paintFoldChevron(
    Canvas canvas,
    Offset offset,
    MarkdownLineRun run, {
    required bool folded,
    required double gutterLeft,
  }) {
    final style = _gutterStyle;
    final slotSize = style.chevronSize;
    final mirrored = _textDirection == TextDirection.rtl;
    final slotCenter =
        gutterLeft +
        (mirrored
            ? style.padding + slotSize / 2
            : _gutterWidth - style.padding - slotSize / 2);
    // The chevron lives in the scrolled content: it must carry the same paint
    // offset as the text and the line numbers, or it stays screen-anchored.
    final center = offset + Offset(slotCenter, run.top + run.height / 2);
    final half = slotSize / 2 * 0.7;
    final flip = mirrored ? -1.0 : 1.0;
    final path = Path();
    if (folded) {
      // Collapsed: point toward the content side.
      path.moveTo(center.dx - flip * half / 2, center.dy - half);
      path.lineTo(center.dx + flip * half / 2, center.dy);
      path.lineTo(center.dx - flip * half / 2, center.dy + half);
    } else {
      path.moveTo(center.dx - half, center.dy - half / 2);
      path.lineTo(center.dx, center.dy + half / 2);
      path.lineTo(center.dx + half, center.dy - half / 2);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = style.chevronColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _paintTableScrollbar(Canvas canvas, Offset offset) {
    final track = _tableScrollbarTrackRect();
    final thumb = _tableScrollbarThumbRect();
    if (track == null || thumb == null) return;
    const radius = Radius.circular(2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(track.shift(offset), radius),
      Paint()..color = _cursorColor.withValues(alpha: 0.12),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(thumb.shift(offset), radius),
      Paint()..color = _cursorColor.withValues(alpha: 0.48),
    );
  }

  void _paintTableBackgrounds(Canvas canvas, Offset offset) {
    final layout = _layout!;
    var styleIndex = 0;
    for (final table in _tables) {
      final bounds = layout.tableBounds(table.id);
      if (bounds == null) {
        styleIndex += table.rows.fold(
          0,
          (count, row) => count + row.cells.length,
        );
        continue;
      }
      final cells = layout.tableCellRects(table.id);
      canvas.save();
      canvas.clipRect(_tableViewport(bounds, layout).shift(offset));
      _paintFill(canvas, bounds.shift(offset), _tableStyle.backgroundColor);
      var cellIndex = 0;
      for (final row in table.rows) {
        final background = _backgroundForRow(row.row);
        for (final _ in row.cells) {
          if (cellIndex >= cells.length) break;
          final override = styleIndex < _resolvedTableCellStyles.length
              ? _resolvedTableCellStyles[styleIndex]
              : null;
          styleIndex += 1;
          _paintFill(
            canvas,
            cells[cellIndex].shift(offset),
            override?.backgroundColor ?? background,
            radius: override?.radius ?? _tableStyle.cellRadius,
            direction: table.direction,
          );
          cellIndex += 1;
        }
      }
      canvas.restore();
    }
  }

  Rect _tableViewport(Rect bounds, MarkdownEditableLayout layout) =>
      Rect.fromLTWH(0, bounds.top, layout.contentWidth, bounds.height);

  Color _backgroundForRow(int row) {
    if (row == 0) return _tableStyle.headerBackgroundColor;
    final stripe = row.isOdd
        ? _tableStyle.oddRowBackgroundColor
        : _tableStyle.evenRowBackgroundColor;
    return stripe.a > 0 ? stripe : _tableStyle.bodyBackgroundColor;
  }

  void _paintFill(
    Canvas canvas,
    Rect rect,
    Color color, {
    BorderRadiusGeometry? radius,
    TextDirection direction = TextDirection.ltr,
  }) {
    if (color.a <= 0) return;
    if (radius == null) {
      canvas.drawRect(rect, Paint()..color = color);
      return;
    }
    final resolved = radius.resolve(direction);
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: resolved.topLeft,
        topRight: resolved.topRight,
        bottomLeft: resolved.bottomLeft,
        bottomRight: resolved.bottomRight,
      ),
      Paint()..color = color,
    );
  }

  void _paintTableBorders(Canvas canvas, Offset offset) {
    final layout = _layout!;
    var styleIndex = 0;
    for (final table in _tables) {
      final bounds = layout.tableBounds(table.id);
      if (bounds == null) {
        styleIndex += table.rows.fold(
          0,
          (count, row) => count + row.cells.length,
        );
        continue;
      }
      final cells = layout.tableCellRects(table.id);
      final cellBorders = <MarkdownResolvedTableBorder?>[];
      final cellRadii = <BorderRadiusGeometry?>[];
      for (final row in table.rows) {
        for (final _ in row.cells) {
          final override = styleIndex < _resolvedTableCellStyles.length
              ? _resolvedTableCellStyles[styleIndex]
              : null;
          cellBorders.add(override?.border?.resolve(table.direction));
          cellRadii.add(override?.radius);
          styleIndex += 1;
        }
      }
      canvas.save();
      canvas.clipRect(_tableViewport(bounds, layout).shift(offset));
      final border = _tableStyle.cellBorder.resolve(table.direction);
      if (_tableStyle.borderModel == MarkdownTableBorderModel.separated) {
        for (var index = 0; index < cells.length; index++) {
          _paintBorder(
            canvas,
            cells[index].shift(offset),
            cellBorders[index] ?? border,
            radius: cellRadii[index] ?? _tableStyle.cellRadius,
            direction: table.direction,
          );
        }
      } else {
        _paintCollapsedBorders(
          canvas,
          cells,
          border,
          offset,
          cellBorders: cellBorders,
        );
      }
      _paintBorder(
        canvas,
        bounds.shift(offset),
        _tableStyle.outerBorder.resolve(table.direction),
        radius: _tableStyle.outerRadius,
        direction: table.direction,
      );
      canvas.restore();
    }
  }

  void _paintCollapsedBorders(
    Canvas canvas,
    List<Rect> cells,
    MarkdownResolvedTableBorder border,
    Offset offset, {
    List<MarkdownResolvedTableBorder?> cellBorders = const [],
  }) {
    for (final segment in resolveCollapsedTableBorderSegments(
      cells,
      border,
      cellBorders: cellBorders,
    )) {
      _paintSide(
        canvas,
        segment.start + offset,
        segment.end + offset,
        segment.side,
      );
    }
  }

  void _paintBorder(
    Canvas canvas,
    Rect rect,
    MarkdownResolvedTableBorder border, {
    BorderRadiusGeometry? radius,
    TextDirection direction = TextDirection.ltr,
  }) {
    final resolvedRadius = radius?.resolve(direction);
    if (resolvedRadius != null &&
        border.left == border.top &&
        border.top == border.right &&
        border.right == border.bottom &&
        border.top.isVisible &&
        border.top.pattern == MarkdownTableBorderPattern.solid) {
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: resolvedRadius.topLeft,
          topRight: resolvedRadius.topRight,
          bottomLeft: resolvedRadius.bottomLeft,
          bottomRight: resolvedRadius.bottomRight,
        ),
        Paint()
          ..color = border.top.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = border.top.width,
      );
      return;
    }
    _paintSide(canvas, rect.topLeft, rect.bottomLeft, border.left);
    _paintSide(canvas, rect.topLeft, rect.topRight, border.top);
    _paintSide(canvas, rect.topRight, rect.bottomRight, border.right);
    _paintSide(canvas, rect.bottomLeft, rect.bottomRight, border.bottom);
  }

  void _paintSide(
    Canvas canvas,
    Offset start,
    Offset end,
    MarkdownTableBorderSide side,
  ) {
    if (!side.isVisible) return;
    final paint = Paint()
      ..color = side.color
      ..strokeWidth = side.width
      ..strokeCap = side.pattern == MarkdownTableBorderPattern.dotted
          ? StrokeCap.round
          : StrokeCap.butt;
    if (side.pattern == MarkdownTableBorderPattern.solid) {
      canvas.drawLine(start, end, paint);
      return;
    }
    final vector = end - start;
    final length = vector.distance;
    if (length == 0) return;
    final unit = vector / length;
    final dash = side.pattern == MarkdownTableBorderPattern.dashed
        ? side.width * 3
        : side.width;
    final gap = side.width * 2;
    for (var distance = 0.0; distance < length; distance += dash + gap) {
      final endDistance = (distance + dash).clamp(0.0, length).toDouble();
      canvas.drawLine(
        start + unit * distance,
        start + unit * endDistance,
        paint,
      );
    }
  }
}

Rect _insetRectForBlockquote(Rect rect, MarkdownBlockDecoration decoration) {
  final nestingInset = decoration.padding * (decoration.nestingLevel - 1);
  if (decoration.textDirection == TextDirection.ltr) {
    return Rect.fromLTRB(
      (rect.left + nestingInset).clamp(rect.left, rect.right),
      rect.top,
      rect.right,
      rect.bottom,
    );
  }
  return Rect.fromLTRB(
    rect.left,
    rect.top,
    (rect.right - nestingInset).clamp(rect.left, rect.right),
    rect.bottom,
  );
}

final class _PaintedBlockDecoration {
  const _PaintedBlockDecoration({required this.decoration, required this.rect});

  final MarkdownBlockDecoration decoration;
  final Rect rect;

  bool canMerge(_PaintedBlockDecoration other) =>
      decoration.kind == MarkdownBlockDecorationKind.blockquote &&
      other.decoration.kind == MarkdownBlockDecorationKind.blockquote &&
      decoration.color == other.decoration.color &&
      decoration.backgroundColor == other.decoration.backgroundColor &&
      decoration.textDirection == other.decoration.textDirection &&
      decoration.thickness == other.decoration.thickness &&
      decoration.radius == other.decoration.radius &&
      decoration.nestingLevel == other.decoration.nestingLevel &&
      decoration.padding == other.decoration.padding &&
      rect.left == other.rect.left &&
      rect.right == other.rect.right &&
      rect.bottom == other.rect.top;

  _PaintedBlockDecoration merge(_PaintedBlockDecoration other) =>
      _PaintedBlockDecoration(
        decoration: decoration,
        rect: Rect.fromLTRB(rect.left, rect.top, rect.right, other.rect.bottom),
      );
}
