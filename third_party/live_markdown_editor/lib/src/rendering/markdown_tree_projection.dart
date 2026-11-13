import 'package:flutter/widgets.dart';

import '../controller/markdown_editor_controller.dart';
import '../extensions/markdown_extension_error.dart';
import '../extensions/markdown_extension_presentation.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_syntax_extension.dart';
import '../foundation/markdown_projection_segment.dart';
import '../foundation/markdown_line_index.dart';
import '../foundation/render_markdown_editable.dart';
import '../model/source_range.dart';
import '../parser/markdown_document.dart';
import '../parser/markdown_node.dart';
import '../theme/markdown_editor_theme_data.dart';

/// Partitions a semantic Markdown tree into a source-backed visual projection.
///
/// Containers contribute only their own syntax ranges; their descendants own
/// semantic content.  This keeps every UTF-16 source position in exactly one
/// segment even when list and quote ranges nest.
List<MarkdownProjectionSegment> markdownTreeSegments({
  required String source,
  required MarkdownDocument document,
  required MarkdownEditorMode mode,
  required MarkdownEditorThemeData theme,
  bool Function(SourceRange range)? active,
  TextSelection? selection,
  TextRange? composing,
  MarkdownSyntaxConfiguration? syntax,
  Map<String, MarkdownSyntaxSession>? sessions,
  MarkdownExtensionErrorListener? onExtensionError,
  Set<String>? reportedErrors,
  TextDirection textDirection = TextDirection.ltr,
  List<SourceRange> foldedRanges = const [],
}) {
  if (source.isEmpty) return const [];
  if (mode == MarkdownEditorMode.raw) {
    return markdownRawSegments(source, foldedRanges);
  }
  return _MarkdownTreeSegmentBuilder(
    foldedRanges: foldedRanges,
    source: source,
    mode: mode,
    theme: theme,
    active: active ?? (_) => false,
    selection: selection,
    composing: composing,
    syntax: syntax,
    sessions: sessions,
    onExtensionError: onExtensionError,
    reportedErrors: reportedErrors,
    textDirection: textDirection,
  ).build(document);
}

/// Whether [range] is exactly a valid Markdown task marker (`[ ]`, `[x]`, or
/// `[X]`). The owning list-prefix parser establishes that the marker is in a
/// task-list position before emitting a widget segment for it.
bool isMarkdownTaskMarker(String source, SourceRange range) =>
    range.length == 3 &&
    range.end <= source.length &&
    source.codeUnitAt(range.start) == 0x5B &&
    (source.codeUnitAt(range.start + 1) == 0x20 ||
        source.codeUnitAt(range.start + 1) == 0x78 ||
        source.codeUnitAt(range.start + 1) == 0x58) &&
    source.codeUnitAt(range.start + 2) == 0x5D;

/// Tree-derived logical indentation for a nested list projection.
final class MarkdownTreeListIndent {
  const MarkdownTreeListIndent(this.depth);

  final int depth;
}

/// Widget-segment identity for an extension widget part.
///
/// Carries the guarded builder and presentation context so the span builders
/// can construct the widget without re-running the extension's presentation
/// hook.
final class MarkdownExtensionWidgetToken {
  const MarkdownExtensionWidgetToken({
    required this.extensionId,
    required this.partId,
    required this.builder,
    required this.context,
    required this.semanticsLabel,
    required this.onActivate,
  });

  final String extensionId;
  final String partId;
  final Widget Function(
    BuildContext context,
    MarkdownExtensionPresentationContext value,
  )
  builder;
  final MarkdownExtensionPresentationContext context;
  final String? semanticsLabel;
  final VoidCallback? onActivate;
}

