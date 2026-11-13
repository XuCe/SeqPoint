import '../model/source_range.dart';
import '../extensions/markdown_extension_error.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_parse_context.dart';
import '../extensions/markdown_syntax_extension.dart';
import 'inline_parser.dart';
import 'block_parser_state.dart';
import 'markdown_document.dart';
import 'markdown_node.dart';
import 'markdown_source_scanner.dart';
import 'link_reference.dart';
import 'table_scanner.dart';

final class MarkdownBlockParser {
  const MarkdownBlockParser({
    this.syntax = const MarkdownSyntaxConfiguration.editorDefaults(),
  });

  final MarkdownSyntaxConfiguration syntax;

  static const MarkdownInlineParser _inlineParser = MarkdownInlineParser();

  static final RegExp _heading = RegExp(r'^( {0,3})(#{1,6})(?:[ \t]+|$)');
  static final RegExp _setextHeading = RegExp(r'^ {0,3}(=+|-+)[ \t]*$');
  static final RegExp _fence = RegExp(
    r'^( {0,3})(`{3,}(?![^`\r\n]*`)|~{3,})(.*)$',
  );
  static final RegExp _rule = RegExp(
    r'^( {0,3})((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$',
  );

  MarkdownDocument parse(
    String source, {
    Map<String, MarkdownLinkDefinition>? externalDefinitions,
  }) {
    syntax.validate();
    final grammar = syntax.grammar;
    final blocks = _parseCommonMarkContainers(
      source,
      grammar,
      externalDefinitions,
    );
    final decorated = grammar.decorators.isEmpty
        ? blocks
        : _decorateBlockTree(blocks, grammar);
    return MarkdownDocument(
      source: source,
      blocks: List.unmodifiable(decorated),
      checkpoints: MarkdownBlockParserState.checkpointsFor(decorated),
      definitions: MarkdownDocument.definitionsFor(decorated),
    );
  }

