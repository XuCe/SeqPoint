import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:native_adaptive_toolbox/native_adaptive_toolbox.dart';

import '../controller/markdown_editor_controller.dart';
import '../direction/markdown_direction.dart';
import '../editing/markdown_editing_behavior.dart';
import '../editing/markdown_table_navigation.dart';
import '../editing/markdown_text_input_formatter.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../foundation/markdown_line_index.dart';
import '../foundation/markdown_editable_text.dart';
import '../foundation/markdown_gutter.dart';
import '../foundation/markdown_source_position_mapper.dart';
import '../foundation/markdown_table_projection.dart';
import '../foundation/markdown_text_projection.dart';
import '../foundation/render_markdown_editable.dart';
import '../model/source_range.dart';
import '../parser/markdown_node.dart';
import '../parser/markdown_document.dart';
import '../theme/markdown_editor_theme_data.dart';
import '../theme/markdown_table_style.dart';
import '../widgets/markdown_component_builders.dart';
import 'markdown_span_builder.dart';
import 'markdown_fold_resolver.dart';
import 'markdown_table_cell_style_resolver.dart';
import 'markdown_tree_projection.dart';

final class EditableMarkdown extends StatefulWidget {
  const EditableMarkdown({
    required this.controller,
    required this.focusNode,
    required this.scrollController,
    required this.theme,
    required this.directionMode,
    required this.fallbackDirection,
    required this.behavior,
    required this.componentBuilders,
    this.syntax = const MarkdownSyntaxConfiguration.editorDefaults(),
    this.gutter = const MarkdownGutterConfiguration(),
    this.gutterStyle = const MarkdownGutterStyle(),
    this.onChanged,
    this.onSelectionChanged,
    this.onLinkTap,
    super.key,
  });

  final MarkdownEditorController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final MarkdownEditorThemeData theme;
  final MarkdownDirectionMode directionMode;
  final TextDirection fallbackDirection;
  final MarkdownEditingBehavior behavior;
  final MarkdownEditorComponentBuilders componentBuilders;
  final MarkdownSyntaxConfiguration syntax;
  final MarkdownGutterConfiguration gutter;
  final MarkdownGutterStyle gutterStyle;
  final ValueChanged<String>? onChanged;
  final ValueChanged<TextSelection>? onSelectionChanged;

  /// Called when the user activates a Markdown link in Live mode.
  final ValueChanged<String>? onLinkTap;

  @override
  State<EditableMarkdown> createState() => _EditableMarkdownState();
}

final class _EditableMarkdownState extends State<EditableMarkdown> {
  final GlobalKey<MarkdownEditableTextState> _editableKey = GlobalKey();
  late _MarkdownProjectionController _projection;
  late NativeToolboxSelectionControls _selectionControls;
  late Map<String, MarkdownSyntaxSession> _sessions;
  final Set<String> _reportedExtensionErrors = {};
  TextDirection _selectionDirection = TextDirection.ltr;

  @override
  void initState() {
    super.initState();
    _sessions = _createSessions(widget.syntax);
    _projection = _createProjection();
    _selectionControls = _createSelectionControls(
      _resolvedDirection(),
      defaultTargetPlatform,
    );
  }

