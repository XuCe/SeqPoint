import '../model/source_range.dart';
import 'entity_decoder.dart';
import 'markdown_node.dart';

/// Parses CommonMark link reference definitions and the shared label,
/// destination, title, and URI-normalization grammar they and the inline
/// bracket stack depend on.
///
/// The scanner works over the joined content of the candidate paragraph lines
/// (each line's content range is joined with a synthetic `\n`), mirroring
/// commonmark.js's `parseReference`/`parseLinkLabel`/`parseLinkDestination`/
/// `parseLinkTitle` exactly, so definition consumption always ends at a line
/// boundary and can be mapped back to whole source lines.
final class MarkdownLinkReferenceScanner {
  const MarkdownLinkReferenceScanner();

  static const MarkdownEntityDecoder _entityDecoder = MarkdownEntityDecoder();

  /// A link label for reference resolution inside inline content.
  static final RegExp _inlineLabel = RegExp(
    r'\[(?:[^\\\[\]]|\\.){0,1000}\]',
    dotAll: true,
  );

  static final RegExp _braceDestination = RegExp(r'<(?:[^<>\n\\\x00]|\\.)*>');

  static final RegExp _title = RegExp(
    r'''"(?:\\[!"#$%&'()*+,./:;<=>?@\[\]\\^_`{|}~-]|\\[^\\]|[^\\"\x00])*"|'(?:\\[!"#$%&'()*+,./:;<=>?@\[\]\\^_`{|}~-]|\\[^\\]|[^\\'\x00])*'|\((?:\\[!"#$%&'()*+,./:;<=>?@\[\]\\^_`{|}~-]|\\[^\\]|[^\\()\x00])*\)''',
  );

  static final RegExp _hexPair = RegExp(r'^[0-9a-f]{2}$', caseSensitive: false);

  /// ASCII percent-encoding table (mdurl `encode`): alphanumerics plus the
  /// safe punctuation set stay literal; everything else is `%HH`.
  static final List<String> _encodeCache = _buildEncodeCache();

  static List<String> _buildEncodeCache() {
    const exclude = r";/?:@&=+$,-_.!~*'()#";
    final cache = List<String>.filled(128, '');
    for (var index = 0; index < 128; index++) {
      final ch = String.fromCharCode(index);
      if ((ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) ||
          (ch.codeUnitAt(0) >= 0x41 && ch.codeUnitAt(0) <= 0x5A) ||
          (ch.codeUnitAt(0) >= 0x61 && ch.codeUnitAt(0) <= 0x7A)) {
        cache[index] = ch;
      } else {
        cache[index] =
            '%${index.toRadixString(16).toUpperCase().padLeft(2, '0')}';
      }
    }
    for (var index = 0; index < exclude.length; index++) {
      cache[exclude.codeUnitAt(index)] = exclude[index];
    }
    return cache;
  }

  /// Attempts to parse a link reference definition from the start of the
  /// candidate [lines] (raw content ranges in source order). Returns null
  /// when the lines do not begin with a valid definition.
  MarkdownLinkDefinitionScan? scanDefinition(
    String source,
    int start,
    int end, {
    required SourceRange Function(int index) contentRange,
    required bool Function(int index) canInclude,
  }) {
    if (start >= end) return null;
    final first = contentRange(start);
    var probe = first.start;
    final firstEnd = first.end;
    var indent = 0;
    while (probe < firstEnd && indent < 3 && source.codeUnitAt(probe) == 0x20) {
      probe++;
      indent++;
    }
    if (probe >= firstEnd || source.codeUnitAt(probe) != 0x5B) return null;

    // Each candidate line is fed to the state machine once; it resumes from
    // its saved continuation point, so a definition spanning K lines costs
    // O(K) and a run of consecutive definitions is linear overall.
    final machine = _DefinitionMachine(source, probe);
    var lineIndex = start;
    while (lineIndex < end) {
      if (lineIndex != start && !canInclude(lineIndex)) break;
      machine.processLine(contentRange(lineIndex));
      if (machine.done) {
        return MarkdownLinkDefinitionScan(
          definition: machine.definition!,
          linesConsumed: machine.linesConsumed,
        );
      }
      if (machine.failed) return null;
      lineIndex++;
    }
    // No more includable lines: resolve the pending state exactly like the
    // reference implementation on the final content.
    machine.resolveAtEnd();
    if (machine.done) {
      return MarkdownLinkDefinitionScan(
        definition: machine.definition!,
        linesConsumed: machine.linesConsumed,
      );
    }
    return null;
  }