/// Computes block decorations contributed by extension presentations.
///
/// Runs the same validated presentation pre-pass as [markdownTreeSegments]
/// and converts `MarkdownExtensionBlockDecoration`s into core
/// [MarkdownBlockDecoration]s. Presentation hooks may therefore run once per
/// decoration computation in addition to once per projection build; hooks
/// must stay deterministic.
List<MarkdownBlockDecoration> markdownTreeExtensionDecorations({
  required String source,
  required MarkdownDocument document,
  required MarkdownEditorThemeData theme,
  required MarkdownEditorMode mode,
  TextSelection? selection,
  TextRange? composing,
  MarkdownSyntaxConfiguration? syntax,
  Map<String, MarkdownSyntaxSession>? sessions,
  MarkdownExtensionErrorListener? onExtensionError,
  Set<String>? reportedErrors,
  TextDirection textDirection = TextDirection.ltr,
  List<SourceRange> hiddenRanges = const [],
}) {
  final builder = _MarkdownTreeSegmentBuilder(
    source: source,
    mode: mode,
    theme: theme,
    active: (_) => false,
    selection: selection,
    composing: composing,
    syntax: syntax,
    sessions: sessions,
    onExtensionError: onExtensionError,
    reportedErrors: reportedErrors,
    textDirection: textDirection,
  );
  builder._collectExtensionPresentations(document.blocks);
  return List.unmodifiable([
    for (final entry in builder._extensionDecorations)
      if (!hiddenRanges.any(
        (hidden) =>
            hidden.start <= entry.range.start && entry.range.end <= hidden.end,
      ))
        MarkdownBlockDecoration(
          kind: MarkdownBlockDecorationKind.extension,
          sourceOffset: entry.range.start,
          sourceEnd: entry.range.end,
          color: theme.accentColor,
          textDirection: textDirection,
          nestingLevel: entry.decoration.nestingLevel,
        ),
  ]);
}

final class _MarkdownTreeSegmentBuilder {
  _MarkdownTreeSegmentBuilder({
    required this.source,
    required this.mode,
    this.foldedRanges = const [],
    required this.theme,
    required this.active,
    required this.selection,
    required this.composing,
    required this.syntax,
    required this.sessions,
    required this.onExtensionError,
    required this.reportedErrors,
    required this.textDirection,
  });

  final String source;
  final MarkdownEditorMode mode;
  final List<SourceRange> foldedRanges;
  final MarkdownEditorThemeData theme;
  final bool Function(SourceRange range) active;
  final TextSelection? selection;
  final TextRange? composing;
  final MarkdownSyntaxConfiguration? syntax;
  final Map<String, MarkdownSyntaxSession>? sessions;
  final MarkdownExtensionErrorListener? onExtensionError;
  final Set<String>? reportedErrors;
  final TextDirection textDirection;
  final List<_TreeEdit> _edits = [];
  final Set<int> _textBoundaries = {};
  final Set<String> _extensionWidgetIds = {};

  List<MarkdownProjectionSegment> build(MarkdownDocument document) {
    void collectStyleBoundaries(List<MarkdownBlockNode> blocks) {
      for (final block in blocks) {
        // Text spans resolve presentation from their source start. Split every
        // semantic block boundary before edits are emitted so a visible run
        // cannot inherit the preceding block's style (notably indented code
        // followed by a paragraph).
        _split(block.range);
        _split(block.contentRange);
        collectStyleBoundaries(block.children);
      }
    }

    collectStyleBoundaries(document.blocks);
    _collectExtensionPresentations(document.blocks);
    for (final block in document.blocks) {
      _block(block, inheritedActive: false, listDepth: 0);
    }
    for (final range in foldedRanges) {
      _hide(range);
    }
    _edits.sort((a, b) {
      final start = a.range.start.compareTo(b.range.start);
      if (start != 0) return start;
      final end = b.range.end.compareTo(a.range.end);
      if (end != 0) return end;
      return a.kind.index.compareTo(b.kind.index);
    });

    // Every _split call is done; freeze the boundaries once so emission can
    // walk them in order instead of rescanning the set per text gap.
    final boundaries = _textBoundaries.toList()..sort();

    final segments = <MarkdownProjectionSegment>[];
    var cursor = 0;
    for (final edit in _edits) {
      if (edit.range.end <= cursor || edit.range.start >= source.length) {
        continue;
      }
      final start = edit.range.start < cursor ? cursor : edit.range.start;
      final end = edit.range.end.clamp(start, source.length);
      if (start >= end || start != edit.range.start) continue;
      if (cursor < start) {
        _text(segments, SourceRange(cursor, start), boundaries);
      }
      final range = SourceRange(start, end);
      switch (edit.kind) {
        case _TreeEditKind.hidden:
          segments.add(MarkdownProjectionSegment.hidden(sourceRange: range));
        case _TreeEditKind.widget:
          segments.add(
            MarkdownProjectionSegment.widget(sourceRange: range, id: edit.id),
          );
        case _TreeEditKind.replacement:
          _replacement(segments, range, edit.text!);
      }
      cursor = end;
    }
    if (cursor < source.length) {
      _text(segments, SourceRange(cursor, source.length), boundaries);
    }
    return segments;
  }