  @override
  void didUpdateWidget(EditableMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.syntax != widget.syntax) {
      for (final session in _sessions.values) {
        session.dispose();
      }
      _sessions = _createSessions(widget.syntax);
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.theme != widget.theme ||
        oldWidget.onLinkTap != widget.onLinkTap ||
        oldWidget.syntax != widget.syntax) {
      _projection.dispose();
      _projection = _createProjection();
    }
  }

  static Map<String, MarkdownSyntaxSession> _createSessions(
    MarkdownSyntaxConfiguration syntax,
  ) {
    final sessions = <String, MarkdownSyntaxSession>{};
    for (final extension in syntax.orderedExtensions) {
      final session = extension.createSession();
      if (session != null) sessions[extension.id] = session;
    }
    return Map.unmodifiable(sessions);
  }

  _MarkdownProjectionController _createProjection() =>
      _MarkdownProjectionController(
        source: widget.controller,
        spanBuilder: MarkdownSpanBuilder(
          theme: widget.theme,
          onLinkTap: widget.onLinkTap,
        ),
        builders: widget.componentBuilders,
        syntax: widget.syntax,
        sessions: _sessions,
        reportedErrors: _reportedExtensionErrors,
        theme: widget.theme,
        directionMode: widget.directionMode,
        fallbackDirection: widget.fallbackDirection,
      );

  TextDirection _resolvedDirection() {
    final directions = _resolvedDirections();
    return directions.isEmpty ? widget.fallbackDirection : directions.first;
  }

  List<TextDirection> _resolvedDirections() =>
      const MarkdownDirectionResolver().resolve(
        widget.controller.text,
        mode: widget.directionMode,
        fallback: widget.fallbackDirection,
      );

  NativeToolboxSelectionControls _createSelectionControls(
    TextDirection direction,
    TargetPlatform platform,
  ) {
    final custom = widget.componentBuilders.selectionHandleBuilder;
    return NativeToolboxSelectionControls(
      platform: platform,
      handleBuilder: custom == null
          ? null
          : (context, type, lineHeight) => custom(
              context,
              MarkdownSelectionHandleContext(
                kind: switch (type) {
                  TextSelectionHandleType.left =>
                    MarkdownSelectionHandleKind.start,
                  TextSelectionHandleType.right =>
                    MarkdownSelectionHandleKind.end,
                  TextSelectionHandleType.collapsed =>
                    MarkdownSelectionHandleKind.collapsed,
                },
                textDirection: direction,
                theme: widget.theme,
              ),
            ),
    );
  }

  @override
  void dispose() {
    _projection.dispose();
    for (final session in _sessions.values) {
      session.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = _resolvedDirection();
    final platform = defaultTargetPlatform;
    if (_selectionControls.platform != platform ||
        _selectionDirection != textDirection) {
      _selectionControls = _createSelectionControls(textDirection, platform);
      _selectionDirection = textDirection;
    }
    final tableCellStyles = resolveMarkdownTableCellStyles(
      document: _document,
      style: widget.theme.tableStyle,
      mode: widget.controller.mode,
      fallbackDirection: widget.fallbackDirection,
    );
    _projection.tableCellStyles = tableCellStyles;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.tab): () =>
            _handleTab(shift: false),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
            _handleTab(shift: true),
      },
      child: MarkdownEditableText(
        key: _editableKey,
        controller: _projection,
        focusNode: widget.focusNode,
        scrollController: widget.scrollController,
        style: widget.theme.bodyStyle,
        cursorColor: widget.theme.caretColor,
        backgroundCursorColor: widget.theme.mutedTextColor,
        selectionColor: widget.theme.selectionColor,
        selectionControls: _selectionControls,
        textDirection: textDirection,
        lineDirections: _resolvedDirections(),
        textAlign: TextAlign.start,
        maxLines: null,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        inputFormatters: [
          MarkdownTextInputFormatter(
            behavior: widget.behavior,
            extensionRules: widget.syntax.editingRules,
            extensionErrorListener: widget.syntax.onExtensionError,
          ),
        ],
        onChanged: widget.onChanged,
        onUndo: widget.controller.undo,
        onRedo: widget.controller.redo,
        onSelectionChanged: (selection, cause) =>
            widget.onSelectionChanged?.call(selection),
        projection: _LiveProjection(
          widget.controller,
          widget.syntax,
          _sessions,
          widget.theme,
          _reportedExtensionErrors,
        ),
        projectionMode: widget.controller.mode,
        tableStyle: widget.theme.tableStyle,
        tableCellStyles: tableCellStyles,
        blockDecorations: _blockDecorations(),
        gutter: widget.gutter,
        gutterStyle: widget.gutterStyle,
        foldableStarts: _foldableStarts(),
        foldedStarts: widget.controller.foldedBlockStarts,
        onToggleFold: _toggleFold,
      ),
    );
  }

  /// Tab moves between table cells; outside tables it indents as before.
  /// Tab on the last cell appends a new row; Shift+Tab walks backwards.
  void _handleTab({required bool shift}) {
    final formatter = MarkdownTextInputFormatter(
      behavior: widget.behavior,
      extensionRules: widget.syntax.editingRules,
      extensionErrorListener: widget.syntax.onExtensionError,
    );
    final selection = widget.controller.selection;
    final document = _document;
    if (!selection.isValid || !selection.isCollapsed) {
      _projection.value = shift
          ? formatter.unindent(_projection.value)
          : formatter.indent(_projection.value);
      return;
    }
    final offset = selection.extentOffset;
    MarkdownBlockNode? table;
    for (final block in document.blocks) {
      if (block.type == MarkdownBlockType.table &&
          block.range.contains(offset)) {
        table = block;
        break;
      }
    }
    if (table == null) {
      _projection.value = shift
          ? formatter.unindent(_projection.value)
          : formatter.indent(_projection.value);
      return;
    }
    final data = table.tableData!;
    if (data.separatorRange.contains(offset)) {
      _projection.value = shift
          ? formatter.unindent(_projection.value)
          : formatter.indent(_projection.value);
      return;
    }
    if (!shift) {
      final next = MarkdownTableNavigation.nextCell(data, offset);
      if (next != null) {
        _projection.value = _projection.value.copyWith(
          selection: TextSelection.collapsed(offset: next),
        );
        return;
      }
      final appended = MarkdownTableNavigation.appendRowText(
        data,
        _projection.value.text,
      );
      _projection.value = TextEditingValue(
        text: appended.text,
        selection: TextSelection.collapsed(offset: appended.caret),
      );
      return;
    }
    final previous = MarkdownTableNavigation.previousCell(data, offset);
    if (previous != null) {
      _projection.value = _projection.value.copyWith(
        selection: TextSelection.collapsed(offset: previous),
      );
      return;
    }
    _projection.value = formatter.unindent(_projection.value);
  }

  MarkdownDocument get _document =>
      widget.controller.documentFor(widget.syntax);

  /// Hidden source ranges for the folds the user collapsed.
  List<SourceRange> _foldedRanges() {
    final folded = widget.controller.foldedBlockStarts;
    if (folded.isEmpty) return const [];
    return [
      for (final fold in resolveMarkdownFolds(_document, folded))
        fold.hiddenRange,
    ];
  }

  List<int> _foldableStarts() => [
    for (final fold in markdownFoldableBlocks(_document)) fold.start,
  ];

  /// Folds or unfolds [blockStart] from the gutter.
  ///
  /// Folding while the caret or selection intersects the collapsed range moves
  /// the caret to the fold start, mirroring what removing that source would do.
  void _toggleFold(int blockStart) {
    final controller = widget.controller;
    final wasFolded = controller.isFoldedAt(blockStart);
    controller.toggleFoldAt(blockStart);
    if (wasFolded) return;
    final folds = resolveMarkdownFolds(_document, {blockStart});
    if (folds.isEmpty) return;
    final hidden = folds.first.hiddenRange;
    final selection = controller.selection;
    if (!selection.isValid) return;
    if (selection.start < hidden.end && selection.end > hidden.start) {
      controller.selection = TextSelection.collapsed(offset: hidden.start);
    }
  }

  List<MarkdownBlockDecoration> _blockDecorations() {
    if (widget.controller.mode != MarkdownEditorMode.live) return const [];
    final directions = const MarkdownDirectionResolver().resolve(
      widget.controller.text,
      mode: widget.directionMode,
      fallback: widget.fallbackDirection,
    );
    final selection = widget.controller.selection;
    final composing = widget.controller.composing;
    bool active(SourceRange range) =>
        _isEditingRangeActive(range, selection, composing);
    final decorations = <MarkdownBlockDecoration>[];
    final lineStarts = markdownLineStarts(widget.controller.text);
    final foldedRanges = _foldedRanges();
    bool folded(SourceRange range) => foldedRanges.any(
      (hidden) => hidden.start <= range.start && range.end <= hidden.end,
    );
    void visit(List<MarkdownBlockNode> blocks, int quoteDepth) {
      for (final block in blocks) {
        final depth =
            quoteDepth + (block.type == MarkdownBlockType.blockquote ? 1 : 0);
        if (folded(block.range)) {
          visit(block.children, depth);
          continue;
        }
        if (block.type == MarkdownBlockType.horizontalRule) {
          if (!active(block.range)) {
            final line = markdownLineIndexFor(lineStarts, block.range.start);
            decorations.add(
              MarkdownBlockDecoration(
                kind: MarkdownBlockDecorationKind.horizontalRule,
                sourceOffset: block.range.start,
                color: widget.theme.quoteBorderColor,
                textDirection: line < directions.length
                    ? directions[line]
                    : widget.fallbackDirection,
                thickness: 1,
                radius: widget.theme.quoteRadius,
                nestingLevel: 1,
              ),
            );
          }
        } else if (block.type == MarkdownBlockType.blockquote &&
            !active(block.range)) {
          for (final part in markdownQuoteLineRanges(
            widget.controller.text,
            block,
            lineStarts,
          )) {
            decorations.add(
              MarkdownBlockDecoration(
                kind: MarkdownBlockDecorationKind.blockquote,
                sourceOffset: part.start,
                sourceEnd: part.end,
                color: widget.theme.quoteBorderColor,
                textDirection: part.lineIndex < directions.length
                    ? directions[part.lineIndex]
                    : widget.fallbackDirection,
                thickness: widget.theme.quoteBorderWidth,
                radius: widget.theme.quoteRadius,
                backgroundColor: widget.theme.quoteBackgroundColor,
                nestingLevel: depth,
              ),
            );
          }
        }
        visit(block.children, depth);
      }
    }

    visit(_document.blocks, 0);
    decorations.addAll(
      markdownTreeExtensionDecorations(
        hiddenRanges: foldedRanges,
        source: widget.controller.text,
        document: _document,
        theme: widget.theme,
        mode: MarkdownEditorMode.live,
        selection: selection,
        composing: composing,
        syntax: widget.syntax,
        sessions: _sessions,
        onExtensionError: widget.syntax.onExtensionError,
        reportedErrors: _reportedExtensionErrors,
        textDirection: widget.fallbackDirection,
      ),
    );
    return decorations;
  }
}