  /// Scans a link destination at [start], returning its raw text and end
  /// offset, or null. The raw text excludes angle brackets and is later
  /// unescaped and URI-normalized.
  static ({String raw, int start, int end})? scanDestination(
    String content,
    int start,
  ) {
    final brace = _braceDestination.matchAsPrefix(content, start);
    if (brace != null) {
      return (
        raw: content.substring(start + 1, brace.end - 1),
        start: start,
        end: brace.end,
      );
    }
    if (start < content.length && content.codeUnitAt(start) == 0x3C) {
      return null;
    }
    var cursor = start;
    var depth = 0;
    while (cursor < content.length) {
      final unit = content.codeUnitAt(cursor);
      if (unit == 0x5C) {
        if (cursor + 1 < content.length &&
            _isAsciiPunctuation(content.codeUnitAt(cursor + 1))) {
          cursor += 2;
          continue;
        }
        cursor++;
        continue;
      }
      if (unit == 0x28) {
        cursor++;
        depth++;
        continue;
      }
      if (unit == 0x29) {
        if (depth == 0) break;
        cursor++;
        depth--;
        continue;
      }
      if (_isDestinationWhitespace(unit)) break;
      cursor++;
    }
    if (cursor == start &&
        (cursor >= content.length || content.codeUnitAt(cursor) != 0x29)) {
      return null;
    }
    if (depth != 0) return null;
    return (raw: content.substring(start, cursor), start: start, end: cursor);
  }

  /// Length of a link label beginning at [start], or 0 when none matches.
  /// Labels longer than 1001 code units are rejected, matching CommonMark.
  static int scanLinkLabelLength(String source, int start, int end) {
    final match = _inlineLabel.matchAsPrefix(source, start);
    if (match == null || match.end > end) return 0;
    if (match.end - start > 1001) return 0;
    return match.end - start;
  }

  /// Scans a link title at [start] — double-quoted, single-quoted, or
  /// parenthesized — returning its decoded value and end offset, or null.
  static ({String title, int end})? scanTitle(
    String source,
    int start,
    int end,
  ) {
    final match = _title.matchAsPrefix(source, start);
    if (match == null || match.end > end) return null;
    return (
      title: unescape(source.substring(start + 1, match.end - 1)),
      end: match.end,
    );
  }

  /// Normalizes a raw `[label]` reference: trims, collapses whitespace to a
  /// single space, and Unicode case-folds (lowercase then uppercase), exactly
  /// like the reference implementation. Dart's `toUpperCase` keeps `ß`, so the
  /// JS-compatible `ß -> SS` expansion is applied explicitly.
  static String normalizeReference(String rawLabel) {
    final inner = rawLabel.substring(1, rawLabel.length - 1).trim();
    return inner
        .replaceAll(RegExp(r'[ \t\r\n]+'), ' ')
        .toLowerCase()
        .toUpperCase()
        .replaceAll('ß', 'SS');
  }

