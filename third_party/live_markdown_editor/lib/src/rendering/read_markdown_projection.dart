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

typedef MarkdownReadTaskSpanBuilder = Widget Function(
  MarkdownBlockNode block,
  SourceRange markerRange,
);

typedef MarkdownReadMediaBuilder = Widget Function(MarkdownMediaContext media);

final class ReadMarkdownProjection {
  ReadMarkdownProjection({required this.theme, this.onLinkTap});

  final MarkdownEditorThemeData theme;
  final ValueChanged<String>? onLinkTap;
  BuildContext? _readContext;
  final List<TapGestureRecognizer> _recognizers = [];
  List<MarkdownTableCellStyle?> _tableCellStyles = const [];

  void beginBuild({List<MarkdownTableCellStyle?> tableCellStyles = const []}) {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _tableCellStyles = tableCellStyles;
  }

  TextSpan build(
    MarkdownDocument document, {
    List<MarkdownTableCellStyle?> tableCellStyles = const [],
    MarkdownReadTaskSpanBuilder? taskBuilder,
    MarkdownReadMediaBuilder? mediaBuilder,
    TextDirection direction = TextDirection.ltr,
    MarkdownSyntaxConfiguration? syntax,
    Map<String, MarkdownSyntaxSession>? sessions,
    Set<String>? reportedErrors,
    BuildContext? context,
  }) {
    beginBuild(tableCellStyles: tableCellStyles);
    _readContext = context;
    return _treeSpan(
      document,
      taskBuilder: taskBuilder,
      mediaBuilder: mediaBuilder,
      direction: direction,
      syntax: syntax,
      sessions: sessions,
      reportedErrors: reportedErrors,
    );
  }

  TextSpan _treeSpan(
    MarkdownDocument document, {
    MarkdownReadTaskSpanBuilder? taskBuilder,
    MarkdownReadMediaBuilder? mediaBuilder,
    TextDirection direction = TextDirection.ltr,
    MarkdownSyntaxConfiguration? syntax,
    Map<String, MarkdownSyntaxSession>? sessions,
    Set<String>? reportedErrors,
  }) {
    final segments = markdownTreeSegments(
      source: document.source,
      document: document,
      mode: MarkdownEditorMode.read,
      theme: theme,
      syntax: syntax,
      sessions: sessions,
      onExtensionError: syntax?.onExtensionError,
      reportedErrors: reportedErrors,
      textDirection: direction,
    );
    return TextSpan(
      style: theme.bodyStyle,
      children: [
        for (final segment in segments)
          if (segment.kind == MarkdownProjectionSegmentKind.text)
            _treeTextSpan(document, segment)
          else if (segment.kind == MarkdownProjectionSegmentKind.widget)
            _treeTaskSpan(
              document,
              segment,
              taskBuilder,
              mediaBuilder,
              direction,
            ),
      ],
    );
  }

  TextSpan _treeTextSpan(
    MarkdownDocument document,
    MarkdownProjectionSegment segment,
  ) {
    final presentation = _treePresentation(document, segment.sourceRange.start);
    return TextSpan(
      text: segment.text,
      style: presentation.style,
      recognizer: presentation.recognizer,
    );
  }

  InlineSpan _treeTaskSpan(
    MarkdownDocument document,
    MarkdownProjectionSegment segment,
    MarkdownReadTaskSpanBuilder? taskBuilder,
    MarkdownReadMediaBuilder? mediaBuilder,
    TextDirection direction,
  ) {
    if (segment.id case final MarkdownTreeListIndent indent) {
      return WidgetSpan(
        child: SizedBox(
          width: (indent.depth - 1) * theme.taskHitTargetSize / 2,
        ),
      );
    }
    final block = _taskAt(
      document.blocks,
      document.source,
      segment.sourceRange,
    );
    if (block != null && taskBuilder != null) {
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: SizedBox(
          width: theme.taskHitTargetSize,
          child: taskBuilder(block, segment.sourceRange),
        ),
      );
    }
    if (segment.id case final MarkdownExtensionWidgetToken token) {
      final context = _readContext;
      if (context == null) {
        return const WidgetSpan(child: SizedBox.shrink());
      }
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
      return WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);
    }
    final image = _imageAt(document, segment.sourceRange.start);
    if (image != null) {
      final linked = _enclosingLinkDestination(
        document,
        segment.sourceRange.start,
      );
      final media = _mediaContext(
        document,
        image,
        segment.sourceRange,
        linked,
        direction,
      );
      Widget child =
          mediaBuilder?.call(media) ?? DefaultMarkdownMedia(context: media);
      if (linked != null && onLinkTap != null) {
        child = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onLinkTap!(linked),
          child: child,
        );
      }
      return WidgetSpan(alignment: PlaceholderAlignment.middle, child: child);
    }
    return WidgetSpan(child: SizedBox(width: theme.taskHitTargetSize));
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
      mode: MarkdownEditorMode.read,
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
    var style = block == null ? theme.bodyStyle : _blockStyle(block!);
    TapGestureRecognizer? recognizer;
    void findInline(List<MarkdownInlineNode> nodes) {
      for (final node in nodes) {
        if (!node.range.contains(offset)) continue;
        style = _inlineStyle(node.type, style);
        if (node.type == MarkdownInlineType.link && onLinkTap != null) {
          recognizer = TapGestureRecognizer()
            ..onTap = () => onLinkTap!(node.destination!);
          _recognizers.add(recognizer!);
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

  TextStyle _blockStyle(MarkdownBlockNode block) => switch (block.type) {
    MarkdownBlockType.heading => theme.headingStyles[(block.level ?? 1) - 1],
    MarkdownBlockType.fencedCode ||
    MarkdownBlockType.indentedCode => theme.codeStyle,
    _ => theme.bodyStyle,
  };

  TextStyle _tableCellTextStyle(int row, int styleIndex) {
    final rowStyle = row == 0
        ? theme.tableStyle.headerTextStyle
        : theme.tableStyle.bodyTextStyle;
    final override = styleIndex < _tableCellStyles.length
        ? _tableCellStyles[styleIndex]?.textStyle
        : null;
    return theme.bodyStyle.merge(rowStyle).merge(override);
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

  void dispose() {
    beginBuild();
  }
}