final class _MarkdownProjectionController extends TextEditingController {
  _MarkdownProjectionController({
    required this.source,
    required this.spanBuilder,
    required this.builders,
    required this.syntax,
    required this.sessions,
    required this.reportedErrors,
    required this.theme,
    required this.directionMode,
    required this.fallbackDirection,
  }) : super.fromValue(source.value) {
    source.addListener(_syncFromSource);
    addListener(_syncToSource);
  }

  final MarkdownEditorController source;
  final MarkdownSpanBuilder spanBuilder;
  final MarkdownEditorComponentBuilders builders;
  final MarkdownSyntaxConfiguration syntax;
  final Map<String, MarkdownSyntaxSession> sessions;
  final Set<String> reportedErrors;
  final MarkdownEditorThemeData theme;
  final MarkdownDirectionMode directionMode;
  final TextDirection fallbackDirection;
  bool _syncing = false;
  List<MarkdownTableCellStyle?> tableCellStyles = const [];

  /// Hidden ranges for the folds the user collapsed, in source order.
  List<SourceRange> _foldedRanges() {
    final folded = source.foldedBlockStarts;
    if (folded.isEmpty) return const [];
    return [
      for (final fold in resolveMarkdownFolds(
        source.documentFor(syntax),
        folded,
      ))
        fold.hiddenRange,
    ];
  }