  /// Merges region-local definitions with an external index, keeping the
  /// external (earlier-source) definitions first so first-definition-wins
  /// holds across the combined document.
  Map<String, MarkdownLinkDefinition> _mergedDefinitions(
    Map<String, MarkdownLinkDefinition> local,
    Map<String, MarkdownLinkDefinition>? external,
  ) {
    if (external == null || external.isEmpty) return local;
    final merged = <String, MarkdownLinkDefinition>{};
    for (final entry in external.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
    for (final entry in local.entries) {
      merged.putIfAbsent(entry.key, () => entry.value);
    }
    return merged;
  }

  List<MarkdownBlockNode> _parseCommonMarkContainers(
    String source,
    MarkdownResolvedGrammar grammar, [
    Map<String, MarkdownLinkDefinition>? externalDefinitions,
  ]) {
    final views = [
      for (final line in MarkdownSourceScanner(source).lines)
        _ContainerLine(line: line, start: line.start, contentStart: line.start),
    ];
    final blocks = _parseContainerLines(
      views,
      source,
      const MarkdownContainerParserState(),
      grammar,
      0,
    );
    final definitions = _mergedDefinitions(
      MarkdownDocument.definitionsFor(blocks),
      externalDefinitions,
    );
    return [
      for (final block in blocks)
        _attachInlineNodes(block, source, const [], definitions, grammar),
    ];
  }

  MarkdownBlockNode _attachInlineNodes(
    MarkdownBlockNode block,
    String source,
    List<SourceRange> ancestorPrefixes,
    Map<String, MarkdownLinkDefinition> definitions, [
    MarkdownResolvedGrammar grammar = const MarkdownResolvedGrammar(),
  ]) {
    final prefixes = [
      ...ancestorPrefixes,
      ...block.markerRanges,
      ...block.continuationPrefixRanges,
    ];
    final children = [
      for (final child in block.children)
        _attachInlineNodes(child, source, prefixes, definitions, grammar),
    ];
    if (!_supportsInlineParsing(block.type) || block.children.isNotEmpty) {
      return block.withChildren(children);
    }
    if (block.type == MarkdownBlockType.table) {
      return block.withTableData(
        block.tableData!.withRows([
          for (final row in block.tableData!.rows)
            row.withCells([
              for (final cell in row.cells)
                cell.withInlineNodes(
                  _parseInlineSegments(
                    cell.contentRange,
                    prefixes,
                    source,
                    definitions,
                    grammar,
                  ),
                ),
            ]),
        ]),
      );
    }
    return block
        .withChildren(children)
        .withInlineNodes(
          _parseInlineSegments(
            block.contentRange,
            prefixes,
            source,
            definitions,
            grammar,
          ),
        );
  }

  List<MarkdownInlineNode> _parseInlineSegments(
    SourceRange contentRange,
    List<SourceRange> prefixes,
    String source,
    Map<String, MarkdownLinkDefinition> definitions,
    MarkdownResolvedGrammar grammar,
  ) {
    final excluded = [
      for (final prefix in prefixes)
        if (prefix.intersects(contentRange))
          SourceRange(
            prefix.start < contentRange.start
                ? contentRange.start
                : prefix.start,
            prefix.end > contentRange.end ? contentRange.end : prefix.end,
          ),
    ]..sort((left, right) => left.start.compareTo(right.start));
    final nodes = <MarkdownInlineNode>[];
    var cursor = contentRange.start;
    for (final prefix in excluded) {
      if (cursor < prefix.start) {
        nodes.addAll(
          _inlineParser.parse(
            source.substring(cursor, prefix.start),
            sourceOffset: cursor,
            definitions: definitions,
            grammar: grammar,
            fullSource: source,
          ),
        );
      }
      if (prefix.end > cursor) cursor = prefix.end;
    }
    if (cursor < contentRange.end) {
      nodes.addAll(
        _inlineParser.parse(
          source.substring(cursor, contentRange.end),
          sourceOffset: cursor,
          definitions: definitions,
          grammar: grammar,
          fullSource: source,
        ),
      );
    }
    return List.unmodifiable(nodes);
  }

  List<MarkdownBlockNode> _parseContainerLines(
    List<_ContainerLine> lines,
    String source,
    MarkdownContainerParserState state,
    MarkdownResolvedGrammar grammar,
    int extensionDepth,
  ) {
    final blocks = <MarkdownBlockNode>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      final text = line.text(source);
      if (text.trim().isEmpty) {
        blocks.add(
          MarkdownBlockNode(
            type: MarkdownBlockType.blank,
            range: SourceRange(line.start, line.end),
            contentRange: SourceRange(line.contentStart, line.contentEnd),
          ),
        );
        index++;
        continue;
      }

      final definition = _tryContainerDefinition(lines, index, source);
      if (definition != null) {
        blocks.add(definition.block);
        index = definition.nextIndex;
        continue;
      }

      final setext = _tryContainerSetext(lines, index, source);
      if (setext != null) {
        blocks.add(setext.block);
        index = setext.nextIndex;
        continue;
      }

      final quote = line.literalContainers ? null : _quoteAt(line, source);
      if (quote != null && state.canOpenContainer) {
        final prefixRanges = <SourceRange>[];
        final childrenLines = <_ContainerLine>[];
        final first = line;
        var last = line;
        var sawBlank = false;
        var lastQuoteAllowsLazyContinuation = false;
        while (index < lines.length) {
          final candidate = lines[index];
          final marker = _quoteAt(candidate, source);
          if (marker != null) {
            final markerEnd = candidate.contentStart + marker.end;
            final markerText = source.substring(
              candidate.contentStart,
              markerEnd,
            );
            // The marker consumes one column per space and one column for a
            // trailing tab; a trailing tab's raw span stays in the content so
            // its remaining columns expand there.
            final contentStart = markerText.endsWith('\t')
                ? markerEnd - 1
                : markerEnd;
            prefixRanges.add(SourceRange(candidate.start, contentStart));
            childrenLines.add(
              candidate.withContentStart(
                contentStart,
                column: candidate.column + markerText.length,
              ),
            );
            final content = candidate.textFrom(markerEnd, source);
            sawBlank = content.trim().isEmpty;
            lastQuoteAllowsLazyContinuation = _canLazyContinuation(content);
            last = candidate;
            index++;
            continue;
          }
          if (candidate.text(source).trim().isEmpty ||
              sawBlank ||
              !lastQuoteAllowsLazyContinuation ||
              _startsContainerBlock(candidate, source)) {
            break;
          }
          // A non-blank paragraph continuation can be lazy inside a quote.
          childrenLines.add(candidate.asLazy());
          last = candidate;
          index++;
        }
        final children = _parseContainerLines(
          childrenLines,
          source,
          state.nested,
          grammar,
          extensionDepth,
        );
        blocks.add(
          MarkdownBlockNode(
            type: MarkdownBlockType.blockquote,
            range: SourceRange(first.start, last.end),
            contentRange: SourceRange(
              childrenLines.first.contentStart,
              last.contentEnd,
            ),
            prefixRange: prefixRanges.first,
            markerRanges: List.unmodifiable(prefixRanges),
            children: List.unmodifiable(children),
          ),
        );
        continue;
      }

      if (_rule.hasMatch(text)) {
        blocks.add(
          MarkdownBlockNode(
            type: MarkdownBlockType.horizontalRule,
            range: SourceRange(line.start, line.end),
            contentRange: SourceRange(line.contentStart, line.contentEnd),
          ),
        );
        index++;
        continue;
      }

      final marker = line.literalContainers
          ? null
          : _listMarkerAt(line, source);
      if (marker != null && state.canOpenContainer) {
        if ((marker.isBlank || (marker.ordered && marker.ordinal != 1)) &&
            blocks.isNotEmpty &&
            blocks.last.type == MarkdownBlockType.paragraph &&
            blocks.last.range.end == line.start) {
          final paragraph = blocks.removeLast();
          blocks.add(
            MarkdownBlockNode(
              type: MarkdownBlockType.paragraph,
              range: SourceRange(paragraph.range.start, line.end),
              contentRange: SourceRange(
                paragraph.contentRange.start,
                line.contentEnd,
              ),
            ),
          );
          index++;
          continue;
        }
        final parsed = _parseList(
          lines,
          index,
          source,
          state,
          marker,
          grammar,
          extensionDepth,
        );
        blocks.add(parsed.block);
        index = parsed.nextIndex;
        continue;
      }

      final fence = _fence.firstMatch(text);
      if (fence != null) {
        final parsed = _parseContainerFence(lines, index, source, fence);
        blocks.add(parsed.block);
        index = parsed.nextIndex;
        continue;
      }

      final heading = _heading.firstMatch(text);
      if (heading != null) {
        final overrideRules = grammar.headingOverrideRules;
        if (overrideRules == null) {
          final prefixEnd = line.contentStart + heading.end;
          blocks.add(
            MarkdownBlockNode(
              type: MarkdownBlockType.heading,
              range: SourceRange(line.start, line.end),
              contentRange: SourceRange(
                prefixEnd,
                _atxContentEnd(source, prefixEnd, line.contentEnd),
              ),
              prefixRange: SourceRange(line.start, prefixEnd),
              level: heading.group(2)!.length,
            ),
          );
          index++;
          continue;
        }
        final override = _matchBlockRules(
          _containerBlockContext(lines, index, source, grammar, extensionDepth),
          overrideRules,
          grammar,
        );
        if (override != null) {
          blocks.add(override.block);
          index = override.nextIndex;
          continue;
        }
      }

      if (_indentColumns(line, source) >= 4) {
        final parsed = _parseContainerIndentedCode(lines, index, source);
        blocks.add(parsed.block);
        index = parsed.nextIndex;
        continue;
      }

      if (grammar.blockFallbackRules.isNotEmpty) {
        final extensionBlock = _matchBlockRules(
          _containerBlockContext(lines, index, source, grammar, extensionDepth),
          grammar.blockFallbackRules,
          grammar,
        );
        if (extensionBlock != null) {
          blocks.add(extensionBlock.block);
          index = extensionBlock.nextIndex;
          continue;
        }
      }
      final first = line;
      var last = line;
      index++;
      while (index < lines.length) {
        final candidate = lines[index];
        if (candidate.text(source).trim().isEmpty ||
            (_startsContainerBlock(candidate, source) &&
                _indentColumns(candidate, source) < 4) ||
            (syntax.baseProfile == MarkdownSyntaxProfile.editorDefaults &&
                index + 1 < lines.length &&
                _isTableStart(
                  candidate.text(source),
                  lines[index + 1].text(source),
                ))) {
          break;
        }
        last = candidate;
        index++;
      }
      blocks.add(
        MarkdownBlockNode(
          type: MarkdownBlockType.paragraph,
          range: SourceRange(first.start, last.end),
          contentRange: SourceRange(first.contentStart, last.contentEnd),
        ),
      );
    }
    return blocks;
  }

