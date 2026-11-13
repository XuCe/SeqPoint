import 'package:flutter/widgets.dart';

/// Controls how paragraph direction is resolved from Markdown source.
enum MarkdownDirectionMode { ltr, rtl, auto, aware }

/// Resolves text direction using the first Unicode language letter.
final class MarkdownDirectionResolver {
  const MarkdownDirectionResolver();

  static final RegExp _letter = RegExp(r'^\p{L}$', unicode: true);

  List<TextDirection> resolve(
    String source, {
    required MarkdownDirectionMode mode,
    TextDirection fallback = TextDirection.ltr,
  }) {
    final lines = source.split('\n');
    return switch (mode) {
      MarkdownDirectionMode.ltr => List.filled(lines.length, TextDirection.ltr),
      MarkdownDirectionMode.rtl => List.filled(lines.length, TextDirection.rtl),
      MarkdownDirectionMode.auto => List.filled(
        lines.length,
        _firstLanguageDirection(source) ?? fallback,
      ),
      MarkdownDirectionMode.aware => _resolveAware(lines, fallback),
    };
  }

  List<TextDirection> _resolveAware(
    List<String> lines,
    TextDirection fallback,
  ) {
    var inherited = fallback;
    return [
      for (final line in lines)
        inherited = _firstLanguageDirection(line) ?? inherited,
    ];
  }

  /// Resolves the direction of the first language letter in [text].
  TextDirection? firstDirection(String text) => _firstLanguageDirection(text);

  TextDirection? _firstLanguageDirection(String text) {
    for (final rune in _withoutLeadingMarkdownSyntax(text).runes) {
      final character = String.fromCharCode(rune);
      if (!_letter.hasMatch(character)) {
        continue;
      }
      return _isRtlLetter(rune) ? TextDirection.rtl : TextDirection.ltr;
    }
    return null;
  }

  String _withoutLeadingMarkdownSyntax(String text) {
    var content = text;
    final blockPrefix = RegExp(
      r'^(?:[ \t]{0,3}(?:>[ \t]?|#{1,6}[ \t]+|[-+*][ \t]+|\d+[.)][ \t]+))+',
    ).firstMatch(content);
    if (blockPrefix != null) content = content.substring(blockPrefix.end);
    final taskPrefix = RegExp(r'^\[[ xX]\][ \t]*').firstMatch(content);
    if (taskPrefix != null) content = content.substring(taskPrefix.end);
    return content;
  }

  bool _isRtlLetter(int rune) =>
      _in(rune, 0x0590, 0x08FF) ||
      _in(rune, 0xFB1D, 0xFDFF) ||
      _in(rune, 0xFE70, 0xFEFF) ||
      _in(rune, 0x10800, 0x10FFF) ||
      _in(rune, 0x1E800, 0x1EEFF);

  bool _in(int value, int start, int end) => value >= start && value <= end;
}
