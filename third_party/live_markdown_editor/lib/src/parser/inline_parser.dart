import '../model/source_range.dart';
import '../extensions/markdown_extension_error.dart';
import '../extensions/markdown_parse_context.dart';
import '../extensions/markdown_syntax_configuration.dart';
import '../extensions/markdown_syntax_extension.dart';
import 'entity_decoder.dart';
import 'inline_bracket_stack.dart';
import 'inline_delimiter_stack.dart';
import 'link_reference.dart';
import 'markdown_node.dart';

final class MarkdownInlineParser {
  const MarkdownInlineParser();

  static const MarkdownEntityDecoder _entityDecoder = MarkdownEntityDecoder();
  static final RegExp _codeLineEndings = RegExp(r'\r\n?|\n');

  static final RegExp _emailAutolink = RegExp(
    r"<([a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*)>",
  );
  static final RegExp _uriAutolink = RegExp(
    r'<[A-Za-z][A-Za-z0-9.+-]{1,31}:[^<>\x00-\x20]*>',
    caseSensitive: false,
  );

  /// Half-open code-unit runs of a single backtick marker.
  static List<({int start, int end})> _collectBacktickRuns(
    String source,
    int start,
    int end,
  ) {
    final runs = <({int start, int end})>[];
    var cursor = start;
    while (cursor < end) {
      final opener = source.indexOf('`', cursor);
      if (opener < 0 || opener >= end) break;
      final runEnd = _runEnd(source, opener, end, 0x60);
      runs.add((start: opener, end: runEnd));
      cursor = runEnd;
    }
    return runs;
  }

  /// For each run, the index of the closest following run with the same
  /// length, or null when no such run exists. Built in one right-to-left
  /// pass so every opening run resolves its closer without re-scanning.
  static List<int?> _nextSameLengthClosers(List<({int start, int end})> runs) {
    final next = List<int?>.filled(runs.length, null);
    final lastSeen = <int, int>{};
    for (var index = runs.length - 1; index >= 0; index--) {
      final length = runs[index].end - runs[index].start;
      next[index] = lastSeen[length];
      lastSeen[length] = index;
    }
    return next;
  }

  List<MarkdownInlineNode> parse(
    String source, {
    int sourceOffset = 0,
    Map<String, MarkdownLinkDefinition> definitions = const {},
    MarkdownResolvedGrammar grammar = const MarkdownResolvedGrammar(),
    String? fullSource,
  }) => _parseRange(
    source,
    0,
    source.length,
    sourceOffset,
    definitions,
    grammar,
    0,
    fullSource ?? source,
  );