  void _syncFromSource() {
    if (_syncing || value == source.value) return;
    _syncing = true;
    value = source.value;
    _syncing = false;
  }

  void _syncToSource() {
    if (_syncing || source.value == value) return;
    _syncing = true;
    source.applyEditingValue(value);
    _syncing = false;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final directions = const MarkdownDirectionResolver().resolve(
      source.text,
      mode: directionMode,
      fallback: fallbackDirection,
    );
    final lineStarts = markdownLineStarts(source.text);
    final foldedRanges = _foldedRanges();
    spanBuilder.beginBuild();
    return spanBuilder.build(
      source.documentFor(syntax),
      mode: source.mode,
      selection: value.selection,
      composing: withComposing ? value.composing : TextRange.empty,
      context: context,
      mediaBuilder: (context, media) =>
          builders.buildMedia(context, context: media),
      direction: fallbackDirection,
      syntax: syntax,
      sessions: sessions,
      reportedErrors: reportedErrors,
      foldedRanges: foldedRanges,
      taskBuilder: (context, block, markerRange) {
        final line = markdownLineIndexFor(lineStarts, block.range.start);
        return builders.buildTaskToggle(
          context,
          context: MarkdownTaskToggleContext(
            sourceRange: markerRange,
            checked:
                source.text.codeUnitAt(markerRange.start + 1) == 0x78 ||
                source.text.codeUnitAt(markerRange.start + 1) == 0x58,
            enabled: true,
            textDirection: line < directions.length
                ? directions[line]
                : fallbackDirection,
            theme: theme,
            onToggle: () => source.toggleTaskAt(markerRange.start + 1),
          ),
        );
      },
      tableCellStyles: tableCellStyles,
    );
  }