  /// Percent-encodes a URI the way the reference implementation does: valid
  /// `%XX` sequences are preserved, safe ASCII stays literal, and non-ASCII
  /// becomes UTF-8 percent-encoding (lone surrogates become `%EF%BF%BD`).
  static String normalizeUri(String uri) {
    final output = StringBuffer();
    var index = 0;
    final length = uri.length;
    while (index < length) {
      final code = uri.codeUnitAt(index);
      if (code == 0x25 && index + 2 < length) {
        final hex = uri.substring(index + 1, index + 3);
        if (_hexPair.hasMatch(hex)) {
          output.write(uri.substring(index, index + 3));
          index += 3;
          continue;
        }
      }
      if (code < 0x80) {
        output.write(_encodeCache[code]);
        index++;
        continue;
      }
      if (code >= 0xD800 && code <= 0xDFFF) {
        if (code >= 0xD800 &&
            code <= 0xDBFF &&
            index + 1 < length &&
            uri.codeUnitAt(index + 1) >= 0xDC00 &&
            uri.codeUnitAt(index + 1) <= 0xDFFF) {
          output.write(Uri.encodeComponent(uri.substring(index, index + 2)));
          index += 2;
          continue;
        }
        output.write('%EF%BF%BD');
        index++;
        continue;
      }
      output.write(Uri.encodeComponent(uri[index]));
      index++;
    }
    return output.toString();
  }

  /// Replaces backslash escapes and entity references with their decoded
  /// values, leaving everything else untouched.
  static String unescape(String value) {
    final output = StringBuffer();
    var cursor = 0;
    while (cursor < value.length) {
      final unit = value.codeUnitAt(cursor);
      if (unit == 0x5C) {
        if (cursor + 1 < value.length &&
            _isAsciiPunctuation(value.codeUnitAt(cursor + 1))) {
          output.writeCharCode(value.codeUnitAt(cursor + 1));
          cursor += 2;
          continue;
        }
      } else if (unit == 0x26) {
        final entity = _entityDecoder.decodeAt(value, cursor);
        if (entity != null) {
          output.write(entity.decodedText);
          cursor += entity.sourceLength;
          continue;
        }
      }
      output.writeCharCode(unit);
      cursor++;
    }
    return output.toString();
  }

  static bool _isAsciiPunctuation(int codeUnit) =>
      (codeUnit >= 0x21 && codeUnit <= 0x2F) ||
      (codeUnit >= 0x3A && codeUnit <= 0x40) ||
      (codeUnit >= 0x5B && codeUnit <= 0x60) ||
      (codeUnit >= 0x7B && codeUnit <= 0x7E);

  static bool _isDestinationWhitespace(int codeUnit) =>
      codeUnit == 0x20 ||
      codeUnit == 0x09 ||
      codeUnit == 0x0A ||
      codeUnit == 0x0B ||
      codeUnit == 0x0C ||
      codeUnit == 0x0D;
}

/// The result of a successful definition scan: the parsed definition plus the
/// number of candidate lines it consumed.
final class MarkdownLinkDefinitionScan {
  const MarkdownLinkDefinitionScan({
    required this.definition,
    required this.linesConsumed,
  });

  final MarkdownLinkDefinition definition;
  final int linesConsumed;
}

/// One stage of an incremental link-reference-definition scan. The machine
/// processes one candidate line per call and resumes from its saved state, so
/// each line's content is scanned at most once per definition attempt.
final class _DefinitionMachine {
  _DefinitionMachine(this.source, this.labelRawStart);

  final String source;

  /// Raw offset of the `[` that opened the label.
  final int labelRawStart;

  static const int _labelContentLimit = 1000;

  SourceRange? _line;
  int _pos = -1;
  _MachinePhase _phase = _MachinePhase.label;
  bool _spnlCrossed = false;
  bool _destSpnlCrossed = false;

  /// Number of candidate lines fed so far (current line index = this - 1).
  int _lineNumber = 0;

  // Label state.
  int labelRawEnd = -1;
  int _labelRepetitions = 0;
  final StringBuffer _labelText = StringBuffer();

  // Destination state.
  int destRawStart = -1;
  int destRawEnd = -1;
  int destLineNumber = -1;
  String? _destination;

  // Title state.
  int _titleDelimiter = 0;
  int titleRawStart = -1;
  int titleRawEnd = -1;
  final StringBuffer _titleText = StringBuffer();

  MarkdownLinkDefinition? definition;
  int linesConsumed = 0;
  bool done = false;
  bool failed = false;