  void _block(
    MarkdownBlockNode block, {
    required bool inheritedActive,
    required int listDepth,
  }) {
    final isActive =
        inheritedActive ||
        (mode == MarkdownEditorMode.live && active(block.range));
    switch (block.type) {
      case MarkdownBlockType.linkDefinition:
        // Active Live must reveal the complete definition, including its
        // trailing newline; Read and inactive Live collapse it entirely.
        if (!isActive || mode != MarkdownEditorMode.live) {
          _hide(block.range);
        }
        return;
      case MarkdownBlockType.horizontalRule:
        if (!isActive || mode == MarkdownEditorMode.read) {
          _hideExceptTrailingLineEnding(block.range);
        }
        return;
      case MarkdownBlockType.blockquote:
        final markers = <SourceRange>[...block.markerRanges];
        final prefix = block.prefixRange;
        if (prefix != null) markers.add(prefix);
        _hideAll(markers, unless: isActive);
        for (final child in block.children) {
          _block(child, inheritedActive: isActive, listDepth: listDepth);
        }
        return;
      case MarkdownBlockType.list:
        for (final child in block.children) {
          _block(child, inheritedActive: isActive, listDepth: listDepth + 1);
        }
        return;
      case MarkdownBlockType.listItem:
        _listItem(block, isActive, listDepth);
        for (final child in block.children) {
          _block(child, inheritedActive: isActive, listDepth: listDepth);
        }
        return;
      case MarkdownBlockType.fencedCode:
        if (!isActive || mode == MarkdownEditorMode.read) {
          if (block.prefixRange case final prefix?) {
            _hide(prefix);
          }
          _hideAll(block.continuationPrefixRanges);
          _hideTrailingSyntax(block);
        }
        return;
      case MarkdownBlockType.indentedCode:
        _hideAll(block.markerRanges, unless: isActive);
        _hideAll(block.continuationPrefixRanges, unless: isActive);
        return;
      case MarkdownBlockType.heading:
        if (!isActive || mode == MarkdownEditorMode.read) {
          if (block.prefixRange case final prefix?) _hide(prefix);
          _hideAll(block.markerRanges);
          _hideTrailingSyntax(block);
        }
        _inlineBlock(block, inheritedActive: inheritedActive);
        return;
      case MarkdownBlockType.table:
        if (!isActive || mode == MarkdownEditorMode.read) _table(block);
        for (final row in block.tableData!.rows) {
          for (final cell in row.cells) {
            _inlineNodes(cell.inlineNodes, cell.contentRange, inheritedActive);
          }
        }
        return;
      case MarkdownBlockType.blank:
        return;
      case MarkdownBlockType.extension:
        if (mode == MarkdownEditorMode.read || !isActive) {
          _applyBlockPresentation(block);
        }
        return;
      case MarkdownBlockType.unorderedListItem:
      case MarkdownBlockType.orderedListItem:
      case MarkdownBlockType.taskListItem:
        _listLeaf(block, isActive, listDepth);
        _inlineBlock(block, inheritedActive: inheritedActive);
        return;
      case MarkdownBlockType.paragraph:
        _hideAll(block.continuationPrefixRanges, unless: isActive);
        _inlineBlock(block, inheritedActive: inheritedActive);
        return;
    }
  }

