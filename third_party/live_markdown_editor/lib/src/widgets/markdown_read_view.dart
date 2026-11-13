import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:native_adaptive_toolbox/native_adaptive_toolbox.dart';

import '../controller/markdown_editor_controller.dart';
import '../direction/markdown_direction.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../foundation/markdown_line_index.dart';
import '../foundation/markdown_editable_text.dart';
import '../foundation/markdown_source_position_mapper.dart';
import '../foundation/markdown_table_projection.dart';
import '../foundation/markdown_text_projection.dart';
import '../foundation/render_markdown_editable.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';
import '../rendering/read_markdown_projection.dart';
import '../rendering/markdown_table_cell_style_resolver.dart';
import '../rendering/markdown_tree_projection.dart';
import '../theme/markdown_editor_theme_data.dart';
import '../theme/markdown_table_style.dart';
import 'markdown_component_builders.dart';

final class MarkdownReadView extends StatefulWidget {
  const MarkdownReadView({
    required this.controller,
    required this.scrollController,
    required this.theme,
    required this.componentBuilders,
    this.syntax = const MarkdownSyntaxConfiguration.editorDefaults(),
    required this.directionMode,
    required this.fallbackDirection,
    this.onLinkTap,
    this.onSelectionChanged,
    super.key,
  });

  final MarkdownEditorController controller;
  final ScrollController scrollController;
  final MarkdownEditorThemeData theme;
  final MarkdownEditorComponentBuilders componentBuilders;
  final MarkdownSyntaxConfiguration syntax;
  final MarkdownDirectionMode directionMode;
  final TextDirection fallbackDirection;
  final ValueChanged<String>? onLinkTap;
  final ValueChanged<TextSelection>? onSelectionChanged;

  @override
  State<MarkdownReadView> createState() => _MarkdownReadViewState();
}

final class _MarkdownReadViewState extends State<MarkdownReadView> {
  final FocusNode _focusNode = FocusNode();
  late ReadMarkdownProjection _projection;
  late Map<String, MarkdownSyntaxSession> _sessions;
  final Set<String> _reportedExtensionErrors = {};

  @override
  void initState() {
    super.initState();
    _sessions = _createSessions(widget.syntax);
    _projection = _createProjection();
  }