  List<MarkdownInlineNode> _parseRange(
    String source,
    int start,
    int end,
    int sourceOffset,
    Map<String, MarkdownLinkDefinition> definitions,
    MarkdownResolvedGrammar grammar,
    int extensionDepth,
    String fullSource,
  ) {
    final sequence = _InlineSequence();
    final delimiters = MarkdownInlineDelimiterStack<_DelimiterElement>();
    final brackets = MarkdownInlineBracketStack<_NodeElement>();
    final backtickRuns = _collectBacktickRuns(source, start, end);
    final backtickClosers = _nextSameLengthClosers(backtickRuns);
    var backtickRunIndex = 0;
    var cursor = start;
    while (cursor < end) {
      final codeUnit = source.codeUnitAt(cursor);

      if (codeUnit == 0x60) {
        if (backtickRunIndex < backtickRuns.length &&
            backtickRuns[backtickRunIndex].start == cursor) {
          final closerIndex = backtickClosers[backtickRunIndex];
          if (closerIndex != null) {
            final closer = backtickRuns[closerIndex];
            sequence.appendNode(
              _codeSpanNode(
                source,
                opener: backtickRuns[backtickRunIndex],
                closer: closer,
                sourceOffset: sourceOffset,
              ),
            );
            cursor = closer.end;
            backtickRunIndex = closerIndex + 1;
            continue;
          }
        }
        final runEnd = _runEnd(source, cursor, end, codeUnit);
        sequence.appendText(
          SourceRange(sourceOffset + cursor, sourceOffset + runEnd),
        );
        cursor = runEnd;
        while (backtickRunIndex < backtickRuns.length &&
            backtickRuns[backtickRunIndex].start < cursor) {
          backtickRunIndex++;
        }
        continue;
      }

      if (codeUnit == 0x21 &&
          cursor + 1 < end &&
          source.codeUnitAt(cursor + 1) == 0x5B) {
        if (grammar.linkOverrideRules != null) {
          // The image marker stays literal; the override owns '[' onward.
          final marker = SourceRange(
            sourceOffset + cursor,
            sourceOffset + cursor + 1,
          );
          sequence.appendText(marker);
          cursor++;
          continue;
        }
        final range = SourceRange(
          sourceOffset + cursor,
          sourceOffset + cursor + 2,
        );
        final element = _NodeElement(
          MarkdownInlineNode(
            type: MarkdownInlineType.text,
            range: range,
            contentRange: range,
          ),
          canMergeWithNext: false,
        );
        sequence.append(element);
        brackets.push(
          MarkdownBracketOpener<_NodeElement>(
            element: element,
            index: cursor + 1,
            image: true,
            delimiterBottom: delimiters.length,
          ),
        );
        cursor += 2;
        continue;
      }

      if (codeUnit == 0x5B) {
        final overrideRules = grammar.linkOverrideRules;
        if (overrideRules != null) {
          final override = _tryInlineRules(
            overrideRules,
            (_) => true,
            source,
            start,
            cursor,
            end,
            sourceOffset,
            grammar,
            definitions,
            extensionDepth,
            fullSource,
            sequence,
            delimiters,
          );
          if (override != null) {
            sequence.appendNode(override.node);
            cursor += override.consumed;
            continue;
          }
          // The override declines: '[' stays literal and pushes no opener.
          final literal = SourceRange(
            sourceOffset + cursor,
            sourceOffset + cursor + 1,
          );
          sequence.appendText(literal);
          cursor++;
          continue;
        }
        final range = SourceRange(
          sourceOffset + cursor,
          sourceOffset + cursor + 1,
        );
        final element = _NodeElement(
          MarkdownInlineNode(
            type: MarkdownInlineType.text,
            range: range,
            contentRange: range,
          ),
          canMergeWithNext: false,
        );
        sequence.append(element);
        brackets.push(
          MarkdownBracketOpener<_NodeElement>(
            element: element,
            index: cursor,
            image: false,
            delimiterBottom: delimiters.length,
          ),
        );
        cursor++;
        continue;
      }

      if (codeUnit == 0x5D) {
        final closerOffset = cursor;
        cursor++;
        final resolvedEnd = _resolveBracket(
          source,
          closerOffset,
          end,
          sourceOffset,
          sequence,
          delimiters,
          brackets,
          definitions,
        );
        if (resolvedEnd != null) {
          cursor = resolvedEnd;
          continue;
        }
        final range = SourceRange(
          sourceOffset + closerOffset,
          sourceOffset + closerOffset + 1,
        );
        sequence.appendText(range);
        continue;
      }

      if (codeUnit == 0x3C) {
        final autolink = _autolinkAt(source, cursor, end, sourceOffset);
        if (autolink != null) {
          sequence.appendNode(autolink.node);
          cursor = autolink.end;
          continue;
        }
      }

      if (codeUnit == 0x2A || codeUnit == 0x5F) {
        final overrideRules = grammar.emphasisOverrideRules;
        if (overrideRules != null) {
          final override = _tryInlineRules(
            overrideRules,
            (_) => true,
            source,
            start,
            cursor,
            end,
            sourceOffset,
            grammar,
            definitions,
            extensionDepth,
            fullSource,
            sequence,
            delimiters,
          );
          if (override != null) {
            sequence.appendNode(override.node);
            cursor += override.consumed;
            continue;
          }
          // The override declines: the whole delimiter run stays literal.
          final runEnd = _runEnd(source, cursor, end, codeUnit);
          final run = SourceRange(sourceOffset + cursor, sourceOffset + runEnd);
          sequence.appendText(run);
          cursor = runEnd;
          continue;
        }
        final runEnd = _runEnd(source, cursor, end, codeUnit);
        final element = _DelimiterElement(
          start: sourceOffset + cursor,
          end: sourceOffset + runEnd,
        );
        sequence.append(element);
        delimiters.add(
          MarkdownInlineDelimiter<_DelimiterElement>.fromRun(
            source: source,
            runStart: cursor,
            runEnd: runEnd,
            rangeStart: start,
            rangeEnd: end,
            token: element,
          ),
        );
        cursor = runEnd;
        continue;
      }

      if (codeUnit == 0x5C) {
        final lineEndingLength = _lineEndingLengthAt(source, cursor + 1, end);
        if (lineEndingLength != 0) {
          final marker = SourceRange(
            sourceOffset + cursor,
            sourceOffset + cursor + 1,
          );
          final range = SourceRange(
            marker.start,
            sourceOffset + cursor + 1 + lineEndingLength,
          );
          sequence.appendNode(
            MarkdownInlineNode(
              type: MarkdownInlineType.hardBreak,
              range: range,
              contentRange: SourceRange(marker.end, range.end),
              markerRanges: [marker],
            ),
          );
          cursor += 1 + lineEndingLength;
          continue;
        }
        if (cursor + 1 < end &&
            _isAsciiPunctuation(source.codeUnitAt(cursor + 1))) {
          final range = SourceRange(
            sourceOffset + cursor,
            sourceOffset + cursor + 2,
          );
          sequence.appendNode(
            MarkdownInlineNode(
              type: MarkdownInlineType.text,
              range: range,
              contentRange: range,
              decodedText: source.substring(cursor + 1, cursor + 2),
            ),
          );
          cursor += 2;
          continue;
        }
      }

      if (codeUnit == 0x26) {
        final entity = _entityDecoder.decodeAt(source, cursor, end: end);
        if (entity != null) {
          final range = SourceRange(
            sourceOffset + cursor,
            sourceOffset + cursor + entity.sourceLength,
          );
          sequence.appendNode(
            MarkdownInlineNode(
              type: MarkdownInlineType.text,
              range: range,
              contentRange: range,
              decodedText: entity.decodedText,
            ),
          );
          cursor += entity.sourceLength;
          continue;
        }
      }

      if (codeUnit == 0) {
        final range = SourceRange(
          sourceOffset + cursor,
          sourceOffset + cursor + 1,
        );
        sequence.appendNode(
          MarkdownInlineNode(
            type: MarkdownInlineType.text,
            range: range,
            contentRange: range,
            decodedText: '\uFFFD',
          ),
        );
        cursor++;
        continue;
      }

      if (codeUnit == 0x20) {
        final spaceEnd = _runEnd(source, cursor, end, codeUnit);
        final lineEndingLength = _lineEndingLengthAt(source, spaceEnd, end);
        if (lineEndingLength != 0) {
          final marker = SourceRange(
            sourceOffset + cursor,
            sourceOffset + spaceEnd,
          );
          final range = SourceRange(
            marker.start,
            sourceOffset + spaceEnd + lineEndingLength,
          );
          sequence.appendNode(
            MarkdownInlineNode(
              type: marker.length >= 2
                  ? MarkdownInlineType.hardBreak
                  : MarkdownInlineType.softBreak,
              range: range,
              contentRange: SourceRange(marker.end, range.end),
              markerRanges: [marker],
            ),
          );
          cursor = spaceEnd + lineEndingLength;
          continue;
        }
        if (spaceEnd == end) {
          final range = SourceRange(
            sourceOffset + cursor,
            sourceOffset + spaceEnd,
          );
          sequence.appendNode(
            MarkdownInlineNode(
              type: MarkdownInlineType.text,
              range: range,
              contentRange: range,
              decodedText: '',
            ),
          );
          cursor = spaceEnd;
          continue;
        }
      }

      final lineEndingLength = _lineEndingLengthAt(source, cursor, end);
      if (lineEndingLength != 0) {
        final range = SourceRange(
          sourceOffset + cursor,
          sourceOffset + cursor + lineEndingLength,
        );
        sequence.appendNode(
          MarkdownInlineNode(
            type: MarkdownInlineType.softBreak,
            range: range,
            contentRange: range,
          ),
        );
        cursor += lineEndingLength;
        continue;
      }

      // Additive inline rules run before literal-text fallback.
      final extension = _tryInlineRules(
        grammar.inlineFallbackRules,
        (rule) => rule.triggerCodeUnits.contains(codeUnit),
        source,
        start,
        cursor,
        end,
        sourceOffset,
        grammar,
        definitions,
        extensionDepth,
        fullSource,
        sequence,
        delimiters,
      );
      if (extension != null) {
        sequence.appendNode(extension.node);
        cursor += extension.consumed;
        continue;
      }

      var textEnd = cursor + 1;
      while (textEnd < end &&
          !_startsInlineToken(source, textEnd, end, grammar.inlineTriggers)) {
        textEnd++;
      }
      sequence.appendText(
        SourceRange(sourceOffset + cursor, sourceOffset + textEnd),
      );
      cursor = textEnd;
    }

    delimiters.process(sequence.wrapEmphasis);
    final nodes = sequence.toNodes();
    if (grammar.decorators.isEmpty) return nodes;
    return _decorateInlineNodes(nodes, grammar);
  }