  ({MarkdownBlockNode block, int nextIndex})? _tryContainerDefinition(
    List<_ContainerLine> lines,
    int index,
    String source,
  ) {
    final first = lines[index];
    if (!RegExp(r'^ {0,3}\[', multiLine: false).hasMatch(first.text(source))) {
      return null;
    }
    final scan = const MarkdownLinkReferenceScanner().scanDefinition(
      source,
      index,
      lines.length,
      contentRange: (lineIndex) => SourceRange(
        lines[lineIndex].contentStart,
        lines[lineIndex].contentEnd,
      ),
      canInclude: (lineIndex) =>
          lines[lineIndex].text(source).trim().isNotEmpty &&
          !(_startsContainerBlock(lines[lineIndex], source) &&
              _indentColumns(lines[lineIndex], source) < 4),
    );
    if (scan == null) return null;
    final last = lines[index + scan.linesConsumed - 1];
    return (
      block: MarkdownBlockNode(
        type: MarkdownBlockType.linkDefinition,
        range: SourceRange(first.start, last.end),
        contentRange: SourceRange(first.contentStart, last.contentEnd),
        definition: scan.definition,
      ),
      nextIndex: index + scan.linesConsumed,
    );
  }

  ({MarkdownBlockNode block, int nextIndex})? _tryContainerSetext(
    List<_ContainerLine> lines,
    int index,
    String source,
  ) {
    final first = lines[index];
    final firstText = first.text(source);
    if (firstText.trim().isEmpty || _startsContainerBlock(first, source)) {
      return null;
    }
    var last = first;
    var scan = index;
    while (scan + 1 < lines.length) {
      final next = lines[scan + 1];
      final nextText = next.text(source);
      final underline = _setextHeading.firstMatch(nextText);
      if (syntax.baseProfile == MarkdownSyntaxProfile.editorDefaults &&
          MarkdownTableScanner.scanRow(
            firstText,
            0,
            firstText.length,
          ).hasPipe &&
          MarkdownTableScanner.isSeparatorRow(nextText, 0, nextText.length)) {
        return null;
      }
      if (underline != null && !next.lazy) {
        var contentEnd = last.contentEnd;
        while (contentEnd > first.contentStart &&
            (source.codeUnitAt(contentEnd - 1) == 0x20 ||
                source.codeUnitAt(contentEnd - 1) == 0x09)) {
          contentEnd--;
        }
        return (
          block: MarkdownBlockNode(
            type: MarkdownBlockType.heading,
            range: SourceRange(first.start, next.end),
            contentRange: SourceRange(first.contentStart, contentEnd),
            markerRanges: [SourceRange(contentEnd, next.contentEnd)],
            level: underline.group(1)![0] == '=' ? 1 : 2,
          ),
          nextIndex: scan + 2,
        );
      }
      if (nextText.trim().isEmpty || _startsContainerBlock(next, source)) {
        return null;
      }
      last = next;
      scan++;
    }
    return null;
  }

  ({MarkdownBlockNode block, int nextIndex}) _parseList(
    List<_ContainerLine> lines,
    int index,
    String source,
    MarkdownContainerParserState state,
    _ListMarker firstMarker,
    MarkdownResolvedGrammar grammar,
    int extensionDepth,
  ) {
    final items = <MarkdownBlockNode>[];
    final first = lines[index];
    var last = first;
    var loose = false;
    var maximumSiblingIndent = firstMarker.indent;
    var lastItemStart = index;
    while (index < lines.length) {
      final itemStart = lines[index];
      final marker = _listMarkerAt(itemStart, source);
      if (marker == null ||
          !marker.isSameListAs(firstMarker) ||
          (state.depth != 0 && marker.indent != firstMarker.indent)) {
        // A marker at the list's content indent continues the last item as
        // a nested list instead of starting a sibling item.
        if (marker != null &&
            items.isNotEmpty &&
            itemStart.column + marker.indent >= firstMarker.contentIndent) {
          index = lastItemStart;
          final reParsed = _parseListItem(
            lines,
            index,
            source,
            state,
            firstMarker,
            maximumSiblingIndent,
            grammar,
            extensionDepth,
          );
          items[items.length - 1] = reParsed.item;
          loose = loose || reParsed.isLoose;
          last = lines[reParsed.nextIndex - 1];
          index = reParsed.nextIndex;
          continue;
        }
        break;
      }
      lastItemStart = index;
      final parsed = _parseListItem(
        lines,
        index,
        source,
        state,
        marker,
        maximumSiblingIndent,
        grammar,
        extensionDepth,
      );
      items.add(parsed.item);
      loose = loose || parsed.isLoose;
      last = lines[parsed.nextIndex - 1];
      index = parsed.nextIndex;
      maximumSiblingIndent = marker.indent;
      if (index >= lines.length) break;
      final candidate = lines[index];
      // A thematic break can never be a list item; it closes the list.
      if (_rule.hasMatch(candidate.text(source))) break;
      final next = _listMarkerAt(candidate, source);
      if (next == null || !next.isSameListAs(firstMarker)) break;
    }
    return (
      block: MarkdownBlockNode(
        type: MarkdownBlockType.list,
        range: SourceRange(first.start, last.end),
        contentRange: SourceRange(first.contentStart, last.contentEnd),
        markerRanges: List.unmodifiable([
          for (final item in items) ...item.markerRanges,
        ]),
        children: List.unmodifiable(items),
        isTight: !loose,
        start: firstMarker.ordinal,
        delimiter: firstMarker.delimiter,
      ),
      nextIndex: index,
    );
  }