  void _listItem(MarkdownBlockNode block, bool isActive, int listDepth) {
    final marker = block.markerRanges.isEmpty
        ? block.prefixRange
        : block.markerRanges.first;
    if (marker == null) return;
    _split(marker);
    final task = block.checked == null
        ? null
        : _taskMarkerAtPrefix(marker, block.contentRange.end);
    if (task != null) {
      final taskSuffixEnd = _taskSuffixEnd(task.end, block.contentRange.end);
      final indent = _treeIndentRange(marker, task.start, listDepth);
      if (mode == MarkdownEditorMode.read) {
        if (indent != null) {
          _widget(indent, MarkdownTreeListIndent(listDepth));
        }
        final hiddenStart = indent?.end ?? marker.start;
        if (hiddenStart < task.start) {
          _hide(SourceRange(hiddenStart, task.start));
        }
        _widget(task, 'read-task-${task.start}');
        if (task.end < taskSuffixEnd) {
          _hide(SourceRange(task.end, taskSuffixEnd));
        }
      } else if (!_markerTouched(task)) {
        // Ordered prefixes remain visible alongside their task control.
        if (!_isOrdered(source, marker.start, task.start)) {
          if (indent != null) {
            _widget(indent, MarkdownTreeListIndent(listDepth));
          }
          final hiddenStart = indent?.end ?? marker.start;
          if (hiddenStart < task.start) {
            _hide(SourceRange(hiddenStart, task.start));
          }
        }
        _widget(task, 'task-${task.start}');
        if (task.end < taskSuffixEnd) {
          _hide(SourceRange(task.end, taskSuffixEnd));
        }
      }
    } else if (mode == MarkdownEditorMode.read) {
      if (_isOrdered(source, marker.start, marker.end)) {
        // Ordered source already has the correct UTF-16 width.
      } else {
        _replace(marker, _bulletReplacement(marker));
      }
    }
    _hideListContinuations(block, isActive, listDepth);
  }

  void _listLeaf(MarkdownBlockNode block, bool isActive, int listDepth) {
    final prefix = block.prefixRange;
    if (prefix == null) return;
    _split(prefix);
    if (block.type == MarkdownBlockType.taskListItem) {
      _listItem(block, isActive, listDepth);
      return;
    }
    if (mode == MarkdownEditorMode.read &&
        block.type == MarkdownBlockType.unorderedListItem) {
      _replace(prefix, _bulletReplacement(prefix));
    }
  }

  String _bulletReplacement(SourceRange range) {
    // A visible segment cannot change UTF-16 length. Keep any indentation and
    // replace only the first marker character with a bullet.
    final literal = range.slice(source);
    final marker = literal.indexOf(RegExp(r'[-+*]'));
    if (marker < 0) return literal;
    return '${literal.substring(0, marker)}•${literal.substring(marker + 1)}';
  }

  void _inlineBlock(MarkdownBlockNode block, {required bool inheritedActive}) {
    _inlineNodes(block.inlineNodes, block.contentRange, inheritedActive);
  }

  void _inlineNodes(
    List<MarkdownInlineNode> nodes,
    SourceRange range,
    bool inheritedActive,
  ) {
    for (final node in nodes) {
      _inline(node, inheritedActive);
    }
  }

  // ---- Extension presentation -------------------------------------------

  final Map<int, MarkdownExtensionPresentation?> _blockPresentations = {};
  final Map<int, MarkdownExtensionPresentation?> _inlinePresentations = {};
  final List<({SourceRange range, MarkdownExtensionBlockDecoration decoration})>
  _extensionDecorations = [];

  /// Validates presentation parts once per node per build.
  ///
  /// Parts must stay inside the node range, be ordered and non-overlapping,
  /// and preserve source UTF-16 length for visible text. Widget part IDs must
  /// be unique across the whole projection. The first invalid presentation
  /// for a node literalizes that node; duplicate widget IDs literalize the
  /// second owner (first wins).
  String? _validatePresentation(
    MarkdownExtensionPresentation presentation,
    SourceRange nodeRange,
  ) {
    var cursor = nodeRange.start;
    for (final part in presentation.parts) {
      final range = part.sourceRange;
      if (range.start < nodeRange.start || range.end > nodeRange.end) {
        return 'part outside the owning node range';
      }
      if (range.end < range.start) return 'part has an inverted range';
      if (range.start < cursor) return 'parts overlap or are unordered';
      if (part is MarkdownExtensionTextPart &&
          part.text.length != range.length) {
        return 'visible text must preserve its source UTF-16 length';
      }
      cursor = range.end;
    }
    for (final part in presentation.parts) {
      if (part is MarkdownExtensionWidgetPart &&
          !_extensionWidgetIds.add(part.id)) {
        return 'duplicate widget id in one projection';
      }
    }
    return null;
  }

  void _reportExtensionError(
    String extensionId,
    Object error,
    SourceRange? range,
  ) {
    final key =
        'presentation:$extensionId:${range?.start ?? -1}:${range?.end ?? -1}';
    final reported = reportedErrors;
    if (reported != null && !reported.add(key)) return;
    onExtensionError?.call(
      MarkdownExtensionError(
        extensionId: extensionId,
        phase: MarkdownExtensionPhase.presentation,
        error: error,
        sourceRange: range,
      ),
    );
  }