  @override
  void didUpdateWidget(MarkdownReadView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.syntax != widget.syntax) {
      for (final session in _sessions.values) {
        session.dispose();
      }
      _sessions = _createSessions(widget.syntax);
    }
    if (oldWidget.theme != widget.theme ||
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

  ReadMarkdownProjection _createProjection() =>
      ReadMarkdownProjection(theme: widget.theme, onLinkTap: widget.onLinkTap);

  @override
  void dispose() {
    _projection.dispose();
    for (final session in _sessions.values) {
      session.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  NativeToolboxSelectionControls _createSelectionControls(
    TextDirection direction,
  ) {
    final custom = widget.componentBuilders.selectionHandleBuilder;
    return NativeToolboxSelectionControls(
      platform: defaultTargetPlatform,
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
  Widget build(BuildContext context) {
    final directions = const MarkdownDirectionResolver().resolve(
      widget.controller.text,
      mode: widget.directionMode,
      fallback: widget.fallbackDirection,
    );
    final tableCellStyles = resolveMarkdownTableCellStyles(
      document: _document,
      style: widget.theme.tableStyle,
      mode: MarkdownEditorMode.read,
      fallbackDirection: widget.fallbackDirection,
    );
    final span = _buildSpan(context, directions, tableCellStyles);
    final direction = _directionForSelection(directions);
    return MarkdownEditableText(
      controller: widget.controller,
      focusNode: _focusNode,
      scrollController: widget.scrollController,
      readOnly: true,
      maxLines: null,
      minLines: 1,
      style: widget.theme.bodyStyle,
      cursorColor: widget.theme.caretColor,
      backgroundCursorColor: widget.theme.mutedTextColor,
      selectionColor: widget.theme.selectionColor,
      selectionControls: _createSelectionControls(direction),
      textDirection: direction,
      blockDecorations: _blockDecorations(directions),
      lineDirections: directions,
      onSelectionChanged: (selection, _) {
        setState(() {});
        widget.onSelectionChanged?.call(selection);
      },
      projection: _ReadSourceProjection(
        span,
        _document,
        widget.theme,
        widget.syntax,
        _sessions,
        _reportedExtensionErrors,
      ),
      projectionMode: MarkdownEditorMode.read,
      tableStyle: widget.theme.tableStyle,
      tableCellStyles: tableCellStyles,
    );
  }

  TextDirection _directionForSelection(List<TextDirection> directions) {
    if (directions.isEmpty) return widget.fallbackDirection;
    final offset = widget.controller.selection.isValid
        ? widget.controller.selection.extentOffset
        : 0;
    final clamped = offset.clamp(0, widget.controller.text.length);
    final line = markdownLineIndexFor(
      markdownLineStarts(widget.controller.text),
      clamped,
    );
    return line < directions.length ? directions[line] : directions.last;
  }

  List<MarkdownBlockDecoration> _blockDecorations(
    List<TextDirection> directions,
  ) {
    final decorations = <MarkdownBlockDecoration>[];
    final lineStarts = markdownLineStarts(widget.controller.text);
    void visit(List<MarkdownBlockNode> blocks, int quoteDepth) {
      for (final block in blocks) {
        final depth =
            quoteDepth + (block.type == MarkdownBlockType.blockquote ? 1 : 0);
        if (block.type == MarkdownBlockType.horizontalRule) {
          decorations.add(
            MarkdownBlockDecoration(
              kind: MarkdownBlockDecorationKind.horizontalRule,
              sourceOffset: block.range.start,
              color: widget.theme.quoteBorderColor,
              thickness: 1,
              radius: widget.theme.quoteRadius,
              textDirection: _directionAt(
                block.range.start,
                directions,
                lineStarts,
              ),
              nestingLevel: 1,
            ),
          );
        } else if (block.type == MarkdownBlockType.blockquote) {
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
                thickness: widget.theme.quoteBorderWidth,
                radius: widget.theme.quoteRadius,
                backgroundColor: widget.theme.quoteBackgroundColor,
                textDirection: part.lineIndex < directions.length
                    ? directions[part.lineIndex]
                    : widget.fallbackDirection,
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
        source: widget.controller.text,
        document: _document,
        theme: widget.theme,
        mode: MarkdownEditorMode.read,
        syntax: widget.syntax,
        sessions: _sessions,
        onExtensionError: widget.syntax.onExtensionError,
        reportedErrors: _reportedExtensionErrors,
        textDirection: widget.fallbackDirection,
      ),
    );
    return decorations;
  }

  TextDirection _directionAt(
    int offset,
    List<TextDirection> directions,
    List<int> lineStarts,
  ) {
    final line = markdownLineIndexFor(lineStarts, offset);
    return line < directions.length
        ? directions[line]
        : widget.fallbackDirection;
  }

  TextSpan _buildSpan(
    BuildContext context,
    List<TextDirection> directions,
    List<MarkdownTableCellStyle?> tableCellStyles,
  ) {
    final lineStarts = markdownLineStarts(widget.controller.text);
    return _projection.build(
      _document,
      tableCellStyles: tableCellStyles,
      direction: widget.fallbackDirection,
      mediaBuilder: (media) =>
          widget.componentBuilders.buildMedia(context, context: media),
      syntax: widget.syntax,
      sessions: _sessions,
      reportedErrors: _reportedExtensionErrors,
      context: context,
      taskBuilder: (block, markerRange) =>
          widget.componentBuilders.buildTaskToggle(
            context,
            context: MarkdownTaskToggleContext(
              sourceRange: markerRange,
              checked:
                  widget.controller.text.codeUnitAt(markerRange.start + 1) ==
                      0x78 ||
                  widget.controller.text.codeUnitAt(markerRange.start + 1) ==
                      0x58,
              enabled: true,
              textDirection: _directionAt(
                block.range.start,
                directions,
                lineStarts,
              ),
              theme: widget.theme,
              onToggle: () =>
                  widget.controller.toggleTaskAt(markerRange.start + 1),
            ),
          ),
    );
  }

  MarkdownDocument get _document =>
      widget.controller.documentFor(widget.syntax);
}

final class _ReadSourceProjection implements MarkdownTextProjection {
  const _ReadSourceProjection(
    this.visualText,
    this.document,
    this.theme,
    this.syntax,
    this.sessions,
    this.reportedErrors,
  );

  final TextSpan visualText;
  final MarkdownDocument document;
  final MarkdownEditorThemeData theme;
  final MarkdownSyntaxConfiguration syntax;
  final Map<String, MarkdownSyntaxSession> sessions;
  final Set<String> reportedErrors;
  @override
  MarkdownProjectionSnapshot project(MarkdownProjectionContext context) {
    final source = context.value.text;
    final segments = markdownTreeSegments(
      source: source,
      document: document,
      mode: MarkdownEditorMode.read,
      theme: theme,
      syntax: syntax,
      sessions: sessions,
      onExtensionError: syntax.onExtensionError,
      reportedErrors: reportedErrors,
      textDirection: context.fallbackDirection,
    );
    final snapshotMapper = MarkdownSourcePositionMapper(
      segments,
      source: source,
    );
    return MarkdownProjectionSnapshot(
      source: source,
      selection: context.value.selection,
      composing: context.value.composing,
      segments: segments,
      blocks: const [],
      visualText: visualText,
      tables: MarkdownTableProjection.build(
        document: document,
        mapper: snapshotMapper,
        fallbackDirection: context.fallbackDirection,
      ),
      invalidationKey: Object.hash(
        source,
        context.value.selection,
        context.value.composing,
        visualText.toPlainText(includeSemanticsLabels: false),
      ),
    );
  }
}