  ({MarkdownBlockNode item, int nextIndex, bool isLoose}) _parseListItem(
    List<_ContainerLine> lines,
    int index,
    String source,
    MarkdownContainerParserState state,
    _ListMarker marker,
    int maximumSiblingIndent,
    MarkdownResolvedGrammar grammar,
    int extensionDepth,
  ) {
    final first = lines[index];
    final task = grammar.taskSlotRules.isEmpty
        ? null
        : _matchBlockRules(
            _containerBlockContext(
              lines,
              index,
              source,
              grammar,
              extensionDepth,
            ),
            grammar.taskSlotRules,
            grammar,
          );
    final childLines = <_ContainerLine>[
      first.withContentStart(
        marker.contentStart,
        column: first.column + marker.contentIndent,
      ),
    ];
    final contentIndent = marker.contentIndent - first.column;
    final continuationPrefixes = <SourceRange>[];
    var lastChildAllowsLazyContinuation = _allowsListLazyContinuation(
      first.withContentStart(marker.contentStart),
      source,
    );
    var last = first;
    var sawBlank = false;
    var blankFollowedIndentedContent = false;
    index++;
    while (index < lines.length) {
      final candidate = lines[index];
      final sibling = _listMarkerAt(candidate, source);
      final siblingIndent = _indentColumns(candidate, source);
      final isSibling =
          sibling != null &&
          sibling.isSameListAs(marker) &&
          (state.depth == 0
              ? siblingIndent <= 3 && siblingIndent <= maximumSiblingIndent + 1
              : sibling.indent == marker.indent &&
                    siblingIndent < marker.contentIndent);
      if (isSibling) {
        break;
      }
      if (state.depth == 0 &&
          sibling != null &&
          sibling.isSameListAs(marker) &&
          siblingIndent >= 4) {
        final contentStart = _advanceColumns(candidate, source, siblingIndent);
        continuationPrefixes.add(SourceRange(candidate.start, contentStart));
        final child = candidate.withContentStart(
          contentStart,
          literalContainers: true,
        );
        childLines.add(child);
        lastChildAllowsLazyContinuation = _allowsListLazyContinuation(
          child,
          source,
        );
        last = candidate;
        index++;
        continue;
      }
      if (candidate.text(source).trim().isEmpty) {
        childLines.add(candidate);
        lastChildAllowsLazyContinuation = false;
        sawBlank = true;
        last = candidate;
        index++;
        continue;
      }
      if (marker.isBlank && sawBlank) break;
      final columns = _indentColumns(candidate, source);
      if (sawBlank &&
          columns >= contentIndent &&
          _listMarkerAt(candidate, source) == null &&
          _quoteAt(candidate, source) == null) {
        blankFollowedIndentedContent = true;
      }
      if (columns >= contentIndent &&
          !(sawBlank && marker.hasTabPadding && columns == contentIndent)) {
        final contentStart = _advanceColumns(
          candidate,
          source,
          candidate.column + contentIndent,
        );
        continuationPrefixes.add(SourceRange(candidate.start, contentStart));
        final child = candidate.withContentStart(
          contentStart,
          column: candidate.column + contentIndent,
        );
        childLines.add(child);
        lastChildAllowsLazyContinuation = _allowsListLazyContinuation(
          child,
          source,
        );
        last = candidate;
        index++;
        continue;
      }
      final isIndentedOnly =
          _indentColumns(candidate, source) >= 4 &&
          _quoteAt(candidate, source) == null &&
          _listMarkerAt(candidate, source) == null &&
          !_fence.hasMatch(candidate.text(source)) &&
          !_heading.hasMatch(candidate.text(source)) &&
          !_rule.hasMatch(candidate.text(source));
      final isOverIndentedListMarker = RegExp(r'^ {4,}[-+*][ \t]+')
          .hasMatch(candidate.text(source));
      final nestedMarker = _listMarkerAt(candidate, source);
      final nestedAtContentColumn =
          nestedMarker != null &&
          candidate.column + nestedMarker.indent >= marker.contentIndent;
      if (marker.isBlank ||
          (sawBlank &&
              (columns < contentIndent ||
                  (marker.hasTabPadding && columns == contentIndent))) ||
          (!sawBlank && !lastChildAllowsLazyContinuation && columns == 0) ||
          (_startsContainerBlock(candidate, source) &&
              !isIndentedOnly &&
              !nestedAtContentColumn)) {
        break;
      }
      // Paragraph text may continue lazily without the item indentation.
      if (isIndentedOnly) {
        final contentStart = _advanceColumns(candidate, source, columns);
        continuationPrefixes.add(SourceRange(candidate.start, contentStart));
        final child = candidate.withContentStart(
          contentStart,
          column: columns,
          literalContainers: isOverIndentedListMarker,
        );
        childLines.add(child);
        lastChildAllowsLazyContinuation = _allowsListLazyContinuation(
          child,
          source,
        );
      } else {
        childLines.add(candidate);
        lastChildAllowsLazyContinuation = _allowsListLazyContinuation(
          candidate,
          source,
        );
      }
      last = candidate;
      index++;
    }
    final parsedChildren = _parseContainerLines(
      childLines,
      source,
      state.nested,
      grammar,
      extensionDepth,
    );
    final children = [
      for (final child in parsedChildren)
        child.withContinuationPrefixRanges([
          ...child.continuationPrefixRanges,
          for (final prefix in continuationPrefixes)
            if (prefix.intersects(child.range)) prefix,
        ]),
    ];
    final nonBlankChildren = children
        .where((child) => child.type != MarkdownBlockType.blank)
        .toList();
    final hasSeparatedChildren =
        nonBlankChildren.length > 1 &&
        children.any((child) => child.type == MarkdownBlockType.blank);
    final nextIsSibling =
        index < lines.length &&
        (_listMarkerAt(lines[index], source)?.isSameListAs(marker) ?? false);
    final hasNestedList = children.any(
      (child) => child.type == MarkdownBlockType.list,
    );
    final hasParagraphAfterNestedList =
        hasNestedList &&
        nonBlankChildren.last.type == MarkdownBlockType.paragraph;
    final onlyFencedCode =
        nonBlankChildren.isNotEmpty &&
        nonBlankChildren.every(
          (child) => child.type == MarkdownBlockType.fencedCode,
        );
    return (
      item: MarkdownBlockNode(
        type: MarkdownBlockType.listItem,
        checked: task?.block.checked,
        range: SourceRange(first.start, last.end),
        contentRange: SourceRange(marker.contentStart, last.contentEnd),
        prefixRange: SourceRange(first.start, marker.contentStart),
        markerRanges: [SourceRange(first.start, marker.contentStart)],
        continuationPrefixRanges: List.unmodifiable(continuationPrefixes),
        children: List.unmodifiable(children),
        start: marker.ordinal,
        delimiter: marker.delimiter,
      ),
      nextIndex: index,
      isLoose:
          sawBlank &&
          !onlyFencedCode &&
          ((nextIsSibling &&
                  !(hasNestedList && blankFollowedIndentedContent)) ||
              hasSeparatedChildren ||
              (!hasNestedList && hasSeparatedChildren) ||
              hasParagraphAfterNestedList),
    );
  }

  ({MarkdownBlockNode block, int nextIndex}) _parseContainerFence(
    List<_ContainerLine> lines,
    int index,
    String source,
    RegExpMatch fence,
  ) {
    final first = lines[index];
    final marker = fence.group(2)!;
    final character = marker[0];
    final closing = RegExp(
      '^( {0,3})${RegExp.escape(character)}{${marker.length},}[ \\t]*\$',
    );
    var last = first;
    var closed = false;
    index++;
    while (index < lines.length) {
      final candidate = lines[index];
      if (closing.hasMatch(candidate.text(source))) {
        last = candidate;
        closed = true;
        index++;
        break;
      }
      last = candidate;
      index++;
    }
    final prefixEnd = first.contentStart + fence.end;
    return (
      block: MarkdownBlockNode(
        type: MarkdownBlockType.fencedCode,
        range: SourceRange(first.start, last.end),
        contentRange: SourceRange(
          prefixEnd,
          closed ? last.contentStart : last.end,
        ),
        prefixRange: SourceRange(first.start, prefixEnd),
        indent: fence.group(1)!.length,
        continuationPrefixRanges: [
          for (final line in lines.skip(1).take(index - 1))
            SourceRange(line.start, line.contentStart),
        ],
        info: fence.group(3)!.trim(),
        isClosed: closed,
      ),
      nextIndex: index,
    );
  }

