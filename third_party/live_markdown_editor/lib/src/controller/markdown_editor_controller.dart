import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../extensions/markdown_syntax_configuration.dart';
import '../parser/block_parser.dart';
import '../parser/markdown_document.dart';
import 'edit_transaction.dart';
import 'markdown_command.dart';

enum MarkdownEditorMode { raw, live, read }

final class MarkdownEditorController extends TextEditingController {
  MarkdownEditorController({
    String text = '',
    MarkdownEditorMode mode = MarkdownEditorMode.live,
    this.historyLimit = 100,
  }) : // Public API intentionally names this parameter `mode`.
       // ignore: prefer_initializing_formals
       _mode = mode,
       super(text: text) {
    _document = _parser.parse(text);
    _documents[_defaultSyntax.parserCacheKey] = _document;
  }

  static const MarkdownBlockParser _parser = MarkdownBlockParser();
  static const MarkdownSyntaxConfiguration _defaultSyntax =
      MarkdownSyntaxConfiguration.editorDefaults();

  final int historyLimit;
  final List<EditTransaction> _undo = [];
  final List<EditTransaction> _redo = [];
  final Map<String, MarkdownDocument> _documents = {};
  final Set<int> _foldedBlockStarts = <int>{};
  late MarkdownDocument _document;
  MarkdownEditorMode _mode;

  MarkdownDocument get document => _document;

  /// Returns a disposable parse snapshot for [syntax] and the current source.
  ///
  /// Until the CommonMark parser accepts syntax profiles, every valid profile
  /// uses the compatible parser while still receiving an isolated snapshot.
  MarkdownDocument documentFor(MarkdownSyntaxConfiguration syntax) {
    final cacheKey = syntax.parserCacheKey;
    final cached = _documents[cacheKey];
    if (cached != null && cached.source == text) return cached;
    final document = MarkdownBlockParser(syntax: syntax).parse(text);
    _documents[cacheKey] = document;
    return document;
  }

  MarkdownEditorMode get mode => _mode;
  TextRange get composing => value.composing;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  set mode(MarkdownEditorMode value) {
    if (value == _mode) return;
    _mode = value;
    notifyListeners();
  }

  @override
  set value(TextEditingValue newValue) {
    if (_document.source != newValue.text) {
      _shiftFolds(text, newValue.text);
      _document = _parser.parseIncremental(_document, newValue.text).document;
      _documents
        ..clear()
        ..[_defaultSyntax.parserCacheKey] = _document;
    }
    super.value = newValue;
  }

  /// Start offsets of blocks the user folded, in source order.
  ///
  /// Fold state is view state: it is shared by every surface driven by this
  /// controller, survives edits (shifted by the edit diff, dropped when the
  /// fold's own start is replaced), and is never an undo step. An offset is
  /// only effective while the current document has a foldable block starting
  /// there; stale offsets are inert and ignored by the fold resolver.
  Set<int> get foldedBlockStarts => Set.unmodifiable(_foldedBlockStarts);

  bool isFoldedAt(int blockStart) => _foldedBlockStarts.contains(blockStart);

  void toggleFoldAt(int blockStart) {
    if (blockStart < 0 || blockStart > text.length) return;
    if (!_foldedBlockStarts.remove(blockStart)) {
      _foldedBlockStarts.add(blockStart);
    }
    notifyListeners();
  }

  void setFoldedBlockStarts(Iterable<int> starts) {
    final next = <int>{
      for (final start in starts)
        if (start >= 0 && start <= text.length) start,
    };
    if (next.length == _foldedBlockStarts.length &&
        next.every(_foldedBlockStarts.contains)) {
      return;
    }
    _foldedBlockStarts
      ..clear()
      ..addAll(next);
    notifyListeners();
  }

  void clearFolds() => setFoldedBlockStarts(const {});

