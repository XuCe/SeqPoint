import '../model/source_range.dart';

enum MarkdownBlockType {
  blank,
  paragraph,
  heading,
  blockquote,
  list,
  listItem,
  unorderedListItem,
  orderedListItem,
  taskListItem,
  fencedCode,
  indentedCode,
  horizontalRule,
  table,
  linkDefinition,
  extension,
}

enum MarkdownTableAlignment { start, center, end }

/// Immutable metadata attached to a parsed node by its owning extension.
///
/// The data is range-free so shifting a subtree never needs to rewrite it.
/// [payload] holds rule-defined values and must be immutable.
final class MarkdownExtensionNodeData {
  const MarkdownExtensionNodeData({
    required this.extensionId,
    required this.ruleId,
    this.payload,
  });

  /// The registering extension's globally unique ID.
  final String extensionId;

  /// The rule ID that produced or decorated the node.
  final String ruleId;

  /// Rule-defined metadata; values must be immutable.
  final Map<String, Object?>? payload;

  MarkdownExtensionNodeData withPayload(Map<String, Object?> value) =>
      MarkdownExtensionNodeData(
        extensionId: extensionId,
        ruleId: ruleId,
        payload: value,
      );
}

final class MarkdownTableCell {
  const MarkdownTableCell({
    required this.contentRange,
    this.inlineNodes = const [],
  });

  /// Content range (trimmed; excludes surrounding pipes and whitespace).
  final SourceRange contentRange;
  final List<MarkdownInlineNode> inlineNodes;

  MarkdownTableCell withInlineNodes(List<MarkdownInlineNode> value) =>
      MarkdownTableCell(contentRange: contentRange, inlineNodes: value);

  MarkdownTableCell shift(int delta) => MarkdownTableCell(
    contentRange: contentRange.shift(delta),
    inlineNodes: [for (final node in inlineNodes) node.shift(delta)],
  );
}

final class MarkdownTableRow {
  const MarkdownTableRow({required this.rowRange, required this.cells});

  /// Full source line of the row, including pipes and the trailing newline.
  final SourceRange rowRange;
  final List<MarkdownTableCell> cells;

  MarkdownTableRow withCells(List<MarkdownTableCell> value) =>
      MarkdownTableRow(rowRange: rowRange, cells: value);

  MarkdownTableRow shift(int delta) => MarkdownTableRow(
    rowRange: rowRange.shift(delta),
    cells: [for (final cell in cells) cell.shift(delta)],
  );
}

final class MarkdownTableData {
  const MarkdownTableData({
    required this.columns,
    required this.alignments,
    required this.rows,
    required this.separatorRange,
  });

  final int columns;

  /// Per-column alignment; shorter lists default to
  /// [MarkdownTableAlignment.start].
  final List<MarkdownTableAlignment> alignments;

  /// Content rows: header row first, then body rows. The separator row is
  /// structure, tracked via [separatorRange].
  final List<MarkdownTableRow> rows;

  /// Full source line of the header separator (e.g. `| --- | :---: |`).
  final SourceRange separatorRange;

  MarkdownTableData withRows(List<MarkdownTableRow> value) => MarkdownTableData(
    columns: columns,
    alignments: alignments,
    rows: value,
    separatorRange: separatorRange,
  );

  MarkdownTableData shift(int delta) => MarkdownTableData(
    columns: columns,
    alignments: alignments,
    rows: [for (final row in rows) row.shift(delta)],
    separatorRange: separatorRange.shift(delta),
  );
}

/// One parsed link reference definition, immutable and source-anchored.
final class MarkdownLinkDefinition {
  const MarkdownLinkDefinition({
    required this.label,
    required this.destination,
    required this.title,
    required this.labelRange,
    required this.destinationRange,
    this.titleRange,
  });

  /// The normalized label (trimmed, whitespace collapsed, Unicode
  /// case-folded) that keys the document-wide first-definition-wins index.
  final String label;

  /// The decoded and URI-normalized destination.
  final String destination;

  /// The decoded title, or null when the definition has no title.
  final String? title;

  /// Exact source range of the `[label]` syntax including both brackets.
  final SourceRange labelRange;

  /// Exact source range of the raw destination text.
  final SourceRange destinationRange;

  /// Exact source range of the title including its quotes, when present.
  final SourceRange? titleRange;

