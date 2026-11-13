import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../foundation/markdown_projection_segment.dart';
import '../model/source_range.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../theme/markdown_editor_theme_data.dart';
import '../theme/markdown_table_style.dart';
import '../widgets/default_markdown_media.dart';
import '../widgets/markdown_component_builders.dart';
import 'markdown_tree_projection.dart';

typedef MarkdownTaskSpanBuilder = Widget Function(
  BuildContext context,
  MarkdownBlockNode block,
  SourceRange markerRange,
);

final class MarkdownSpanBuilder {
  MarkdownSpanBuilder({required this.theme, this.onLinkTap});

  final MarkdownEditorThemeData theme;
  final ValueChanged<String>? onLinkTap;
  final List<TapGestureRecognizer> _recognizers = [];
  List<MarkdownTableCellStyle?> _tableCellStyles = const [];
  int _tableCellStyleIndex = 0;

  /// Disposes recognizers created by the previous build.
  void beginBuild() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  /// Disposes any live recognizers; call when the owning controller dies.
  void dispose() => beginBuild();

  TextSpan build(
    MarkdownDocument document, {
    required MarkdownEditorMode mode,
    required TextSelection selection,
    TextRange composing = TextRange.empty,
    BuildContext? context,
    MarkdownTaskSpanBuilder? taskBuilder,
    MarkdownMediaBuilder? mediaBuilder,
    TextDirection direction = TextDirection.ltr,
    MarkdownSyntaxConfiguration? syntax,
    Map<String, MarkdownSyntaxSession>? sessions,
    Set<String>? reportedErrors,
    List<MarkdownTableCellStyle?> tableCellStyles = const [],
    List<SourceRange> foldedRanges = const [],
  }) {
    _tableCellStyles = tableCellStyles;
    _tableCellStyleIndex = 0;
    if (mode == MarkdownEditorMode.raw) {
      // Raw is the exact source identity projection in every mode surface,
      // minus any folded ranges the user collapsed.
      if (foldedRanges.isEmpty) {
        return TextSpan(style: theme.bodyStyle, text: document.source);
      }
      final visible = markdownRawSegments(
        document.source,
        foldedRanges,
      ).where((segment) => segment.kind == MarkdownProjectionSegmentKind.text);
      return TextSpan(
        style: theme.bodyStyle,
        text: visible.map((segment) => segment.text).join(),
      );
    }
    if (mode == MarkdownEditorMode.live) {
      return _treeSpan(
        document,
        mode: mode,
        selection: selection,
        composing: composing,
        context: context,
        taskBuilder: taskBuilder,
        mediaBuilder: mediaBuilder,
        direction: direction,
        syntax: syntax,
        sessions: sessions,
        reportedErrors: reportedErrors,
        foldedRanges: foldedRanges,
      );
    }
    final linksInteractive =
        mode == MarkdownEditorMode.live && onLinkTap != null;
    final spans = <InlineSpan>[];
    for (final block in document.blocks) {
      _appendBlock(
        spans,
        document,
        block,
        mode,
        selection,
        composing,
        context,
        taskBuilder,
        linksInteractive,
      );
    }
    return TextSpan(style: theme.bodyStyle, children: spans);
  }