  /// Consults [rules] at the offered cursor. Returns the first valid match
  /// (with its child ranges already parsed), or a literalized node when a
  /// match violates engine bounds, or null when every rule declines.
  ({MarkdownInlineNode node, int consumed})? _tryInlineRules(
    List<MarkdownInlineRule> rules,
    bool Function(MarkdownInlineRule rule) canTry,
    String source,
    int start,
    int cursor,
    int end,
    int sourceOffset,
    MarkdownResolvedGrammar grammar,
    Map<String, MarkdownLinkDefinition> definitions,
    int extensionDepth,
    String fullSource,
    _InlineSequence sequence,
    MarkdownInlineDelimiterStack<_DelimiterElement> delimiters,
  ) {
    if (rules.isEmpty) return null;
    final absoluteCursor = sourceOffset + cursor;
    final enclosingEnd = sourceOffset + end;
    for (final rule in rules) {
      if (!canTry(rule)) continue;
      final ownerId = grammar.ruleOwnerById[rule.id.value] ?? rule.id.value;
      final context = MarkdownInlineParseContext(
        source: fullSource,
        cursor: absoluteCursor,
        enclosingRange: SourceRange(sourceOffset + start, enclosingEnd),
        activeDelimiters: [
          for (final delimiter in delimiters.snapshot)
            MarkdownInlineDelimiterInfo(
              marker: delimiter.marker,
              start: delimiter.token.start,
              end: delimiter.token.end,
            ),
        ],
        parseChildren: (range) => _parseInlineChildren(
          range,
          fullSource,
          grammar,
          definitions,
          extensionDepth + 1,
          ownerId,
        ),
      );
      MarkdownInlineMatch? match;
      try {
        match = rule.matchInline(context);
      } catch (error) {
        _reportExtensionError(
          grammar,
          ownerId,
          error,
          SourceRange(absoluteCursor, absoluteCursor + 1),
        );
        continue;
      }
      if (match == null) continue;
      final node = match.node;
      var valid =
          node.range.start == absoluteCursor &&
          node.range.end > node.range.start &&
          node.range.end <= enclosingEnd;
      if (valid && match.childRanges.isNotEmpty) {
        if (extensionDepth + 1 >
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
          ownerId,
          'invalid inline match for rule ${rule.id.value}',
          node.range,
        );
        final literalEnd =
            node.range.start == absoluteCursor &&
                node.range.end > absoluteCursor &&
                node.range.end <= enclosingEnd
            ? node.range.end
            : absoluteCursor + 1;
        final literalRange = SourceRange(absoluteCursor, literalEnd);
        return (
          node: MarkdownInlineNode(
            type: MarkdownInlineType.text,
            range: literalRange,
            contentRange: literalRange,
          ),
          consumed: literalEnd - absoluteCursor,
        );
      }
      final children = <MarkdownInlineNode>[];
      for (final childRange in match.childRanges) {
        children.addAll(context.parseChildren(childRange));
      }
      return (
        node: node.withChildren(children),
        consumed: node.range.end - absoluteCursor,
      );
    }
    return null;
  }