  MarkdownLinkDefinition shift(int delta) => MarkdownLinkDefinition(
    label: label,
    destination: destination,
    title: title,
    labelRange: labelRange.shift(delta),
    destinationRange: destinationRange.shift(delta),
    titleRange: titleRange?.shift(delta),
  );
}

final class MarkdownBlockNode {
  const MarkdownBlockNode({
    required this.type,
    required this.range,
    required this.contentRange,
    this.prefixRange,
    this.level,
    this.indent = 0,
    this.checked,
    this.info,
    this.isClosed = true,
    this.markerRanges = const [],
    this.continuationPrefixRanges = const [],
    this.children = const [],
    this.isTight,
    this.contentColumn,
    this.start,
    this.delimiter,
    this.inlineNodes = const [],
    this.tableData,
    this.definition,
    this.extensionData,
  });

  final MarkdownBlockType type;
  final SourceRange range;
  final SourceRange contentRange;
  final SourceRange? prefixRange;
  final int? level;
  final int indent;
  final bool? checked;
  final String? info;
  final bool isClosed;

  /// Source ranges for structural markers owned by this block.
  ///
  /// A block quote can have one range per physical line, while a list item
  /// usually has a single marker range. Keeping them separate from
  /// [contentRange] lets projections hide only the Markdown syntax.
  final List<SourceRange> markerRanges;

  /// Prefixes removed while matching continuation lines in a container.
  /// They remain source-owned syntax and are never removed from the document.
  final List<SourceRange> continuationPrefixRanges;

  /// Nested block structure. Source partitions remain top-level, while this
  /// tree carries semantic containment for parser and extension consumers.
  final List<MarkdownBlockNode> children;

  /// Lists are tight when no item has separated block children.
  final bool? isTight;

  /// Absolute column where [contentRange] begins (indented code blocks with
  /// tab indentation), used to expand partial tabs in rendered content.
  final int? contentColumn;

  /// The first ordinal of an ordered list.
  final int? start;

  /// The marker delimiter of an ordered list (`.` or `)`).
  final String? delimiter;
  final List<MarkdownInlineNode> inlineNodes;
  final MarkdownTableData? tableData;
  final MarkdownLinkDefinition? definition;
  final MarkdownExtensionNodeData? extensionData;

  MarkdownBlockNode withInlineNodes(List<MarkdownInlineNode> value) =>
      MarkdownBlockNode(
        type: type,
        range: range,
        contentRange: contentRange,
        prefixRange: prefixRange,
        level: level,
        indent: indent,
        checked: checked,
        info: info,
        isClosed: isClosed,
        markerRanges: markerRanges,
        continuationPrefixRanges: continuationPrefixRanges,
        children: children,
        isTight: isTight,
        contentColumn: contentColumn,
        start: start,
        delimiter: delimiter,
        inlineNodes: value,
        tableData: tableData,
        definition: definition,
        extensionData: extensionData,
      );

  MarkdownBlockNode withChildren(List<MarkdownBlockNode> value) =>
      MarkdownBlockNode(
        type: type,
        range: range,
        contentRange: contentRange,
        prefixRange: prefixRange,
        level: level,
        indent: indent,
        checked: checked,
        info: info,
        isClosed: isClosed,
        markerRanges: markerRanges,
        continuationPrefixRanges: continuationPrefixRanges,
        children: value,
        isTight: isTight,
        contentColumn: contentColumn,
        start: start,
        delimiter: delimiter,
        inlineNodes: inlineNodes,
        tableData: tableData,
        definition: definition,
        extensionData: extensionData,
      );

  MarkdownBlockNode withContinuationPrefixRanges(List<SourceRange> value) =>
      MarkdownBlockNode(
        type: type,
        range: range,
        contentRange: contentRange,
        prefixRange: prefixRange,
        level: level,
        indent: indent,
        checked: checked,
        info: info,
        isClosed: isClosed,
        markerRanges: markerRanges,
        continuationPrefixRanges: value,
        children: children,
        isTight: isTight,
        contentColumn: contentColumn,
        start: start,
        delimiter: delimiter,
        inlineNodes: inlineNodes,
        tableData: tableData,
        definition: definition,
        extensionData: extensionData,
      );