  MarkdownExtensionPresentationContext _presentationContext(
    SourceRange nodeRange,
    String extensionId,
  ) => MarkdownExtensionPresentationContext(
    source: source,
    nodeRange: nodeRange,
    mode: mode,
    activeRange: _activeEditRange(),
    theme: theme,
    textDirection: textDirection,
    session: sessions?[extensionId],
  );

  SourceRange? _activeEditRange() {
    final composing = this.composing;
    if (composing != null && composing.isValid && !composing.isCollapsed) {
      return SourceRange(composing.start, composing.end);
    }
    final selection = this.selection;
    if (selection != null && selection.isValid) {
      return SourceRange(selection.start, selection.end);
    }
    return null;
  }

  MarkdownExtensionPresentation? _presentationFor(MarkdownBlockNode node) {
    final cached = _blockPresentations[node.range.start];
    if (cached != null) return cached;
    final data = node.extensionData;
    final config = syntax;
    if (data == null || config == null) return null;
    final extension = config.extensionById(data.extensionId);
    if (extension == null) return null;
    final context = _presentationContext(node.range, data.extensionId);
    MarkdownExtensionPresentation? presentation;
    try {
      presentation = extension.presentBlock(context, node);
    } catch (error) {
      _reportExtensionError(data.extensionId, error, node.range);
      _blockPresentations[node.range.start] = null;
      return null;
    }
    if (presentation == null) {
      _blockPresentations[node.range.start] = null;
      return null;
    }
    final validation = _validatePresentation(presentation, node.range);
    if (validation != null) {
      _reportExtensionError(data.extensionId, validation, node.range);
      _blockPresentations[node.range.start] = null;
      return null;
    }
    _blockPresentations[node.range.start] = presentation;
    if (presentation.decoration case final decoration?) {
      _extensionDecorations.add((range: node.range, decoration: decoration));
    }
    return presentation;
  }

  MarkdownExtensionPresentation? _presentationForInline(
    MarkdownInlineNode node,
  ) {
    final cached = _inlinePresentations[node.range.start];
    if (cached != null) return cached;
    final data = node.extensionData;
    final config = syntax;
    if (data == null || config == null) return null;
    final extension = config.extensionById(data.extensionId);
    if (extension == null) return null;
    final context = _presentationContext(node.range, data.extensionId);
    MarkdownExtensionPresentation? presentation;
    try {
      presentation = extension.presentInline(context, node);
    } catch (error) {
      _reportExtensionError(data.extensionId, error, node.range);
      _inlinePresentations[node.range.start] = null;
      return null;
    }
    if (presentation == null) {
      _inlinePresentations[node.range.start] = null;
      return null;
    }
    final validation = _validatePresentation(presentation, node.range);
    if (validation != null) {
      _reportExtensionError(data.extensionId, validation, node.range);
      _inlinePresentations[node.range.start] = null;
      return null;
    }
    _inlinePresentations[node.range.start] = presentation;
    return presentation;
  }

  void _applyBlockPresentation(MarkdownBlockNode node) {
    final presentation = _presentationFor(node);
    if (presentation == null) return;
    _emitParts(presentation, node.range, node.extensionData!.extensionId);
  }

  void _applyInlinePresentation(MarkdownInlineNode node) {
    final presentation = _presentationForInline(node);
    if (presentation == null) return;
    _emitParts(presentation, node.range, node.extensionData!.extensionId);
  }

  void _emitParts(
    MarkdownExtensionPresentation presentation,
    SourceRange nodeRange,
    String extensionId,
  ) {
    final context = _presentationContext(nodeRange, extensionId);
    for (final part in presentation.parts) {
      switch (part) {
        case MarkdownExtensionTextPart():
          _replace(part.sourceRange, part.text);
        case MarkdownExtensionHiddenPart():
          _hide(part.sourceRange);
        case MarkdownExtensionWidgetPart():
          final token = MarkdownExtensionWidgetToken(
            extensionId: extensionId,
            partId: part.id,
            builder: part.builder,
            context: context,
            semanticsLabel: presentation.semanticsLabel,
            onActivate: presentation.onActivate,
          );
          _widget(part.sourceRange, token);
      }
    }
  }