  @override
  void dispose() {
    spanBuilder.dispose();
    source.removeListener(_syncFromSource);
    removeListener(_syncToSource);
    super.dispose();
  }
}

final class _LiveProjection implements MarkdownTextProjection {
  const _LiveProjection(
    this.controller,
    this.syntax,
    this.sessions,
    this.theme,
    this.reportedErrors,
  );

  final MarkdownEditorController controller;
  final MarkdownSyntaxConfiguration syntax;
  final Map<String, MarkdownSyntaxSession> sessions;
  final MarkdownEditorThemeData theme;
  final Set<String> reportedErrors;

  @override
  MarkdownProjectionSnapshot project(MarkdownProjectionContext context) {
    final folds = controller.foldedBlockStarts.isEmpty
        ? const <MarkdownFoldRange>[]
        : resolveMarkdownFolds(
            controller.documentFor(syntax),
            controller.foldedBlockStarts,
          );
    final foldedRanges = [for (final fold in folds) fold.hiddenRange];
    if (context.mode == MarkdownEditorMode.raw) {
      if (foldedRanges.isEmpty) {
        return const IdentityMarkdownTextProjection().project(context);
      }
      return MarkdownProjectionSnapshot(
        source: context.value.text,
        selection: context.value.selection,
        composing: context.value.composing,
        segments: markdownRawSegments(context.value.text, foldedRanges),
        blocks: const [],
        invalidationKey: Object.hash(
          context.value.text,
          context.value.selection,
          context.value.composing,
          context.fallbackDirection,
          Object.hashAll(foldedRanges.map((range) => range.start)),
        ),
      );
    }
    final source = context.value.text;
    final selection = context.value.selection;
    final composing = context.value.composing;
    bool active(SourceRange range) =>
        _isEditingRangeActive(range, selection, composing);
    final document = controller.documentFor(syntax);
    final projectedSegments = markdownTreeSegments(
      source: source,
      document: document,
      mode: MarkdownEditorMode.live,
      theme: theme,
      active: active,
      selection: selection,
      composing: composing,
      syntax: syntax,
      sessions: sessions,
      onExtensionError: syntax.onExtensionError,
      reportedErrors: reportedErrors,
      textDirection: context.fallbackDirection,
      foldedRanges: foldedRanges,
    );
    final snapshotMapper = MarkdownSourcePositionMapper(
      projectedSegments,
      source: source,
    );
    return MarkdownProjectionSnapshot(
      source: source,
      selection: context.value.selection,
      composing: context.value.composing,
      segments: projectedSegments,
      blocks: const [],
      tables: MarkdownTableProjection.build(
        document: document,
        mapper: snapshotMapper,
        fallbackDirection: context.fallbackDirection,
        hiddenRanges: foldedRanges,
      ),
      invalidationKey: Object.hash(
        source,
        context.value.selection,
        context.value.composing,
        Object.hashAll(foldedRanges.map((range) => range.start)),
      ),
    );
  }
}

bool _isEditingRangeActive(
  SourceRange range,
  TextSelection selection,
  TextRange composing,
) {
  if (selection.isValid &&
      (_editingOffsetTouches(range, selection.baseOffset) ||
          _editingOffsetTouches(range, selection.extentOffset) ||
          (!selection.isCollapsed &&
              selection.start <= range.end &&
              range.start < selection.end))) {
    return true;
  }
  return composing.isValid &&
      (_editingOffsetTouches(range, composing.start) ||
          _editingOffsetTouches(range, composing.end) ||
          (composing.start < range.end && range.start < composing.end));
}

bool _editingOffsetTouches(SourceRange range, int offset) =>
    offset >= range.start && offset < range.end;