  /// Parses [range] as child inline content of an extension node. Enforces
  /// the maximum child recursion depth: on violation the range becomes a
  /// literal text node and a parse error is reported.
  List<MarkdownInlineNode> _parseInlineChildren(
    SourceRange range,
    String fullSource,
    MarkdownResolvedGrammar grammar,
    Map<String, MarkdownLinkDefinition> definitions,
    int depth,
    String extensionId,
  ) {
    if (depth > MarkdownSyntaxExtension.maximumChildRecursionDepth) {
      _reportExtensionError(
        grammar,
        extensionId,
        'extension child recursion exceeds maximum depth '
        '${MarkdownSyntaxExtension.maximumChildRecursionDepth}',
        range,
      );
      return [
        MarkdownInlineNode(
          type: MarkdownInlineType.text,
          range: range,
          contentRange: range,
        ),
      ];
    }
    return _parseRange(
      fullSource,
      range.start,
      range.end,
      0,
      definitions,
      grammar,
      depth,
      fullSource,
    );
  }

  /// Applies decorator rules to completed inline nodes, attaching metadata
  /// to nodes that do not already carry extension data.
  List<MarkdownInlineNode> _decorateInlineNodes(
    List<MarkdownInlineNode> nodes,
    MarkdownResolvedGrammar grammar,
  ) {
    late final List<MarkdownInlineNode> Function(List<MarkdownInlineNode> nodes)
    visit;
    MarkdownInlineNode decorate(MarkdownInlineNode node) {
      var current = node;
      if (current.extensionData == null) {
        for (final decorator in grammar.decorators) {
          final data = decorator.decorateInline(current);
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

    visit = (input) => [for (final node in input) decorate(node)];

    return visit(nodes);
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

  /// Resolves the bracket closed at [closerOffset]. Returns the source offset
  /// just after the resolved link/image syntax, or null when the bracket
  /// stays literal (the caller appends `]` as text).
  int? _resolveBracket(
    String source,
    int closerOffset,
    int end,
    int sourceOffset,
    _InlineSequence sequence,
    MarkdownInlineDelimiterStack<_DelimiterElement> delimiters,
    MarkdownInlineBracketStack<_NodeElement> brackets,
    Map<String, MarkdownLinkDefinition> definitions,
  ) {
    final opener = brackets.top;
    if (opener == null) return null;
    if (!opener.active) {
      brackets.pop();
      return null;
    }

    // Inline link `(...)`.
    if (closerOffset + 1 < end && source.codeUnitAt(closerOffset + 1) == 0x28) {
      final inline = _scanInlineLink(source, closerOffset + 1, end);
      if (inline != null) {
        _makeLink(
          opener,
          closerOffset,
          inline.linkEnd,
          source,
          sourceOffset,
          sequence,
          delimiters,
          brackets,
          destination: inline.destination,
          title: inline.title,
        );
        return inline.linkEnd;
      }
    }

    // Full, collapsed, or shortcut reference.
    final reference = _scanReference(
      source,
      closerOffset + 1,
      closerOffset,
      end,
      opener,
      definitions,
    );
    if (reference != null) {
      _makeLink(
        opener,
        closerOffset,
        reference.linkEnd,
        source,
        sourceOffset,
        sequence,
        delimiters,
        brackets,
        destination: reference.destination,
        title: reference.title,
      );
      return reference.linkEnd;
    }

    brackets.pop();
    return null;
  }

  ({String destination, String? title, int linkEnd})? _scanInlineLink(
    String source,
    int openParenOffset,
    int end,
  ) {
    var cursor = openParenOffset + 1;
    cursor = _skipSpnl(source, cursor, end);
    final destination = MarkdownLinkReferenceScanner.scanDestination(
      source,
      cursor,
    );
    if (destination == null || destination.end > end) return null;
    cursor = destination.end;
    final decodedDestination = MarkdownLinkReferenceScanner.normalizeUri(
      MarkdownLinkReferenceScanner.unescape(destination.raw),
    );

    final beforeTitle = cursor;
    cursor = _skipSpnl(source, cursor, end);
    String? decodedTitle;
    if (cursor != beforeTitle) {
      final titleMatch = MarkdownLinkReferenceScanner.scanTitle(
        source,
        cursor,
        end,
      );
      if (titleMatch != null) {
        decodedTitle = titleMatch.title;
        cursor = titleMatch.end;
      } else {
        cursor = beforeTitle;
      }
    }

    cursor = _skipSpnl(source, cursor, end);
    if (cursor >= end || source.codeUnitAt(cursor) != 0x29) return null;
    return (
      destination: decodedDestination,
      title: decodedTitle,
      linkEnd: cursor + 1,
    );
  }

  ({String destination, String? title, int linkEnd})? _scanReference(
    String source,
    int start,
    int closerOffset,
    int end,
    MarkdownBracketOpener<_NodeElement> opener,
    Map<String, MarkdownLinkDefinition> definitions,
  ) {
    String? rawLabel;
    var labelEnd = -1;
    final labelLength = MarkdownLinkReferenceScanner.scanLinkLabelLength(
      source,
      start,
      end,
    );
    if (labelLength > 2) {
      rawLabel = source.substring(start, start + labelLength);
      labelEnd = start + labelLength;
    } else if (labelLength == 2) {
      // Collapsed reference `[]`: the empty label is consumed as syntax.
      if (!opener.bracketAfter) {
        rawLabel = source.substring(opener.index, closerOffset + 1);
        labelEnd = start + labelLength;
      }
    } else if (!opener.bracketAfter) {
      rawLabel = source.substring(opener.index, closerOffset + 1);
    }
    if (rawLabel == null) return null;
    final normalized = MarkdownLinkReferenceScanner.normalizeReference(
      rawLabel,
    );
    final definition = definitions[normalized];
    if (definition == null) return null;
    return (
      destination: definition.destination,
      title: definition.title,
      linkEnd: labelEnd > 0 ? labelEnd : closerOffset + 1,
    );
  }

  void _makeLink(
    MarkdownBracketOpener<_NodeElement> opener,
    int closerOffset,
    int linkEnd,
    String source,
    int sourceOffset,
    _InlineSequence sequence,
    MarkdownInlineDelimiterStack<_DelimiterElement> delimiters,
    MarkdownInlineBracketStack<_NodeElement> brackets, {
    required String destination,
    required String? title,
  }) {
    // Resolve emphasis delimiters strictly inside the link content before the
    // elements are moved into the link node.
    delimiters.processFrom(opener.delimiterBottom, sequence.wrapEmphasis);

    final children = sequence.removeNodesAfter(opener.element);
    final elementRange = opener.element.node.range;
    final isImage = opener.image;
    opener.element.node = MarkdownInlineNode(
      type: isImage ? MarkdownInlineType.image : MarkdownInlineType.link,
      range: SourceRange(elementRange.start, sourceOffset + linkEnd),
      contentRange: SourceRange(elementRange.end, sourceOffset + closerOffset),
      openingRange: elementRange,
      closingRange: SourceRange(
        sourceOffset + closerOffset,
        sourceOffset + linkEnd,
      ),
      children: children,
      destination: destination,
      title: title,
    );
    if (!isImage) brackets.deactivateEarlierLinks();
    brackets.pop();
  }

  MarkdownInlineNode _codeSpanNode(
    String source, {
    required ({int start, int end}) opener,
    required ({int start, int end}) closer,
    required int sourceOffset,
  }) {
    final contentRange = SourceRange(
      sourceOffset + opener.end,
      sourceOffset + closer.start,
    );
    var normalized = source
        .substring(opener.end, closer.start)
        .replaceAll(_codeLineEndings, ' ')
        .replaceAll('\u0000', '\uFFFD');
    final containsNonSpace = normalized.codeUnits.any((unit) => unit != 0x20);
    if (containsNonSpace &&
        normalized.startsWith(' ') &&
        normalized.endsWith(' ')) {
      normalized = normalized.substring(1, normalized.length - 1);
    }
    return MarkdownInlineNode(
      type: MarkdownInlineType.code,
      range: SourceRange(
        sourceOffset + opener.start,
        sourceOffset + closer.end,
      ),
      contentRange: contentRange,
      openingRange: SourceRange(
        sourceOffset + opener.start,
        sourceOffset + opener.end,
      ),
      closingRange: SourceRange(
        sourceOffset + closer.start,
        sourceOffset + closer.end,
      ),
      decodedText: normalized,
    );
  }

  _InlineMatch? _autolinkAt(
    String source,
    int start,
    int end,
    int sourceOffset,
  ) {
    final email = _emailAutolink.matchAsPrefix(source, start);
    if (email != null && email.end <= end) {
      final content = email.group(1)!;
      final range = SourceRange(sourceOffset + start, sourceOffset + email.end);
      final contentRange = SourceRange(range.start + 1, range.end - 1);
      return _InlineMatch(
        MarkdownInlineNode(
          type: MarkdownInlineType.link,
          range: range,
          contentRange: contentRange,
          openingRange: SourceRange(range.start, range.start + 1),
          closingRange: SourceRange(range.end - 1, range.end),
          destination: MarkdownLinkReferenceScanner.normalizeUri(
            'mailto:$content',
          ),
          title: '',
          children: [
            MarkdownInlineNode(
              type: MarkdownInlineType.text,
              range: contentRange,
              contentRange: contentRange,
            ),
          ],
        ),
        email.end,
      );
    }
    final uri = _uriAutolink.matchAsPrefix(source, start);
    if (uri != null && uri.end <= end) {
      final full = uri.group(0)!;
      final content = full.substring(1, full.length - 1);
      final range = SourceRange(sourceOffset + start, sourceOffset + uri.end);
      final contentRange = SourceRange(range.start + 1, range.end - 1);
      return _InlineMatch(
        MarkdownInlineNode(
          type: MarkdownInlineType.link,
          range: range,
          contentRange: contentRange,
          openingRange: SourceRange(range.start, range.start + 1),
          closingRange: SourceRange(range.end - 1, range.end),
          destination: MarkdownLinkReferenceScanner.normalizeUri(content),
          title: '',
          children: [
            MarkdownInlineNode(
              type: MarkdownInlineType.text,
              range: contentRange,
              contentRange: contentRange,
            ),
          ],
        ),
        uri.end,
      );
    }
    return null;
  }

  int _skipSpnl(String source, int start, int end) {
    var cursor = start;
    while (cursor < end && source.codeUnitAt(cursor) == 0x20) {
      cursor++;
    }
    if (cursor < end && _lineEndingLengthAt(source, cursor, end) != 0) {
      cursor += _lineEndingLengthAt(source, cursor, end);
      while (cursor < end && source.codeUnitAt(cursor) == 0x20) {
        cursor++;
      }
    }
    return cursor;
  }

  static int _runEnd(String source, int start, int end, int codeUnit) {
    var cursor = start;
    while (cursor < end && source.codeUnitAt(cursor) == codeUnit) {
      cursor++;
    }
    return cursor;
  }

  int _lineEndingLengthAt(String source, int offset, int end) {
    if (offset >= end) return 0;
    final codeUnit = source.codeUnitAt(offset);
    if (codeUnit == 0x0A) return 1;
    if (codeUnit != 0x0D) return 0;
    return offset + 1 < end && source.codeUnitAt(offset + 1) == 0x0A ? 2 : 1;
  }

  bool _startsInlineToken(
    String source,
    int offset,
    int end,
    Set<int> extensionTriggers,
  ) {
    final codeUnit = source.codeUnitAt(offset);
    if (extensionTriggers.contains(codeUnit)) return true;
    return codeUnit == 0 ||
        codeUnit == 0x20 ||
        codeUnit == 0x21 ||
        codeUnit == 0x26 ||
        codeUnit == 0x2A ||
        codeUnit == 0x3C ||
        codeUnit == 0x3D ||
        codeUnit == 0x5B ||
        codeUnit == 0x5C ||
        codeUnit == 0x5D ||
        codeUnit == 0x5F ||
        codeUnit == 0x60 ||
        codeUnit == 0x7E ||
        _lineEndingLengthAt(source, offset, end) != 0;
  }

  bool _isAsciiPunctuation(int codeUnit) =>
      (codeUnit >= 0x21 && codeUnit <= 0x2F) ||
      (codeUnit >= 0x3A && codeUnit <= 0x40) ||
      (codeUnit >= 0x5B && codeUnit <= 0x60) ||
      (codeUnit >= 0x7B && codeUnit <= 0x7E);
}

final class _InlineSequence {
  _InlineElement? _head;
  _InlineElement? _tail;

  void appendText(SourceRange range) => appendNode(
    MarkdownInlineNode(
      type: MarkdownInlineType.text,
      range: range,
      contentRange: range,
    ),
  );

  void appendNode(MarkdownInlineNode node) {
    final previous = _tail;
    if (previous is _NodeElement &&
        previous.canMergeWithNext &&
        previous.node.type == MarkdownInlineType.text &&
        previous.node.decodedText == null &&
        node.type == MarkdownInlineType.text &&
        node.decodedText == null &&
        previous.node.range.end == node.range.start) {
      previous.node = MarkdownInlineNode(
        type: MarkdownInlineType.text,
        range: SourceRange(previous.node.range.start, node.range.end),
        contentRange: SourceRange(
          previous.node.contentRange.start,
          node.contentRange.end,
        ),
      );
      return;
    }
    append(_NodeElement(node));
  }

  void append(_InlineElement element) {
    element.previous = _tail;
    if (_tail == null) {
      _head = element;
    } else {
      _tail!.next = element;
    }
    _tail = element;
  }

  /// Removes every element after [anchor] from the sequence and returns them
  /// as semantic nodes (unresolved delimiter elements become literal text).
  List<MarkdownInlineNode> removeNodesAfter(_NodeElement anchor) {
    final nodes = _nodesBetween(anchor.next, null);
    var current = anchor.next;
    while (current != null) {
      final next = current.next;
      _remove(current);
      current = next;
    }
    return nodes;
  }

  void wrapEmphasis(MarkdownInlineDelimiterMatch<_DelimiterElement> match) {
    final opener = match.opener.token;
    final closer = match.closer.token;
    final useLength = match.useLength;
    final openingRange = SourceRange(opener.end - useLength, opener.end);
    final closingRange = SourceRange(closer.start, closer.start + useLength);
    final children = _nodesBetween(opener.next, closer);

    var child = opener.next;
    while (child != null && child != closer) {
      final next = child.next;
      _remove(child);
      child = next;
    }

    opener.end -= useLength;
    final previous = opener.start == opener.end ? opener.previous : opener;
    if (opener.start == opener.end) _remove(opener);

    closer.start += useLength;
    final next = closer.start == closer.end ? closer.next : closer;
    if (closer.start == closer.end) _remove(closer);

    _insertBetween(
      previous,
      next,
      _NodeElement(
        MarkdownInlineNode(
          type: useLength == 2
              ? MarkdownInlineType.bold
              : MarkdownInlineType.italic,
          range: SourceRange(openingRange.start, closingRange.end),
          contentRange: SourceRange(openingRange.end, closingRange.start),
          openingRange: openingRange,
          closingRange: closingRange,
          children: children,
        ),
      ),
    );
  }

  List<MarkdownInlineNode> toNodes() =>
      List.unmodifiable(_nodesBetween(_head, null));

  List<MarkdownInlineNode> _nodesBetween(
    _InlineElement? first,
    _InlineElement? end,
  ) {
    final nodes = <MarkdownInlineNode>[];
    var current = first;
    while (current != null && current != end) {
      late final MarkdownInlineNode node;
      if (current is _NodeElement) {
        node = current.node;
      } else {
        final delimiter = current as _DelimiterElement;
        final range = SourceRange(delimiter.start, delimiter.end);
        node = MarkdownInlineNode(
          type: MarkdownInlineType.text,
          range: range,
          contentRange: range,
        );
      }
      final previous = nodes.isEmpty ? null : nodes.last;
      if (previous?.type == MarkdownInlineType.text &&
          previous?.decodedText == null &&
          node.type == MarkdownInlineType.text &&
          node.decodedText == null &&
          previous!.range.end == node.range.start) {
        nodes[nodes.length - 1] = MarkdownInlineNode(
          type: MarkdownInlineType.text,
          range: SourceRange(previous.range.start, node.range.end),
          contentRange: SourceRange(
            previous.contentRange.start,
            node.contentRange.end,
          ),
        );
      } else {
        nodes.add(node);
      }
      current = current.next;
    }
    return List.unmodifiable(nodes);
  }

  void _remove(_InlineElement element) {
    if (element.previous == null) {
      _head = element.next;
    } else {
      element.previous!.next = element.next;
    }
    if (element.next == null) {
      _tail = element.previous;
    } else {
      element.next!.previous = element.previous;
    }
    element
      ..previous = null
      ..next = null;
  }

  void _insertBetween(
    _InlineElement? previous,
    _InlineElement? next,
    _InlineElement element,
  ) {
    element
      ..previous = previous
      ..next = next;
    if (previous == null) {
      _head = element;
    } else {
      previous.next = element;
    }
    if (next == null) {
      _tail = element;
    } else {
      next.previous = element;
    }
  }
}

abstract base class _InlineElement {
  _InlineElement? previous;
  _InlineElement? next;
}

final class _NodeElement extends _InlineElement {
  _NodeElement(this.node, {this.canMergeWithNext = true});

  MarkdownInlineNode node;

  /// Bracket-opener elements must stay distinct so their `[`/`![` text node
  /// survives adjacent-text coalescing and can anchor link resolution.
  final bool canMergeWithNext;
}

final class _DelimiterElement extends _InlineElement {
  _DelimiterElement({required this.start, required this.end});

  int start;
  int end;
}

final class _InlineMatch {
  const _InlineMatch(this.node, this.end);

  final MarkdownInlineNode node;
  final int end;
}