  void _shiftFolds(String oldText, String newText) {
    if (_foldedBlockStarts.isEmpty || oldText == newText) return;
    final sharedLength = oldText.length < newText.length
        ? oldText.length
        : newText.length;
    var prefix = 0;
    while (prefix < sharedLength && oldText[prefix] == newText[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < sharedLength - prefix &&
        oldText[oldText.length - suffix - 1] ==
            newText[newText.length - suffix - 1]) {
      suffix++;
    }
    final oldEditEnd = oldText.length - suffix;
    final delta = newText.length - oldText.length;
    final insertion = oldEditEnd == prefix && delta > 0;
    final mapped = <int>{};
    for (final start in _foldedBlockStarts) {
      if (insertion ? start < prefix : start <= prefix) {
        mapped.add(start);
      } else if (start >= oldEditEnd) {
        mapped.add(start + delta);
      }
    }
    _foldedBlockStarts
      ..clear()
      ..addAll(mapped);
  }

  void execute(MarkdownCommand command, {String? argument}) {
    switch (command) {
      case MarkdownCommand.bold:
        _wrap('**', '**');
      case MarkdownCommand.italic:
        _wrap('*', '*');
      case MarkdownCommand.strikethrough:
        _wrap('~~', '~~');
      case MarkdownCommand.highlight:
        _wrap('==', '==');
      case MarkdownCommand.inlineCode:
        _wrap('`', '`');
      case MarkdownCommand.link:
        _wrap('[', '](${argument ?? ''})');
      case MarkdownCommand.heading1:
      case MarkdownCommand.heading2:
      case MarkdownCommand.heading3:
      case MarkdownCommand.heading4:
      case MarkdownCommand.heading5:
      case MarkdownCommand.heading6:
        final level = command.index - MarkdownCommand.heading1.index + 1;
        _prefixLines((_) => '${'#' * level} ');
      case MarkdownCommand.blockquote:
        _prefixLines((_) => '> ');
      case MarkdownCommand.unorderedList:
        _prefixLines((_) => '- ');
      case MarkdownCommand.orderedList:
        _prefixLines((index) => '${index + 1}. ');
      case MarkdownCommand.taskList:
        _prefixLines((_) => '- [ ] ');
      case MarkdownCommand.fencedCode:
        final language = argument?.trim() ?? '';
        _wrap('```$language\n', '\n```');
      case MarkdownCommand.horizontalRule:
        _insertRule();
    }
  }

  void toggleTaskAt(int sourceOffset) {
    if (sourceOffset < 0 || sourceOffset > text.length) return;
    final lineStart = text.lastIndexOf('\n', math.max(0, sourceOffset - 1)) + 1;
    final lineEndCandidate = text.indexOf('\n', sourceOffset);
    final lineEnd = lineEndCandidate < 0 ? text.length : lineEndCandidate;
    final line = text.substring(lineStart, lineEnd);
    final match = RegExp(r'^\s*(?:>\s*)*(?:[-+*]|\d+[.)])\s+\[([ xX])\]')
        .firstMatch(line);
    if (match == null) return;
    final markerOffset =
        lineStart + match.start + match.group(0)!.lastIndexOf('[') + 1;
    final checked = match.group(1)!.toLowerCase() == 'x';
    _replace(markerOffset, markerOffset + 1, checked ? ' ' : 'x');
  }

  void undo() {
    if (_undo.isEmpty) return;
    final transaction = _undo.removeLast();
    _redo.add(transaction);
    value = transaction.before;
  }

  void redo() {
    if (_redo.isEmpty) return;
    final transaction = _redo.removeLast();
    _undo.add(transaction);
    value = transaction.after;
  }

  /// Applies a user edit and records it as one undoable transaction.
  void applyEditingValue(TextEditingValue nextValue) {
    if (nextValue == value) return;
    _record(EditTransaction(before: value, after: nextValue));
    value = nextValue;
  }

  void _wrap(String opening, String closing) {
    final start = selection.start;
    final end = selection.end;
    if (start < 0 || end < 0) return;
    final selected = text.substring(start, end);
    final replacement = '$opening$selected$closing';
    final contentStart = start + opening.length;
    final contentEnd = contentStart + selected.length;
    final reversed = selection.baseOffset > selection.extentOffset;
    _replace(
      start,
      end,
      replacement,
      selection: selected.isEmpty
          ? TextSelection.collapsed(offset: contentStart)
          : TextSelection(
              baseOffset: reversed ? contentEnd : contentStart,
              extentOffset: reversed ? contentStart : contentEnd,
            ),
    );
  }

  void _prefixLines(String Function(int index) prefixFor) {
    final start = selection.start;
    final end = selection.end;
    if (start < 0 || end < 0) return;
    final lineStart = text.lastIndexOf('\n', math.max(0, start - 1)) + 1;
    final endNewline = text.indexOf('\n', end);
    final lineEnd = endNewline < 0 ? text.length : endNewline;
    final lines = text.substring(lineStart, lineEnd).split('\n');
    final prefixes = List.generate(lines.length, prefixFor);
    final replacement = [
      for (var index = 0; index < lines.length; index++)
        '${prefixes[index]}${lines[index]}',
    ].join('\n');
    final addedBeforeBase = prefixes
        .take(_lineIndexAt(text, lineStart, selection.baseOffset) + 1)
        .fold(0, (sum, prefix) => sum + prefix.length);
    final addedBeforeExtent = prefixes
        .take(_lineIndexAt(text, lineStart, selection.extentOffset) + 1)
        .fold(0, (sum, prefix) => sum + prefix.length);
    _replace(
      lineStart,
      lineEnd,
      replacement,
      selection: TextSelection(
        baseOffset: selection.baseOffset + addedBeforeBase,
        extentOffset: selection.extentOffset + addedBeforeExtent,
      ),
    );
  }

  int _lineIndexAt(String source, int lineStart, int offset) =>
      '\n'.allMatches(source.substring(lineStart, offset)).length;

  void _insertRule() {
    final offset = selection.extentOffset;
    if (offset < 0) return;
    final needsLeading = offset > 0 && text[offset - 1] != '\n';
    final needsTrailing = offset < text.length && text[offset] != '\n';
    final insertion =
        '${needsLeading ? '\n' : ''}---${needsTrailing ? '\n' : ''}';
    _replace(
      offset,
      offset,
      insertion,
      selection: TextSelection.collapsed(offset: offset + insertion.length),
    );
  }

  void _replace(
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
  }) {
    final before = value;
    final newText = text.replaceRange(start, end, replacement);
    final delta = replacement.length - (end - start);
    final newSelection =
        selection ?? _shiftSelection(before.selection, start, end, delta);
    final after = TextEditingValue(
      text: newText,
      selection: newSelection,
      composing: _shiftRange(before.composing, start, end, delta),
    );
    _record(EditTransaction(before: before, after: after));
    value = after;
  }

  TextSelection _shiftSelection(
    TextSelection value,
    int start,
    int end,
    int delta,
  ) => TextSelection(
    baseOffset: _shiftOffset(value.baseOffset, start, end, delta),
    extentOffset: _shiftOffset(value.extentOffset, start, end, delta),
    affinity: value.affinity,
    isDirectional: value.isDirectional,
  );

  TextRange _shiftRange(TextRange range, int start, int end, int delta) {
    if (!range.isValid || range.isCollapsed) return range;
    if (end <= range.start) {
      return TextRange(start: range.start + delta, end: range.end + delta);
    }
    if (start >= range.end) return range;
    return TextRange.empty;
  }

  int _shiftOffset(int offset, int start, int end, int delta) {
    if (offset <= start) return offset;
    if (offset >= end) return offset + delta;
    return start;
  }

  void _record(EditTransaction transaction) {
    _undo.add(transaction);
    if (_undo.length > historyLimit) _undo.removeAt(0);
    _redo.clear();
  }
}