  void _collectExtensionPresentations(List<MarkdownBlockNode> blocks) {
    for (final block in blocks) {
      if (block.type == MarkdownBlockType.extension) {
        _presentationFor(block);
      }
      _collectExtensionPresentations(block.children);
      for (final node in block.inlineNodes) {
        _collectInlinePresentations(node);
      }
      if (block.type == MarkdownBlockType.table && block.tableData != null) {
        for (final row in block.tableData!.rows) {
          for (final cell in row.cells) {
            for (final node in cell.inlineNodes) {
              _collectInlinePresentations(node);
            }
          }
        }
      }
    }
  }

  void _collectInlinePresentations(MarkdownInlineNode node) {
    if (node.type == MarkdownInlineType.extension) {
      _presentationForInline(node);
    }
    for (final child in node.children) {
      _collectInlinePresentations(child);
    }
  }

  void _inline(MarkdownInlineNode node, bool inheritedActive) {
    final isActive =
        inheritedActive ||
        (mode == MarkdownEditorMode.live && active(node.range));
    if (node.type == MarkdownInlineType.text) {
      if (!isActive && node.decodedText != null) {
        _replace(node.range, node.decodedText!);
      }
      return;
    }
    if (node.type == MarkdownInlineType.softBreak ||
        node.type == MarkdownInlineType.hardBreak) {
      if (!isActive || mode == MarkdownEditorMode.read) {
        _hideAll(node.markerRanges);
      }
      return;
    }
    if (node.type == MarkdownInlineType.image) {
      // One atomic widget owns the whole image construct. An active Live
      // caret keeps the exact literal source instead.
      if (mode == MarkdownEditorMode.read || !isActive) {
        _widget(node.range, 'image-${node.range.start}');
      }
      return;
    }
    if (node.type == MarkdownInlineType.extension) {
      // The extension owns presentation; without one the node stays literal.
      if (mode == MarkdownEditorMode.read || !isActive) {
        _applyInlinePresentation(node);
      }
      return;
    }
    if (!isActive || mode == MarkdownEditorMode.read) {
      if (node.openingRange case final opening?) _hide(opening);
      if (node.closingRange case final closing?) _hide(closing);
      _hideAll(node.markerRanges);
    }
    if (!isActive && node.decodedText != null) {
      _replace(node.contentRange, node.decodedText!);
    }
    for (final child in node.children) {
      _inline(child, isActive);
    }
  }

  void _hideTrailingSyntax(MarkdownBlockNode block) {
    if (block.contentRange.end >= block.range.end) return;
    _hideExceptTrailingLineEnding(
      SourceRange(block.contentRange.end, block.range.end),
    );
  }

  void _hideExceptTrailingLineEnding(SourceRange range) {
    var end = range.end;
    if (end > range.start && source.codeUnitAt(end - 1) == 0x0A) end--;
    if (range.start < end) _hide(SourceRange(range.start, end));
  }

  void _table(MarkdownBlockNode block) {
    final data = block.tableData!;
    final separator = data.separatorRange;
    _hideExceptTrailingLineEnding(separator);
    for (final row in data.rows) {
      if (row.cells.isEmpty) continue;
      final rowEnd = _lineContentEnd(row.rowRange);
      final first = row.cells.first.contentRange;
      final last = row.cells.last.contentRange;
      if (row.rowRange.start < first.start) {
        _hide(SourceRange(row.rowRange.start, first.start));
      }
      for (var index = 0; index + 1 < row.cells.length; index++) {
        final start = row.cells[index].contentRange.end;
        final end = row.cells[index + 1].contentRange.start;
        if (start < end) _hide(SourceRange(start, end));
      }
      if (last.end < rowEnd) _hide(SourceRange(last.end, rowEnd));
    }
  }

  int _lineContentEnd(SourceRange range) =>
      range.end > range.start && source.codeUnitAt(range.end - 1) == 0x0A
      ? range.end - 1
      : range.end;

  void _text(
    List<MarkdownProjectionSegment> output,
    SourceRange range,
    List<int> boundaries,
  ) {
    if (range.length == 0) return;
    // Boundaries are sorted and unique; find the first one inside the range.
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (boundaries[middle] > range.start) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    var start = range.start;
    for (var index = low; index < boundaries.length; index++) {
      final end = boundaries[index];
      if (end >= range.end) break;
      output.add(
        MarkdownProjectionSegment.text(
          sourceRange: SourceRange(start, end),
          text: source.substring(start, end),
        ),
      );
      start = end;
    }
    output.add(
      MarkdownProjectionSegment.text(
        sourceRange: SourceRange(start, range.end),
        text: source.substring(start, range.end),
      ),
    );
  }