  TextSpan _treeSpan(
    MarkdownDocument document, {
    required MarkdownEditorMode mode,
    required TextSelection selection,
    required TextRange composing,
    required BuildContext? context,
    required MarkdownTaskSpanBuilder? taskBuilder,
    MarkdownMediaBuilder? mediaBuilder,
    TextDirection direction = TextDirection.ltr,
    MarkdownSyntaxConfiguration? syntax,
    Map<String, MarkdownSyntaxSession>? sessions,
    Set<String>? reportedErrors,
    List<SourceRange> foldedRanges = const [],
  }) {
    final segments = markdownTreeSegments(
      source: document.source,
      document: document,
      mode: mode,
      theme: theme,
      active: (range) => _isActive(range, selection, composing),
      selection: selection,
      composing: composing,
      syntax: syntax,
      sessions: sessions,
      onExtensionError: syntax?.onExtensionError,
      reportedErrors: reportedErrors,
      textDirection: direction,
      foldedRanges: foldedRanges,
    );
    final spans = <InlineSpan>[];
    for (final segment in segments) {
      if (segment.kind == MarkdownProjectionSegmentKind.text) {
        final presentation = _treePresentation(
          document,
          segment.sourceRange.start,
        );
        spans.add(
          TextSpan(
            text: segment.text,
            style: presentation.style,
            recognizer: presentation.recognizer,
          ),
        );
      } else if (segment.kind == MarkdownProjectionSegmentKind.widget) {
        if (segment.id case final MarkdownExtensionWidgetToken token) {
          if (context == null) continue;
          Widget child = token.builder(context, token.context);
          if (token.semanticsLabel != null) {
            child = Semantics(label: token.semanticsLabel, child: child);
          }
          if (token.onActivate != null) {
            child = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: token.onActivate,
              child: child,
            );
          }
          spans.add(
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: child),
          );
          continue;
        }
        if (segment.id case final MarkdownTreeListIndent indent) {
          spans.add(
            WidgetSpan(
              child: SizedBox(
                width: (indent.depth - 1) * theme.taskHitTargetSize / 2,
              ),
            ),
          );
          continue;
        }
        final marker = segment.sourceRange;
        final task = _taskAt(document.blocks, document.source, marker);
        if (task != null && context != null && taskBuilder != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: SizedBox(
                width: theme.taskHitTargetSize,
                child: taskBuilder(context, task, marker),
              ),
            ),
          );
          continue;
        }
        final image = _imageAt(document, marker.start);
        if (image != null && context != null) {
          final linked = _enclosingLinkDestination(document, marker.start);
          Widget media =
              mediaBuilder?.call(
                context,
                _mediaContext(document, image, marker, linked, direction),
              ) ??
              DefaultMarkdownMedia(
                context: _mediaContext(
                  document,
                  image,
                  marker,
                  linked,
                  direction,
                ),
              );
          if (linked != null && onLinkTap != null) {
            media = GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onLinkTap!(linked),
              child: media,
            );
          }
          spans.add(
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: media),
          );
          continue;
        }
        spans.add(WidgetSpan(child: SizedBox(width: theme.taskHitTargetSize)));
      }
    }
    return TextSpan(style: theme.bodyStyle, children: spans);
  }

  MarkdownBlockNode? _taskAt(
    List<MarkdownBlockNode> blocks,
    String source,
    SourceRange marker,
  ) {
    for (final block in blocks) {
      if ((block.type == MarkdownBlockType.taskListItem ||
              block.type == MarkdownBlockType.listItem) &&
          block.range.contains(marker.start) &&
          isMarkdownTaskMarker(source, marker)) {
        return block;
      }
      final child = _taskAt(block.children, source, marker);
      if (child != null) return child;
    }
    return null;
  }

  MarkdownInlineNode? _imageAt(MarkdownDocument document, int offset) {
    MarkdownInlineNode? inNodes(List<MarkdownInlineNode> nodes) {
      for (final node in nodes) {
        if (!node.range.contains(offset)) continue;
        if (node.type == MarkdownInlineType.image) return node;
        final child = inNodes(node.children);
        if (child != null) return child;
        return null;
      }
      return null;
    }

    MarkdownInlineNode? inBlock(MarkdownBlockNode block) {
      if (!block.range.contains(offset)) return null;
      final found = inNodes(block.inlineNodes);
      if (found != null) return found;
      if (block.type == MarkdownBlockType.table && block.tableData != null) {
        for (final row in block.tableData!.rows) {
          for (final cell in row.cells) {
            final found = inNodes(cell.inlineNodes);
            if (found != null) return found;
          }
        }
      }
      for (final child in block.children) {
        final found = inBlock(child);
        if (found != null) return found;
      }
      return null;
    }

    for (final block in document.blocks) {
      final found = inBlock(block);
      if (found != null) return found;
    }
    return null;
  }

  String? _enclosingLinkDestination(MarkdownDocument document, int offset) {
    String? inNodes(List<MarkdownInlineNode> nodes) {
      for (final node in nodes) {
        if (!node.range.contains(offset)) continue;
        if (node.type == MarkdownInlineType.link) {
          return node.destination;
        }
        final child = inNodes(node.children);
        if (child != null) return child;
        return null;
      }
      return null;
    }

    String? inBlock(MarkdownBlockNode block) {
      if (!block.range.contains(offset)) return null;
      final found = inNodes(block.inlineNodes);
      if (found != null) return found;
      if (block.type == MarkdownBlockType.table && block.tableData != null) {
        for (final row in block.tableData!.rows) {
          for (final cell in row.cells) {
            final found = inNodes(cell.inlineNodes);
            if (found != null) return found;
          }
        }
      }
      for (final child in block.children) {
        final found = inBlock(child);
        if (found != null) return found;
      }
      return null;
    }

    for (final block in document.blocks) {
      final found = inBlock(block);
      if (found != null) return found;
    }
    return null;
  }

  MarkdownMediaContext _mediaContext(
    MarkdownDocument document,
    MarkdownInlineNode image,
    SourceRange marker,
    String? linked,
    TextDirection direction,
  ) {
    return MarkdownMediaContext(
      destination: image.destination ?? marker.slice(document.source),
      alt: _altText(document, image),
      title: image.title,
      sourceRange: marker,
      mode: MarkdownEditorMode.live,
      textDirection: direction,
      constraints: BoxConstraints(
        maxWidth: theme.mediaMaxWidth,
        maxHeight: theme.mediaMaxHeight,
      ),
      loadState: MarkdownMediaLoadState.ready,
      theme: theme,
      linkedDestination: linked,
    );
  }

  String? _altText(MarkdownDocument document, MarkdownInlineNode image) {
    final source = document.source;
    final buffer = StringBuffer();
    for (final child in image.children) {
      if (child.type != MarkdownInlineType.text) continue;
      buffer.write(child.decodedText ?? child.contentRange.slice(source));
    }
    final alt = buffer.toString().trim();
    return alt.isEmpty ? null : alt;
  }

  ({TextStyle style, TapGestureRecognizer? recognizer}) _treePresentation(
    MarkdownDocument document,
    int offset,
  ) {
    MarkdownBlockNode? block;
    MarkdownBlockNode? inlineOwner;
    void findBlock(List<MarkdownBlockNode> nodes) {
      for (final node in nodes) {
        if (!node.range.contains(offset)) continue;
        block = node;
        if (node.inlineNodes.isNotEmpty) inlineOwner = node;
        findBlock(node.children);
        return;
      }
    }

    findBlock(document.blocks);
    var style = block == null ? theme.bodyStyle : _contentStyle(block!);
    TapGestureRecognizer? recognizer;
    void findInline(List<MarkdownInlineNode> nodes) {
      for (final node in nodes) {
        if (!node.range.contains(offset)) continue;
        style = _inlineStyle(node.type, style);
        if (node.type == MarkdownInlineType.link && onLinkTap != null) {
          recognizer = _linkRecognizer(node);
        }
        findInline(node.children);
        return;
      }
    }

    if (block?.type == MarkdownBlockType.table) {
      final data = block!.tableData!;
      var styleIndex = 0;
      for (var row = 0; row < data.rows.length; row++) {
        for (final cell in data.rows[row].cells) {
          if (cell.contentRange.contains(offset)) {
            style = _tableCellTextStyle(row, styleIndex);
            findInline(cell.inlineNodes);
            return (style: style, recognizer: recognizer);
          }
          styleIndex++;
        }
      }
    }
    findInline(inlineOwner?.inlineNodes ?? const []);
    return (style: style, recognizer: recognizer);
  }

  void _appendBlock(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
    MarkdownEditorMode mode,
    TextSelection selection,
    TextRange composing,
    BuildContext? context,
    MarkdownTaskSpanBuilder? taskBuilder,
    bool linksInteractive,
  ) {
    final source = document.source;
    final activeBlock = _isActive(block.range, selection, composing);
    if (block.type == MarkdownBlockType.linkDefinition) {
      if (mode == MarkdownEditorMode.live && !activeBlock) return;
      if (mode == MarkdownEditorMode.read) return;
      spans.add(TextSpan(text: block.contentRange.slice(source)));
      return;
    }
    if (mode == MarkdownEditorMode.live &&
        block.type == MarkdownBlockType.horizontalRule &&
        !activeBlock) {
      if (block.range.slice(source).endsWith('\n')) {
        spans.add(const TextSpan(text: '\n'));
      }
      return;
    }
    if (block.type == MarkdownBlockType.table) {
      if (mode == MarkdownEditorMode.live) {
        _appendLiveTable(
          spans,
          document,
          block,
          selection,
          composing,
          context,
          taskBuilder,
          linksInteractive,
        );
      } else {
        _appendLiteralTable(spans, document, block);
      }
      return;
    }
    final prefix = block.prefixRange;
    if (prefix != null && prefix.length > 0) {
      SourceRange? taskMarkerRange;
      if (block.type == MarkdownBlockType.taskListItem) {
        final bracket = source.indexOf('[', prefix.start);
        if (bracket >= prefix.start &&
            bracket + 3 <= prefix.end &&
            bracket + 3 <= source.length &&
            source.codeUnitAt(bracket + 2) == 0x5D) {
          taskMarkerRange = SourceRange(bracket, bracket + 3);
        }
      }
      if (mode == MarkdownEditorMode.live &&
          taskMarkerRange != null &&
          context != null &&
          taskBuilder != null) {
        if (_markerTouched(taskMarkerRange, selection, composing)) {
          // The caret touches the marker: reveal the literal prefix
          // (e.g. `1. [ ] `) so it can be edited, like Obsidian.
          spans.add(
            TextSpan(
              text: prefix.slice(source),
              style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
            ),
          );
        } else {
          if (_isOrderedMarker(source, prefix.start, taskMarkerRange.start)) {
            // Ordered numbers stay visible next to the control.
            spans.add(
              TextSpan(
                text: source.substring(prefix.start, taskMarkerRange.start),
                style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
              ),
            );
          }
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: SizedBox(
                width: theme.taskHitTargetSize,
                child: taskBuilder(context, block, taskMarkerRange),
              ),
            ),
          );
        }
      } else {
        final hidePrefix =
            mode == MarkdownEditorMode.live &&
            (block.type == MarkdownBlockType.taskListItem ||
                ((block.type == MarkdownBlockType.heading ||
                        block.type == MarkdownBlockType.blockquote ||
                        block.type == MarkdownBlockType.fencedCode) &&
                    !_isActive(block.range, selection, composing)));
        if (!hidePrefix) {
          spans.add(
            TextSpan(
              text: prefix.slice(source),
              style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
            ),
          );
        }
      }
    }
    if (block.contentRange.length > 0) {
      if (mode == MarkdownEditorMode.live && block.inlineNodes.isNotEmpty) {
        _appendInlineNodes(
          spans,
          document,
          block,
          selection,
          composing,
          linksInteractive,
        );
      } else {
        spans.add(
          TextSpan(
            text: block.contentRange.slice(source),
            style: _contentStyle(block),
          ),
        );
      }
    }
    if (block.contentRange.end < block.range.end) {
      if (block.type == MarkdownBlockType.heading &&
          mode == MarkdownEditorMode.live &&
          !activeBlock) {
        final trailing = source.substring(
          block.contentRange.end,
          block.range.end,
        );
        if (trailing.endsWith('\n')) spans.add(const TextSpan(text: '\n'));
        return;
      }
      final hideTrailing =
          block.type == MarkdownBlockType.fencedCode &&
          mode == MarkdownEditorMode.live &&
          !activeBlock;
      if (hideTrailing) {
        final hasTrailingNewline =
            source.codeUnitAt(block.range.end - 1) == 0x0A;
        if (hasTrailingNewline) {
          spans.add(const TextSpan(text: '\n'));
        }
      } else {
        spans.add(
          TextSpan(
            text: source.substring(block.contentRange.end, block.range.end),
            style: block.type == MarkdownBlockType.fencedCode
                ? theme.codeStyle
                : theme.bodyStyle,
          ),
        );
      }
    }
  }

  void _appendInlineNodes(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
    TextSelection selection,
    TextRange composing,
    bool linksInteractive,
  ) {
    var cursor = block.contentRange.start;
    for (final node in block.inlineNodes) {
      if (cursor < node.range.start) {
        spans.add(
          TextSpan(
            text: document.source.substring(cursor, node.range.start),
            style: _contentStyle(block),
          ),
        );
      }
      _appendInlineNode(
        spans,
        document,
        block,
        node,
        selection,
        composing,
        linksInteractive,
      );
      cursor = node.range.end;
    }
    if (cursor < block.contentRange.end) {
      spans.add(
        TextSpan(
          text: document.source.substring(cursor, block.contentRange.end),
          style: _contentStyle(block),
        ),
      );
    }
  }

  void _appendInlineNode(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
    MarkdownInlineNode node,
    TextSelection selection,
    TextRange composing,
    bool linksInteractive, [
    TextStyle? inheritedStyle,
    TapGestureRecognizer? inheritedRecognizer,
  ]) {
    final baseStyle = inheritedStyle ?? _contentStyle(block);
    if (node.type == MarkdownInlineType.text) {
      spans.add(
        TextSpan(
          text: node.range.slice(document.source),
          style: baseStyle,
          recognizer: inheritedRecognizer,
        ),
      );
      return;
    }
    final isLink = node.type == MarkdownInlineType.link;
    final recognizer = isLink && linksInteractive
        ? _linkRecognizer(node)
        : inheritedRecognizer;
    final active = _isActive(node.range, selection, composing);
    if (active && node.openingRange != null) {
      final opening = node.openingRange!;
      spans.add(
        TextSpan(
          text: opening.slice(document.source),
          style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
        ),
      );
    }
    final contentStyle = _inlineStyle(node.type, baseStyle);
    if (node.type == MarkdownInlineType.softBreak ||
        node.type == MarkdownInlineType.hardBreak) {
      // Break markers (trailing spaces or a backslash) are only shown while
      // the break is being edited; the line ending itself always stays.
      if (active) {
        for (final marker in node.markerRanges) {
          spans.add(
            TextSpan(
              text: marker.slice(document.source),
              style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
            ),
          );
        }
      }
      spans.add(
        TextSpan(
          text: node.contentRange.slice(document.source),
          style: contentStyle,
          recognizer: recognizer,
        ),
      );
      return;
    }
    if (node.children.isEmpty) {
      spans.add(
        TextSpan(
          text: node.contentRange.slice(document.source),
          style: contentStyle,
          recognizer: recognizer,
        ),
      );
    } else {
      var cursor = node.contentRange.start;
      for (final child in node.children) {
        if (cursor < child.range.start) {
          spans.add(
            TextSpan(
              text: document.source.substring(cursor, child.range.start),
              style: contentStyle,
              recognizer: recognizer,
            ),
          );
        }
        _appendInlineNode(
          spans,
          document,
          block,
          child,
          selection,
          composing,
          linksInteractive,
          contentStyle,
          recognizer,
        );
        cursor = child.range.end;
      }
      if (cursor < node.contentRange.end) {
        spans.add(
          TextSpan(
            text: document.source.substring(cursor, node.contentRange.end),
            style: contentStyle,
            recognizer: recognizer,
          ),
        );
      }
    }
    if (active && node.closingRange != null) {
      final closing = node.closingRange!;
      spans.add(
        TextSpan(
          text: closing.slice(document.source),
          style: theme.bodyStyle.copyWith(color: theme.mutedTextColor),
        ),
      );
    }
  }

  TextStyle _contentStyle(MarkdownBlockNode block) => switch (block.type) {
    MarkdownBlockType.heading => theme.headingStyles[(block.level ?? 1) - 1],
    MarkdownBlockType.fencedCode ||
    MarkdownBlockType.indentedCode => theme.codeStyle,
    _ => theme.bodyStyle,
  };

  TapGestureRecognizer _linkRecognizer(MarkdownInlineNode node) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => onLinkTap!(node.destination!);
    _recognizers.add(recognizer);
    return recognizer;
  }

  TextStyle _inlineStyle(MarkdownInlineType type, TextStyle base) =>
      switch (type) {
        MarkdownInlineType.bold => base.copyWith(fontWeight: FontWeight.bold),
        MarkdownInlineType.italic => base.copyWith(fontStyle: FontStyle.italic),
        MarkdownInlineType.strikethrough => base.copyWith(
          decoration: TextDecoration.lineThrough,
        ),
        MarkdownInlineType.highlight => base.copyWith(
          backgroundColor: theme.highlightColor,
        ),
        MarkdownInlineType.code => theme.codeStyle.copyWith(
          backgroundColor: theme.codeBackgroundColor,
        ),
        MarkdownInlineType.link => base.copyWith(
          color: theme.accentColor,
          decoration: TextDecoration.underline,
        ),
        MarkdownInlineType.text ||
        MarkdownInlineType.softBreak ||
        MarkdownInlineType.hardBreak ||
        MarkdownInlineType.image ||
        MarkdownInlineType.extension => base,
      };

  bool _isActive(
    SourceRange range,
    TextSelection selection,
    TextRange composing,
  ) {
    if (selection.isValid) {
      if (_touches(range, selection.baseOffset) ||
          _touches(range, selection.extentOffset) ||
          (!selection.isCollapsed &&
              selection.start <= range.end &&
              range.start < selection.end)) {
        return true;
      }
    }
    return composing.isValid &&
        (_touches(range, composing.start) ||
            _touches(range, composing.end) ||
            (composing.start < range.end && range.start < composing.end));
  }

  bool _touches(SourceRange range, int offset) =>
      offset >= range.start && offset < range.end;

  bool _markerTouched(
    SourceRange range,
    TextSelection selection,
    TextRange composing,
  ) {
    if (selection.isValid &&
        (_touches(range, selection.baseOffset) ||
            _touches(range, selection.extentOffset))) {
      return true;
    }
    return composing.isValid &&
        (_touches(range, composing.start) || _touches(range, composing.end));
  }

  bool _isOrderedMarker(String source, int start, int end) {
    var index = start;
    while (index < end && source.codeUnitAt(index) == 0x20) {
      index++;
    }
    return index < end &&
        source.codeUnitAt(index) >= 0x30 &&
        source.codeUnitAt(index) <= 0x39;
  }

  /// Renders a table block for Live mode: raw source when active, aligned
  /// cells with hidden pipes/separator when inactive.
  void _appendLiveTable(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
    TextSelection selection,
    TextRange composing,
    BuildContext? context,
    MarkdownTaskSpanBuilder? taskBuilder,
    bool linksInteractive,
  ) {
    final source = document.source;
    final data = block.tableData!;
    final active = _isActive(block.range, selection, composing);
    if (active) {
      _appendLiteralTable(spans, document, block);
      return;
    }
    // Build and measure every cell span once per table.
    final cellSpans = <List<InlineSpan>>[];
    var pendingStyleIndex = _tableCellStyleIndex;
    for (
      var dataRowIndex = 0;
      dataRowIndex < data.rows.length;
      dataRowIndex++
    ) {
      final row = data.rows[dataRowIndex];
      for (final cell in row.cells) {
        final cellStyle = _tableCellTextStyle(dataRowIndex, pendingStyleIndex);
        pendingStyleIndex += 1;
        final children = <InlineSpan>[];
        _appendCellInlineNodes(
          children,
          document,
          block,
          cell,
          selection,
          composing,
          linksInteractive,
          cellStyle,
        );
        cellSpans.add(children);
      }
    }
    // Separator row: emit only its newline, after the header row so visual
    // order matches source order.
    final separator = data.separatorRange;
    final separatorEnd =
        separator.end > separator.start &&
            source.codeUnitAt(separator.end - 1) == 0x0A
        ? separator.end - 1
        : separator.end;
    var cellIndex = 0;
    var rowIndex = 0;
    for (final row in data.rows) {
      if (rowIndex == 1 && separatorEnd < separator.end) {
        spans.add(const TextSpan(text: '\n'));
      }
      final currentRow = rowIndex;
      rowIndex++;
      final cells = row.cells;
      if (cells.isEmpty) continue;
      for (var c = 0; c < cells.length; c++, cellIndex++) {
        final cellStyle = _tableCellTextStyle(currentRow, _tableCellStyleIndex);
        _tableCellStyleIndex += 1;
        if (cellSpans[cellIndex].isNotEmpty) {
          spans.add(TextSpan(style: cellStyle, children: cellSpans[cellIndex]));
        }
      }
      if (row.rowRange.end > row.rowRange.start &&
          source.codeUnitAt(row.rowRange.end - 1) == 0x0A) {
        spans.add(const TextSpan(text: '\n'));
      }
    }
  }

  /// Appends a cell's inline nodes within its own content range.
  void _appendCellInlineNodes(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
    MarkdownTableCell cell,
    TextSelection selection,
    TextRange composing,
    bool linksInteractive,
    TextStyle cellStyle,
  ) {
    final source = document.source;
    var cursor = cell.contentRange.start;
    for (final node in cell.inlineNodes) {
      if (cursor < node.range.start) {
        spans.add(
          TextSpan(
            text: source.substring(cursor, node.range.start),
            style: cellStyle,
          ),
        );
      }
      _appendInlineNode(
        spans,
        document,
        block,
        node,
        selection,
        composing,
        linksInteractive,
        cellStyle,
      );
      cursor = node.range.end;
    }
    if (cursor < cell.contentRange.end) {
      spans.add(
        TextSpan(
          text: source.substring(cursor, cell.contentRange.end),
          style: cellStyle,
        ),
      );
    }
  }

  TextStyle _tableCellTextStyle(int row, int styleIndex) {
    final rowStyle = row == 0
        ? theme.tableStyle.headerTextStyle
        : theme.tableStyle.bodyTextStyle;
    final override = styleIndex < _tableCellStyles.length
        ? _tableCellStyles[styleIndex]?.textStyle
        : null;
    return theme.bodyStyle.merge(rowStyle).merge(override);
  }

  void _appendLiteralTable(
    List<InlineSpan> spans,
    MarkdownDocument document,
    MarkdownBlockNode block,
  ) {
    final source = document.source;
    var cursor = block.range.start;
    final rows = block.tableData!.rows;
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      for (final cell in row.cells) {
        if (cursor < cell.contentRange.start) {
          spans.add(
            TextSpan(
              text: source.substring(cursor, cell.contentRange.start),
              style: theme.bodyStyle,
            ),
          );
        }
        spans.add(
          TextSpan(
            text: cell.contentRange.slice(source),
            style: _tableCellTextStyle(rowIndex, _tableCellStyleIndex),
          ),
        );
        _tableCellStyleIndex += 1;
        cursor = cell.contentRange.end;
      }
    }
    if (cursor < block.range.end) {
      spans.add(
        TextSpan(
          text: source.substring(cursor, block.range.end),
          style: theme.bodyStyle,
        ),
      );
    }
  }
}