  ({MarkdownBlockNode block, int nextIndex}) _parseContainerIndentedCode(
    List<_ContainerLine> lines,
    int index,
    String source,
  ) {
    final first = lines[index];
    final firstContentStart = _advanceColumns(first, source, first.column + 4);
    final contentColumn = first.column + 4;
    final markers = <SourceRange>[SourceRange(first.start, firstContentStart)];
    var last = first;
    var pendingBlankMarkers = <SourceRange>[];
    var pendingBlankCount = 0;
    index++;
    while (index < lines.length) {
      final candidate = lines[index];
      if (candidate.text(source).trim().isEmpty) {
        pendingBlankMarkers.add(
          SourceRange(
            candidate.start,
            _advanceColumns(candidate, source, candidate.column + 4),
          ),
        );
        pendingBlankCount++;
        index++;
        continue;
      }
      if (_indentColumns(candidate, source) < 4) break;
      markers.addAll(pendingBlankMarkers);
      pendingBlankMarkers = <SourceRange>[];
      pendingBlankCount = 0;
      final contentStart = _advanceColumns(
        candidate,
        source,
        candidate.column + 4,
      );
      markers.add(SourceRange(candidate.start, contentStart));
      last = candidate;
      index++;
    }
    if (pendingBlankCount > 0) {
      // Separating and trailing blanks remain independent source partitions.
      index -= pendingBlankCount;
    }
    return (
      block: MarkdownBlockNode(
        type: MarkdownBlockType.indentedCode,
        range: SourceRange(first.start, last.end),
        contentRange: SourceRange(firstContentStart, last.contentEnd),
        markerRanges: List.unmodifiable(markers),
        contentColumn: contentColumn,
      ),
      nextIndex: index,
    );
  }

  _ListMarker? _listMarkerAt(_ContainerLine line, String source) {
    // Skip up to three columns of leading whitespace; tabs expand with
    // four-column stops, and a tab overshooting the limit is not a marker.
    var offset = line.contentStart;
    var column = line.column;
    while (offset < line.contentEnd && column - line.column < 3) {
      final unit = source.codeUnitAt(offset);
      if (unit == 0x20) {
        column++;
        offset++;
      } else if (unit == 0x09) {
        final next = column + 4 - (column % 4);
        if (next - line.column > 3) break;
        column = next;
        offset++;
      } else {
        break;
      }
    }
    return _markerAtOffset(line, source, offset, column);
  }

  _ListMarker? _markerAtOffset(
    _ContainerLine line,
    String source,
    int markerOffset,
    int markerColumn,
  ) {
    if (markerOffset >= line.contentEnd) return null;
    final marker = source.codeUnitAt(markerOffset);
    final isUnordered = marker == 0x2D || marker == 0x2B || marker == 0x2A;
    var digitEnd = markerOffset;
    if (!isUnordered) {
      while (digitEnd < line.contentEnd &&
          source.codeUnitAt(digitEnd) >= 0x30 &&
          source.codeUnitAt(digitEnd) <= 0x39) {
        digitEnd++;
      }
      if (digitEnd == markerOffset ||
          digitEnd - markerOffset > 9 ||
          digitEnd >= line.contentEnd) {
        return null;
      }
      final delimiter = source.codeUnitAt(digitEnd);
      if (delimiter != 0x2E && delimiter != 0x29) return null;
      return _markerWithPadding(
        line,
        source,
        markerOffset,
        digitEnd + 1,
        markerColumn,
        ordered: true,
        ordinal: int.parse(source.substring(markerOffset, digitEnd)),
        delimiter: String.fromCharCode(delimiter),
      );
    }
    return _markerWithPadding(
      line,
      source,
      markerOffset,
      markerOffset + 1,
      markerColumn,
      ordered: false,
      ordinal: null,
      delimiter: null,
    );
  }

  _ListMarker? _markerWithPadding(
    _ContainerLine line,
    String source,
    int markerOffset,
    int markerEnd,
    int markerColumn, {
    required bool ordered,
    required int? ordinal,
    required String? delimiter,
  }) {
    final markerWidth = _columnsBetween(
      source,
      markerOffset,
      markerEnd,
      markerColumn,
    );
    // Optional padding: spaces and tabs after the marker.
    final rawPaddingStart = markerEnd;
    var paddingStart = markerEnd;
    var paddingText = '';
    var paddingColumns = 0;
    while (paddingStart < line.contentEnd) {
      final unit = source.codeUnitAt(paddingStart);
      if (unit == 0x20) {
        paddingText += ' ';
        paddingColumns++;
        paddingStart++;
      } else if (unit == 0x09) {
        // A tab terminates the padding at one column; its remaining columns
        // stay in the content.
        paddingText += '\t';
        paddingColumns++;
        paddingStart++;
        break;
      } else {
        break;
      }
    }
    final hasPadding = paddingText.isNotEmpty;
    // A marker must be followed by whitespace padding or the end of the line;
    // `+++` and `---a---` are not list items.
    if (!hasPadding && markerEnd < line.contentEnd) return null;
    final markerColumnEnd =
        markerColumn + markerWidth + (hasPadding ? paddingColumns : 0);
    // A tab's remaining columns stay in the content. More than four
    // spaces of padding consume only one space; the remainder is content and
    // can therefore open an indented code block.
    final tabInPadding = paddingText.contains('\t');
    final overPadded = !tabInPadding && paddingColumns > 4;
    final effectivePadding = overPadded ? 1 : (hasPadding ? paddingColumns : 0);
    final contentStart = tabInPadding
        ? rawPaddingStart
        : overPadded
        ? rawPaddingStart + 1
        : paddingStart;
    final contentIndent = markerWidth + (hasPadding ? effectivePadding : 1);
    return _ListMarker(
      ordered: ordered,
      indent: _columnsBetween(
        source,
        line.contentStart,
        markerOffset,
        line.column,
      ),
      bullet: ordered
          ? null
          : String.fromCharCode(source.codeUnitAt(markerOffset)),
      ordinal: ordinal,
      delimiter: delimiter,
      contentStart: contentStart,
      contentIndent: contentIndent == 0 ? 1 : contentIndent,
      hasTabPadding: tabInPadding,
      isBlank: !hasPadding && markerColumnEnd == markerColumn + markerWidth,
    );
  }

  RegExpMatch? _quoteAt(_ContainerLine line, String source) =>
      RegExp(r'^( {0,3}>[ \t]?)').firstMatch(line.text(source));