  void _split(SourceRange range) {
    _textBoundaries
      ..add(range.start)
      ..add(range.end);
  }

  void _replacement(
    List<MarkdownProjectionSegment> output,
    SourceRange range,
    String text,
  ) {
    if (range.length == 0) return;
    if (text.length >= range.length) {
      output.add(
        MarkdownProjectionSegment.text(sourceRange: range, text: text),
      );
      return;
    }
    if (text.isNotEmpty) {
      output.add(
        MarkdownProjectionSegment.text(
          sourceRange: SourceRange(range.start, range.start + text.length),
          text: text,
        ),
      );
    }
    final hiddenStart = range.start + text.length;
    if (hiddenStart < range.end) {
      output.add(
        MarkdownProjectionSegment.hidden(
          sourceRange: SourceRange(hiddenStart, range.end),
        ),
      );
    }
  }

  void _hide(SourceRange range, {bool unless = false}) {
    if (unless) return;
    if (range.length > 0) _edits.add(_TreeEdit.hidden(range));
  }

  void _hideAll(List<SourceRange> ranges, {bool unless = false}) {
    for (final range in ranges) {
      _hide(range, unless: unless);
    }
  }

  void _widget(SourceRange range, Object id) {
    if (range.length > 0) _edits.add(_TreeEdit.widget(range, id));
  }

  void _replace(SourceRange range, String text) {
    if (range.length > 0) _edits.add(_TreeEdit.replacement(range, text));
  }

  bool _isOrdered(String text, int start, int end) {
    var index = start;
    while (index < end && text.codeUnitAt(index) == 0x20) {
      index++;
    }
    return index < end &&
        text.codeUnitAt(index) >= 0x30 &&
        text.codeUnitAt(index) <= 0x39;
  }

  int _taskSuffixEnd(int start, int limit) {
    var end = start;
    while (end < limit) {
      final unit = source.codeUnitAt(end);
      if (unit != 0x20 && unit != 0x09) break;
      end++;
    }
    return end;
  }

  SourceRange? _treeIndentRange(
    SourceRange marker,
    int taskStart,
    int listDepth,
  ) {
    if (listDepth < 2 || marker.start >= taskStart) return null;
    var end = marker.start;
    while (end < taskStart && _isWhitespace(source.codeUnitAt(end))) {
      end++;
    }
    if (end == marker.start) end = marker.start + 1;
    return SourceRange(marker.start, end);
  }

  void _hideListContinuations(
    MarkdownBlockNode block,
    bool isActive,
    int listDepth,
  ) {
    if (isActive) return;
    for (final range in block.continuationPrefixRanges) {
      if (listDepth > 1 && range.length > 0) {
        _widget(range, MarkdownTreeListIndent(listDepth));
      } else {
        _hide(range);
      }
    }
  }

  /// Whether a caret/composing edge touches [range], mirroring the
  /// pre-tree marker semantics: a caret at the marker's inclusive end still
  /// reveals it, while a document-wide selection must not literalize every
  /// task marker.
  bool _markerTouched(SourceRange range) {
    final selection = this.selection;
    if (selection != null &&
        selection.isValid &&
        (_touches(range, selection.baseOffset) ||
            _touches(range, selection.extentOffset))) {
      return true;
    }
    final composing = this.composing;
    return composing != null &&
        composing.isValid &&
        (_touches(range, composing.start) || _touches(range, composing.end));
  }

  static bool _touches(SourceRange range, int offset) =>
      offset >= range.start && offset <= range.end;