  /// Processes one candidate line, advancing the scan from its saved state.
  void processLine(SourceRange line) {
    _line = line;
    _pos = line.start;
    _lineNumber++;
    if (_lineNumber == 1 && _phase == _MachinePhase.label) {
      // Start after the opening `[` (the machine's cursor begins at the
      // bracket that the caller's quick reject located).
      _pos = labelRawStart + 1;
    }
    while (!done && !failed && _pos < line.end) {
      switch (_phase) {
        case _MachinePhase.label:
          _scanLabel();
          break;
        case _MachinePhase.colonCheck:
          if (source.codeUnitAt(_pos) == 0x3A) {
            _pos++;
            _phase = _MachinePhase.afterColonSpnl;
          } else {
            failed = true;
          }
          break;
        case _MachinePhase.afterColonSpnl:
          while (_pos < line.end && source.codeUnitAt(_pos) == 0x20) {
            _pos++;
          }
          if (_pos < line.end) _phase = _MachinePhase.destination;
          break;
        case _MachinePhase.destination:
          _scanDestination();
          break;
        case _MachinePhase.afterDestSpnl:
          while (_pos < line.end && source.codeUnitAt(_pos) == 0x20) {
            _pos++;
          }
          if (_pos < line.end) _phase = _MachinePhase.titleCheck;
          break;
        case _MachinePhase.titleCheck:
          if (_pos < line.end) {
            final unit = source.codeUnitAt(_pos);
            if (_isTitleDelimiterCode(unit)) {
              _titleDelimiter = unit;
              titleRawStart = _pos;
              _titleText.clear();
              _pos++;
              _phase = _MachinePhase.title;
            } else {
              _rewindWithoutTitle();
            }
          } else {
            _rewindWithoutTitle();
          }
          break;
        case _MachinePhase.title:
          _scanTitle();
          break;
        case _MachinePhase.done:
        case _MachinePhase.failed:
          return;
      }
    }
    // Reached the end of the line while a phase can continue on the next one.
    if (done || failed) return;
    switch (_phase) {
      case _MachinePhase.label:
      case _MachinePhase.title:
        // The line boundary is a content character for labels and titles.
        if (_phase == _MachinePhase.label) {
          _labelText.write('\n');
        } else {
          _titleText.write('\n');
        }
        break;
      case _MachinePhase.afterColonSpnl:
        if (_spnlCrossed) {
          // The destination cannot start on a third line.
          failed = true;
          return;
        }
        _spnlCrossed = true;
        break;
      case _MachinePhase.afterDestSpnl:
        if (!_destSpnlCrossed) {
          _destSpnlCrossed = true;
        } else {
          // The crossed line held only spaces: no title follows.
          _rewindWithoutTitle();
          return;
        }
        break;
      case _MachinePhase.destination:
        if (_spnlCrossed) {
          // The crossed destination line was empty.
          failed = true;
          return;
        }
        _spnlCrossed = true;
        break;
      case _MachinePhase.colonCheck:
        failed = true; // a colon must directly follow the label
        return;
      case _MachinePhase.titleCheck:
        _rewindWithoutTitle();
        return;
      case _MachinePhase.done:
      case _MachinePhase.failed:
        return;
    }
  }

  void _scanLabel() {
    final unit = source.codeUnitAt(_pos);
    if (unit == 0x5C) {
      if (_pos + 1 >= _line!.end) {
        // `\` plus the line boundary form one escaped pair; the boundary
        // character is written by the line-end handling.
        _labelText.write('\\');
        _labelRepetitions++;
        _pos = _line!.end;
        return;
      }
      _labelText.writeCharCode(unit);
      _labelText.writeCharCode(source.codeUnitAt(_pos + 1));
      _labelRepetitions++;
      _pos += 2;
    } else if (unit == 0x5B) {
      failed = true;
      return;
    } else if (unit == 0x5D) {
      if (labelRawEnd < 0) {
        labelRawEnd = _pos;
        if (_pos - labelRawStart + 1 > 1001) {
          failed = true;
          return;
        }
        _pos++;
        _phase = _MachinePhase.colonCheck;
        return;
      }
    } else {
      _labelText.writeCharCode(unit);
      _labelRepetitions++;
      _pos++;
    }
    if (_labelRepetitions > _labelContentLimit) failed = true;
  }