  MarkdownBlockNode withTableData(MarkdownTableData value) => MarkdownBlockNode(
    type: type,
    range: range,
    contentRange: contentRange,
    prefixRange: prefixRange,
    level: level,
    indent: indent,
    checked: checked,
    info: info,
    isClosed: isClosed,
    markerRanges: markerRanges,
    continuationPrefixRanges: continuationPrefixRanges,
    children: children,
    isTight: isTight,
    contentColumn: contentColumn,
    start: start,
    delimiter: delimiter,
    inlineNodes: inlineNodes,
    tableData: value,
    definition: definition,
    extensionData: extensionData,
  );

  MarkdownBlockNode withExtensionData(MarkdownExtensionNodeData value) =>
      MarkdownBlockNode(
        type: type,
        range: range,
        contentRange: contentRange,
        prefixRange: prefixRange,
        level: level,
        indent: indent,
        checked: checked,
        info: info,
        isClosed: isClosed,
        markerRanges: markerRanges,
        continuationPrefixRanges: continuationPrefixRanges,
        children: children,
        isTight: isTight,
        contentColumn: contentColumn,
        start: start,
        delimiter: delimiter,
        inlineNodes: inlineNodes,
        tableData: tableData,
        definition: definition,
        extensionData: value,
      );

  MarkdownBlockNode shift(int delta) => MarkdownBlockNode(
    type: type,
    range: range.shift(delta),
    contentRange: contentRange.shift(delta),
    prefixRange: prefixRange?.shift(delta),
    level: level,
    indent: indent,
    checked: checked,
    info: info,
    isClosed: isClosed,
    markerRanges: [for (final range in markerRanges) range.shift(delta)],
    continuationPrefixRanges: [
      for (final range in continuationPrefixRanges) range.shift(delta),
    ],
    children: [for (final child in children) child.shift(delta)],
    isTight: isTight,
    contentColumn: contentColumn,
    start: start,
    delimiter: delimiter,
    inlineNodes: [for (final node in inlineNodes) node.shift(delta)],
    tableData: tableData?.shift(delta),
    definition: definition?.shift(delta),
    extensionData: extensionData,
  );
}

enum MarkdownInlineType {
  text,
  softBreak,
  hardBreak,
  bold,
  italic,
  strikethrough,
  highlight,
  code,
  link,
  image,
  extension,
}

final class MarkdownInlineNode {
  const MarkdownInlineNode({
    required this.type,
    required this.range,
    required this.contentRange,
    this.openingRange,
    this.closingRange,
    this.children = const [],
    this.markerRanges = const [],
    this.decodedText,
    this.destination,
    this.title,
    this.extensionData,
  });

  final MarkdownInlineType type;
  final SourceRange range;
  final SourceRange contentRange;
  final SourceRange? openingRange;
  final SourceRange? closingRange;
  final List<MarkdownInlineNode> children;

  /// Exact source ranges that produce structure rather than semantic text.
  ///
  /// Hard breaks use this for their trailing spaces or backslash. Delimiter
  /// nodes continue to expose [openingRange] and [closingRange].
  final List<SourceRange> markerRanges;

  /// Semantic text when it differs from [contentRange]'s literal source.
  ///
  /// Entities, escapes, insecure nulls, and normalized code spans retain their
  /// exact source ranges while exposing the decoded presentation here.
  final String? decodedText;
  final String? destination;
  final String? title;
  final MarkdownExtensionNodeData? extensionData;

  MarkdownInlineNode withChildren(List<MarkdownInlineNode> value) =>
      MarkdownInlineNode(
        type: type,
        range: range,
        contentRange: contentRange,
        openingRange: openingRange,
        closingRange: closingRange,
        children: value,
        markerRanges: markerRanges,
        decodedText: decodedText,
        destination: destination,
        title: title,
        extensionData: extensionData,
      );

  MarkdownInlineNode withExtensionData(MarkdownExtensionNodeData value) =>
      MarkdownInlineNode(
        type: type,
        range: range,
        contentRange: contentRange,
        openingRange: openingRange,
        closingRange: closingRange,
        children: children,
        markerRanges: markerRanges,
        decodedText: decodedText,
        destination: destination,
        title: title,
        extensionData: value,
      );

  MarkdownInlineNode shift(int delta) => MarkdownInlineNode(
    type: type,
    range: range.shift(delta),
    contentRange: contentRange.shift(delta),
    openingRange: openingRange?.shift(delta),
    closingRange: closingRange?.shift(delta),
    children: [for (final child in children) child.shift(delta)],
    markerRanges: [for (final range in markerRanges) range.shift(delta)],
    decodedText: decodedText,
    destination: destination,
    title: title,
    extensionData: extensionData,
  );
}