  SourceRange? _taskMarkerAtPrefix(SourceRange marker, int limit) {
    var cursor = marker.start;
    while (cursor < limit && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    while (cursor < marker.end && source.codeUnitAt(cursor) == 0x3E) {
      cursor++;
      while (cursor < limit && _isWhitespace(source.codeUnitAt(cursor))) {
        cursor++;
      }
    }
    if (cursor >= limit) return null;
    final first = source.codeUnitAt(cursor);
    if (first == 0x2D || first == 0x2B || first == 0x2A) {
      cursor++;
    } else {
      final digitStart = cursor;
      while (cursor < limit && _isAsciiDigit(source.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor == digitStart ||
          cursor >= limit ||
          (source.codeUnitAt(cursor) != 0x2E &&
              source.codeUnitAt(cursor) != 0x29)) {
        return null;
      }
      cursor++;
    }
    if (cursor >= limit || !_isWhitespace(source.codeUnitAt(cursor))) {
      return null;
    }
    while (cursor < limit && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    final task = SourceRange(cursor, cursor + 3);
    if (task.end > limit || !isMarkdownTaskMarker(source, task)) return null;
    if (task.end < limit && !_isWhitespace(source.codeUnitAt(task.end))) {
      return null;
    }
    return task;
  }

  bool _isWhitespace(int unit) => unit == 0x20 || unit == 0x09;

  bool _isAsciiDigit(int unit) => unit >= 0x30 && unit <= 0x39;
}

/// Raw-mode segments: the exact source, minus any folded ranges.
///
/// Raw stays byte-identical to the source while nothing is folded; folding a
/// block hides exactly its range, and the remaining text segments keep the
/// projection ordered and gap-free.
List<MarkdownProjectionSegment> markdownRawSegments(
  String source,
  List<SourceRange> foldedRanges,
) {
  if (foldedRanges.isEmpty) {
    return [
      MarkdownProjectionSegment.text(
        sourceRange: SourceRange(0, source.length),
        text: source,
      ),
    ];
  }
  final ordered = [...foldedRanges]
    ..sort((left, right) => left.start.compareTo(right.start));
  final segments = <MarkdownProjectionSegment>[];
  var cursor = 0;
  for (final range in ordered) {
    final start = range.start.clamp(cursor, source.length);
    final end = range.end.clamp(start, source.length);
    if (start > cursor) {
      segments.add(
        MarkdownProjectionSegment.text(
          sourceRange: SourceRange(cursor, start),
          text: source.substring(cursor, start),
        ),
      );
    }
    if (end > start) {
      segments.add(
        MarkdownProjectionSegment.hidden(sourceRange: SourceRange(start, end)),
      );
    }
    cursor = end;
  }
  if (cursor < source.length) {
    segments.add(
      MarkdownProjectionSegment.text(
        sourceRange: SourceRange(cursor, source.length),
        text: source.substring(cursor),
      ),
    );
  }
  return List.unmodifiable(segments);
}

/// Splits a blockquote's content range into its physical source lines.
///
/// Hierarchical blockquotes span hard lines; quote decorations are painted
/// per hard line so each gutter keeps the resolved direction of its own text
/// (a quote holding both LTR and RTL lines keeps both gutters, matching the
/// per-line quote nodes the flat parser used to produce). Each returned entry
/// intersects the quote content range with one source line and carries that
/// line's zero-based index.
List<({int start, int end, int lineIndex})> markdownQuoteLineRanges(
  String source,
  MarkdownBlockNode blockquote,
  List<int> lineStarts,
) {
  final rangeStart = blockquote.contentRange.start;
  final rangeEnd = blockquote.contentRange.end;
  final ranges = <({int start, int end, int lineIndex})>[];
  if (rangeStart >= rangeEnd) return ranges;
  var lineIndex = markdownLineIndexFor(lineStarts, rangeStart);
  while (lineIndex < lineStarts.length) {
    final lineStart = lineStarts[lineIndex];
    if (lineStart >= rangeEnd) break;
    final nextStart = lineIndex + 1 < lineStarts.length
        ? lineStarts[lineIndex + 1]
        : source.length + 1;
    final lineEnd = nextStart - 1 > rangeEnd ? rangeEnd : nextStart - 1;
    final start = lineStart < rangeStart ? rangeStart : lineStart;
    if (start < lineEnd) {
      ranges.add((start: start, end: lineEnd, lineIndex: lineIndex));
    }
    lineIndex++;
  }
  return ranges;
}

enum _TreeEditKind { hidden, widget, replacement }

final class _TreeEdit {
  const _TreeEdit.hidden(this.range)
    : kind = _TreeEditKind.hidden,
      text = null,
      id = null;
  const _TreeEdit.widget(this.range, this.id)
    : kind = _TreeEditKind.widget,
      text = null;
  const _TreeEdit.replacement(this.range, this.text)
    : kind = _TreeEditKind.replacement,
      id = null;

  final SourceRange range;
  final _TreeEditKind kind;
  final String? text;
  final Object? id;
}