  bool _startsContainerBlock(_ContainerLine line, String source) {
    if (line.literalContainers) return false;
    final text = line.text(source);
    return _quoteAt(line, source) != null ||
        _listMarkerAt(line, source) != null ||
        _rule.hasMatch(text) ||
        _fence.hasMatch(text) ||
        _heading.hasMatch(text) ||
        (_indentColumns(line, source) >= 4 &&
            !RegExp(r'^ {4,}[-+*][ \\t]+').hasMatch(text));
  }

  bool _canLazyContinuation(String text) =>
      text.trim().isNotEmpty &&
      !_fence.hasMatch(text) &&
      !_heading.hasMatch(text) &&
      !_rule.hasMatch(text);

  bool _allowsListLazyContinuation(_ContainerLine line, String source) {
    final quote = line.literalContainers ? null : _quoteAt(line, source);
    if (quote != null) {
      // A quote can itself continue lazily only when its immediately nested
      // content is a paragraph. This keeps a list's state aligned with its
      // actual last child rather than the quote marker that introduced it.
      final nestedLine = line.withContentStart(
        line.contentStart + quote.end,
        column: line.column + quote.end,
      );
      return _canLazyContinuation(nestedLine.text(source)) &&
          !_startsContainerBlock(nestedLine, source);
    }
    return _canLazyContinuation(line.text(source)) &&
        !_startsContainerBlock(line, source);
  }

  int _indentColumns(_ContainerLine line, String source) {
    var offset = line.contentStart;
    var columns = line.column;
    while (offset < line.contentEnd) {
      final unit = source.codeUnitAt(offset);
      if (unit == 0x20) {
        columns++;
      } else if (unit == 0x09) {
        columns += 4 - (columns % 4);
      } else {
        break;
      }
      offset++;
    }
    return columns - line.column;
  }

  int _columnsBetween(String source, int start, int end, int initialColumn) {
    var column = initialColumn;
    for (var offset = start; offset < end; offset++) {
      final unit = source.codeUnitAt(offset);
      if (unit == 0x09) {
        column += 4 - (column % 4);
      } else {
        column++;
      }
    }
    return column;
  }

  int _advanceColumns(_ContainerLine line, String source, int target) {
    var offset = line.contentStart;
    var columns = line.column;
    while (offset < line.contentEnd && columns < target) {
      final unit = source.codeUnitAt(offset);
      if (unit == 0x20) {
        columns++;
        offset++;
      } else if (unit == 0x09) {
        final next = columns + 4 - (columns % 4);
        if (next > target) {
          // The tab overshoots the target: content starts inside it, so the
          // raw offset stays at the tab and the renderer expands the partial
          // remainder from the target column.
          break;
        }
        columns = next;
        offset++;
      } else {
        break;
      }
    }
    return offset;
  }