  void _scanDestination() {
    final destination = MarkdownLinkReferenceScanner.scanDestination(
      source,
      _pos,
    );
    if (destination == null) {
      failed = true;
      return;
    }
    destRawStart = destination.start;
    destRawEnd = destination.end;
    destLineNumber = _lineNumber - 1;
    _destination = MarkdownLinkReferenceScanner.normalizeUri(
      MarkdownLinkReferenceScanner.unescape(destination.raw),
    );
    _pos = destination.end;
    _phase = _MachinePhase.afterDestSpnl;
  }

  void _scanTitle() {
    final unit = source.codeUnitAt(_pos);
    if (unit == 0x5C) {
      if (_pos + 1 >= _line!.end) {
        // `\` plus the line boundary form one escaped pair.
        _titleText.write('\\');
        _pos = _line!.end;
        return;
      }
      final next = source.codeUnitAt(_pos + 1);
      // `\` plus any character (including another backslash, which is part of
      // the escapable class) is one escaped pair.
      _titleText.writeCharCode(unit);
      _titleText.writeCharCode(next);
      _pos += 2;
      return;
    }
    if (unit == _titleDelimiter) {
      final title = MarkdownLinkReferenceScanner.unescape(
        _titleText.toString(),
      );
      titleRawEnd = _pos;
      _pos++;
      // The title must be the last thing on its line.
      var probe = _pos;
      final lineEnd = _line!.end;
      while (probe < lineEnd && source.codeUnitAt(probe) == 0x20) {
        probe++;
      }
      if (probe == lineEnd) {
        _finish(title);
      } else {
        // Trailing content after the title: discard it and fall back to the
        // destination-only definition when the destination reaches a line end.
        _rewindWithoutTitle();
      }
      return;
    }
    if (unit == 0x00 ||
        (_titleDelimiter == 0x28 && (unit == 0x28 || unit == 0x29))) {
      _rewindWithoutTitle();
      return;
    }
    _titleText.writeCharCode(unit);
    _pos++;
  }

  /// The reference discards an absent/failed title and accepts the
  /// destination alone when it reaches a line end.
  void _rewindWithoutTitle() {
    var probe = destRawEnd;
    while (probe < source.length && source.codeUnitAt(probe) == 0x20) {
      probe++;
    }
    if (probe >= source.length || _isLineEnding(source.codeUnitAt(probe))) {
      _finish(null);
    } else {
      failed = true;
    }
  }

  void _finish(String? title) {
    final normalizedLabel = MarkdownLinkReferenceScanner.normalizeReference(
      '[$_labelText]',
    );
    if (normalizedLabel.isEmpty) {
      // The label must contain non-whitespace characters.
      failed = true;
      return;
    }
    definition = MarkdownLinkDefinition(
      label: normalizedLabel,
      destination: _destination!,
      title: title,
      labelRange: SourceRange(labelRawStart, labelRawEnd + 1),
      destinationRange: SourceRange(destRawStart, destRawEnd),
      titleRange: title == null
          ? null
          : SourceRange(titleRawStart, titleRawEnd + 1),
    );
    linesConsumed = (title == null ? destLineNumber : _lineNumber - 1) + 1;
    done = true;
  }

  /// Resolves a pending state when no more candidate lines exist, mirroring
  /// the reference implementation on the truncated content.
  void resolveAtEnd() {
    if (done || failed) return;
    switch (_phase) {
      case _MachinePhase.afterDestSpnl:
      case _MachinePhase.title:
      case _MachinePhase.titleCheck:
        _rewindWithoutTitle();
        break;
      default:
        // An unclosed label or a missing destination fails like the reference.
        failed = true;
    }
  }
}

enum _MachinePhase {
  label,
  colonCheck,
  afterColonSpnl,
  destination,
  afterDestSpnl,
  titleCheck,
  title,
  done,
  failed,
}

bool _isTitleDelimiterCode(int unit) =>
    unit == 0x22 || unit == 0x27 || unit == 0x28;

bool _isLineEnding(int unit) => unit == 0x0A || unit == 0x0D;