  MarkdownParseUpdate parseIncremental(
    MarkdownDocument previous,
    String source,
  ) {
    if (previous.source == source) {
      return MarkdownParseUpdate(
        document: previous,
        reparsedRange: const SourceRange(0, 0),
        reusedBlockCount: previous.blocks.length,
      );
    }
    if (previous.blocks.isEmpty || source.isEmpty) {
      final document = parse(source);
      return MarkdownParseUpdate(
        document: document,
        reparsedRange: SourceRange(0, source.length),
        reusedBlockCount: 0,
      );
    }

    final oldSource = previous.source;
    final oldBlocks = previous.blocks;
    var prefix = 0;
    final sharedLength = oldSource.length < source.length
        ? oldSource.length
        : source.length;
    while (prefix < sharedLength && oldSource[prefix] == source[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < sharedLength - prefix &&
        oldSource[oldSource.length - suffix - 1] ==
            source[source.length - suffix - 1]) {
      suffix++;
    }
    final oldEditEnd = oldSource.length - suffix;
    final newEditEnd = source.length - suffix;
    final delta = source.length - oldSource.length;

    // Reuse old top-level blocks up to a blank-separated boundary strictly
    // before the edit. A blank line guarantees no preceding block can absorb
    // the edited lines (Setext underlines, indented list continuations, lazy
    // quotes); everything after the boundary is reparsed by the convergence
    // region, so the context-free parse there is always correct.
    var reuseCount = 0;
    for (
      var index = 0;
      index < oldBlocks.length && oldBlocks[index].range.end < prefix;
      index++
    ) {
      if (_isBlankSeparatedBoundary(oldBlocks[index].range.end, oldSource)) {
        reuseCount = index + 1;
      }
    }
    final startOffset = reuseCount == 0
        ? 0
        : oldBlocks[reuseCount - 1].range.end;
    final external = previous.definitions;

    // Delimiter-sensitive edits (fences) reflow arbitrary structure: skip
    // convergence and parse straight to the document end.
    final changedLines =
        '${_affectedLines(oldSource, prefix, oldEditEnd)}\n'
        '${_affectedLines(source, prefix, newEditEnd)}';
    final delimiterSensitive = RegExp(
      r'^ {0,3}(`{3,}|~{3,})',
      multiLine: true,
    ).hasMatch(changedLines);

    // Convergence: parse the region up to the first old block that starts
    // after the edit and stop when that block provably matches (same type,
    // shifted range, identical slice) with the whole post-edit portion
    // reproduced positionally. Otherwise continue to the document end.
    List<MarkdownBlockNode>? fresh;
    var convergedOldIndex = oldBlocks.length;
    var oldCandidate = reuseCount;
    while (oldCandidate < oldBlocks.length &&
        oldBlocks[oldCandidate].range.start < oldEditEnd) {
      oldCandidate++;
    }
    var iterations = 0;
    const maxConvergenceIterations = 4;
    while (!delimiterSensitive &&
        oldCandidate < oldBlocks.length &&
        iterations < maxConvergenceIterations) {
      iterations++;
      if (oldBlocks[oldCandidate].type == MarkdownBlockType.blank) {
        oldCandidate++;
        continue;
      }
      final parseEnd = oldBlocks[oldCandidate].range.end + delta;
      if (parseEnd <= startOffset) {
        oldCandidate++;
        continue;
      }
      final region = source.substring(startOffset, parseEnd);
      final parsed = parse(region, externalDefinitions: external).blocks;
      if (parsed.isEmpty) {
        oldCandidate++;
        continue;
      }
      final last = parsed.last;
      final shifted = oldBlocks[oldCandidate].range.shift(delta);
      final aligned =
          last.range.end == region.length &&
          last.range.shift(startOffset) == shifted &&
          last.type == oldBlocks[oldCandidate].type &&
          source.substring(shifted.start, shifted.end) ==
              oldSource.substring(
                oldBlocks[oldCandidate].range.start,
                oldBlocks[oldCandidate].range.end,
              );
      if (aligned) {
        // The whole post-edit portion of the region must reproduce the old
        // blocks positionally; a diverged interior (e.g. an indented-code
        // block where a nested list stood) invalidates the suffix context.
        var postEdit = 0;
        while (postEdit < parsed.length &&
            parsed[postEdit].range.start + startOffset < newEditEnd) {
          postEdit++;
        }
        var positional = parsed.length == oldCandidate - reuseCount + 1;
        for (var i = postEdit; positional && i < parsed.length; i++) {
          final oldIndex = reuseCount + i;
          final oldRange = oldBlocks[oldIndex].range;
          if (oldRange.start + delta < 0) {
            positional = false;
            break;
          }
          if (parsed[i].range.shift(startOffset) != oldRange.shift(delta) ||
              parsed[i].type != oldBlocks[oldIndex].type) {
            positional = false;
          }
        }
        if (positional) {
          fresh = [for (final block in parsed) block.shift(startOffset)];
          convergedOldIndex = oldCandidate;
          break;
        }
      }
      oldCandidate++;
    }

    final List<MarkdownBlockNode> blocks;
    if (fresh != null) {
      blocks = [
        ...oldBlocks.take(reuseCount),
        ...fresh,
        for (final block in oldBlocks.skip(convergedOldIndex + 1))
          block.shift(delta),
      ];
    } else {
      final tail = parse(
        source.substring(startOffset),
        externalDefinitions: external,
      ).blocks;
      blocks = [
        ...oldBlocks.take(reuseCount),
        for (final block in tail) block.shift(startOffset),
      ];
    }
    var document = MarkdownDocument(
      source: source,
      blocks: List.unmodifiable(blocks),
      checkpoints: MarkdownBlockParserState.checkpointsFor(blocks),
    );

    // A changed definition index can re-resolve references anywhere in the
    // document, including reused subtrees: fall back to a full parse.
    if (!_sameDefinitions(document.definitions, previous.definitions)) {
      document = parse(source);
      return MarkdownParseUpdate(
        document: document,
        reparsedRange: SourceRange(0, source.length),
        reusedBlockCount: 0,
      );
    }
    assert(document.roundTrip() == source);
    final reparsedEnd = fresh != null
        ? fresh.last.range.end
        : blocks.isEmpty
        ? startOffset
        : blocks.last.range.end;
    return MarkdownParseUpdate(
      document: document,
      reparsedRange: SourceRange(startOffset, reparsedEnd),
      reusedBlockCount:
          reuseCount +
          (fresh != null ? oldBlocks.length - convergedOldIndex : 0),
    );
  }

  /// Whether [offset] is a source position where no open block can continue:
  /// the document start, the document end, or a line directly following a
  /// blank line.
  static bool _isBlankSeparatedBoundary(int offset, String source) {
    if (offset == 0 || offset >= source.length) return true;
    return source.codeUnitAt(offset) == 0x0A;
  }

  static bool _sameDefinitions(
    Map<String, MarkdownLinkDefinition> a,
    Map<String, MarkdownLinkDefinition> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null) return false;
      if (other.destination != entry.value.destination ||
          other.title != entry.value.title ||
          other.labelRange != entry.value.labelRange) {
        return false;
      }
    }
    return true;
  }

  String _affectedLines(String source, int start, int end) {
    final lineStart = source.lastIndexOf('\n', start > 0 ? start - 1 : 0) + 1;
    final nextNewline = source.indexOf('\n', end);
    final lineEnd = nextNewline < 0 ? source.length : nextNewline;
    return source.substring(lineStart, lineEnd);
  }

  bool _supportsInlineParsing(MarkdownBlockType type) => switch (type) {
    MarkdownBlockType.blank ||
    MarkdownBlockType.fencedCode ||
    MarkdownBlockType.indentedCode ||
    MarkdownBlockType.horizontalRule ||
    MarkdownBlockType.linkDefinition ||
    MarkdownBlockType.extension => false,
    _ => true,
  };

  bool _isTableStart(String line, String nextLine) {
    final header = MarkdownTableScanner.scanRow(line, 0, line.length);
    if (!header.hasPipe) return false;
    if (!MarkdownTableScanner.isSeparatorRow(nextLine, 0, nextLine.length)) {
      return false;
    }
    final separator = MarkdownTableScanner.scanRow(
      nextLine,
      0,
      nextLine.length,
    );
    return header.cells.length == separator.cells.length;
  }

  int _atxContentEnd(String source, int contentStart, int contentEnd) {
    while (contentEnd > contentStart) {
      final codeUnit = source.codeUnitAt(contentEnd - 1);
      if (codeUnit != 0x20 && codeUnit != 0x09) break;
      contentEnd--;
    }
    final content = source.substring(contentStart, contentEnd);
    final closing = RegExp(r'[ \t]+#+[ \t]*$').firstMatch(content);
    final end = closing == null ? contentEnd : contentStart + closing.start;
    final trimmed = source.substring(contentStart, end).trim();
    if (trimmed.replaceAll('#', '').trim().isEmpty) return contentStart;
    return end;
  }

  /// Consults [rules] at the offered line through [context]. Returns the
  /// first valid match (with child ranges parsed and attached), or null when
  /// every rule declines or is invalidated.
  ({MarkdownBlockNode block, int nextIndex})? _matchBlockRules(
    MarkdownBlockParseContext context,
    List<MarkdownBlockRule> rules,
    MarkdownResolvedGrammar grammar,
  ) {
    if (rules.isEmpty) return null;
    final lineCount = context.lineCount;
    final firstLineStart = context.lineRangeAt(0).start;
    for (final rule in rules) {
      MarkdownBlockMatch? match;
      try {
        match = rule.matchBlock(context);
      } catch (error) {
        _reportExtensionError(
          grammar,
          grammar.ruleOwnerById[rule.id.value] ?? rule.id.value,
          error,
          null,
        );
        continue;
      }
      if (match == null) continue;
      final node = match.node;
      var valid =
          node.range.start == firstLineStart &&
          node.range.length > 0 &&
          node.range.end <= context.lineRangeAt(lineCount - 1).end;
      var consumed = 1;
      if (valid) {
        // Accessors are relative to the context start; find how many lines
        // the node covers so the caller can advance past it.
        var found = false;
        for (var relative = 0; relative < lineCount; relative++) {
          if (context.lineRangeAt(relative).end == node.range.end) {
            consumed = relative + 1;
            found = true;
            break;
          }
          if (context.lineRangeAt(relative).end > node.range.end) break;
        }
        valid = found;
      }
      if (valid && match.childRanges.isNotEmpty) {
        if (context.depth + 1 >
            MarkdownSyntaxExtension.maximumChildRecursionDepth) {
          valid = false;
        } else {
          var childCursor = node.range.start;
          for (final childRange in match.childRanges) {
            if (childRange.start < childCursor ||
                childRange.end > node.range.end ||
                childRange.end <= childRange.start) {
              valid = false;
              break;
            }
            childCursor = childRange.end;
          }
        }
      }
      if (!valid) {
        _reportExtensionError(
          grammar,
          grammar.ruleOwnerById[rule.id.value] ?? rule.id.value,
          'invalid block match for rule ${rule.id.value}',
          node.range,
        );
        continue;
      }
      final children = <MarkdownBlockNode>[];
      for (final childRange in match.childRanges) {
        children.addAll(context.parseChildren(childRange));
      }
      return (
        block: node.withChildren(children),
        nextIndex: context.lineIndex + consumed,
      );
    }
    return null;
  }

  /// A block context over container-parser lines (content after prefixes).
  MarkdownBlockParseContext _containerBlockContext(
    List<_ContainerLine> lines,
    int index,
    String source,
    MarkdownResolvedGrammar grammar,
    int depth,
  ) => MarkdownBlockParseContext(
    source: source,
    lineIndex: index,
    depth: depth,
    lineCount: lines.length - index,
    lineRangeAt: (i) =>
        SourceRange(lines[index + i].start, lines[index + i].end),
    contentRangeAt: (i) =>
        SourceRange(lines[index + i].contentStart, lines[index + i].contentEnd),
    parseChildren: (range) =>
        _parseChildBlocks(range, source, grammar, depth + 1),
  );

  /// Parses [range] as child blocks of an extension container. Enforces the
  /// maximum child recursion depth: on violation the range becomes a literal
  /// paragraph and a parse error is reported.
  List<MarkdownBlockNode> _parseChildBlocks(
    SourceRange range,
    String source,
    MarkdownResolvedGrammar grammar,
    int extensionDepth,
  ) {
    if (extensionDepth > MarkdownSyntaxExtension.maximumChildRecursionDepth) {
      _reportExtensionError(
        grammar,
        '',
        'extension child recursion exceeds maximum depth '
            '${MarkdownSyntaxExtension.maximumChildRecursionDepth}',
        range,
      );
      return [
        MarkdownBlockNode(
          type: MarkdownBlockType.paragraph,
          range: range,
          contentRange: range,
        ),
      ];
    }
    final lines = <_ContainerLine>[];
    for (final line in MarkdownSourceScanner(source).lines) {
      if (line.start >= range.end) break;
      if (line.end <= range.start) continue;
      lines.add(
        _ContainerLine(
          line: line,
          start: line.start,
          contentStart: line.start < range.start ? range.start : line.start,
          endOverride: line.end > range.end ? range.end : null,
        ),
      );
    }
    final blocks = _parseContainerLines(
      lines,
      source,
      const MarkdownContainerParserState(),
      grammar,
      extensionDepth,
    );
    final definitions = MarkdownDocument.definitionsFor(blocks);
    return [
      for (final block in blocks)
        _attachInlineNodes(block, source, const [], definitions, grammar),
    ];
  }

  /// Applies decorator rules to completed block nodes, attaching metadata
  /// to nodes that do not already carry extension data.
  List<MarkdownBlockNode> _decorateBlockTree(
    List<MarkdownBlockNode> blocks,
    MarkdownResolvedGrammar grammar,
  ) {
    late final List<MarkdownBlockNode> Function(List<MarkdownBlockNode> blocks)
    visit;
    MarkdownBlockNode decorate(MarkdownBlockNode block) {
      var current = block;
      if (current.extensionData == null) {
        for (final decorator in grammar.decorators) {
          final data = decorator.decorateBlock(current);
          if (data != null) {
            current = current.withExtensionData(data);
            break;
          }
        }
      }
      if (current.children.isNotEmpty) {
        current = current.withChildren(visit(current.children));
      }
      return current;
    }

    visit = (input) => [for (final block in input) decorate(block)];

    return visit(blocks);
  }

  void _reportExtensionError(
    MarkdownResolvedGrammar grammar,
    String extensionId,
    Object error,
    SourceRange? sourceRange,
  ) {
    grammar.onExtensionError?.call(
      MarkdownExtensionError(
        extensionId: extensionId,
        phase: MarkdownExtensionPhase.parse,
        error: error,
        sourceRange: sourceRange,
      ),
    );
  }
}

final class MarkdownParseUpdate {
  const MarkdownParseUpdate({
    required this.document,
    required this.reparsedRange,
    required this.reusedBlockCount,
  });

  final MarkdownDocument document;
  final SourceRange reparsedRange;
  final int reusedBlockCount;
}

final class _ContainerLine {
  const _ContainerLine({
    required this.line,
    required this.start,
    required this.contentStart,
    this.column = 0,
    this.literalContainers = false,
    this.lazy = false,
    this.endOverride,
  });

  final MarkdownSourceLine line;
  final int start;
  final int contentStart;

  /// Visual column of [contentStart] (tab stops every 4 columns).
  final int column;
  final bool literalContainers;

  /// Whether this line continued a container paragraph without its own
  /// marker or indentation (lazy continuation).
  final bool lazy;

  /// Bounds the physical line when parsing a partial child range.
  final int? endOverride;

  int get contentEnd {
    final bound = endOverride ?? line.end;
    return bound < line.contentEnd ? bound : line.contentEnd;
  }

  int get end => endOverride ?? line.end;

  String text(String source) => source.substring(contentStart, contentEnd);

  String textFrom(int start, String source) =>
      source.substring(start, contentEnd);

  _ContainerLine withContentStart(
    int value, {
    int? column,
    bool literalContainers = false,
  }) => _ContainerLine(
    line: line,
    start: start,
    contentStart: value,
    column: column ?? this.column,
    literalContainers: literalContainers,
    lazy: lazy,
  );

  _ContainerLine asLazy() => _ContainerLine(
    line: line,
    start: start,
    contentStart: contentStart,
    literalContainers: literalContainers,
    lazy: true,
  );
}

final class _ListMarker {
  const _ListMarker({
    required this.ordered,
    required this.indent,
    required this.bullet,
    required this.ordinal,
    required this.delimiter,
    required this.contentStart,
    required this.contentIndent,
    required this.hasTabPadding,
    required this.isBlank,
  });

  final bool ordered;
  final int indent;
  final String? bullet;
  final int? ordinal;
  final String? delimiter;
  final int contentStart;
  final int contentIndent;
  final bool hasTabPadding;
  final bool isBlank;

  bool isSameListAs(_ListMarker other) =>
      ordered == other.ordered &&
      (ordered ? delimiter == other.delimiter : bullet == other.bullet);
}
