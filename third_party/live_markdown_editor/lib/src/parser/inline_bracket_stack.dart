/// One open `[` or `![` bracket candidate used while resolving CommonMark
/// links and images.
///
/// Records are pushed in source order; a `]` always pairs with the top of the
/// stack. When a link (not an image) resolves, every earlier non-image opener
/// is deactivated so links cannot nest while images inside links remain legal.
final class MarkdownBracketOpener<T> {
  MarkdownBracketOpener({
    required this.element,
    required this.index,
    required this.image,
    required this.delimiterBottom,
  });

  /// The sequence element owning the `[` or `![` text node.
  final T element;

  /// Source offset of the `[` (for images this is the offset of the bracket,
  /// one after the `!`).
  final int index;

  /// True for `![` image openers.
  final bool image;

  /// The delimiter-stack depth recorded when this bracket was opened; emphasis
  /// delimiters at or above this index are the bracket's content.
  final int delimiterBottom;

  /// Links are deactivated when a nested link resolves.
  bool active = true;

  /// Set on an opener when a later bracket opens inside it; a shortcut or
  /// collapsed reference is only attempted when no nested bracket was seen.
  bool bracketAfter = false;
}

/// LIFO stack of open bracket candidates with the link-nesting rule.
final class MarkdownInlineBracketStack<T> {
  final List<MarkdownBracketOpener<T>> _openers = [];

  MarkdownBracketOpener<T>? get top => _openers.isEmpty ? null : _openers.last;

  bool get isEmpty => _openers.isEmpty;

  void push(MarkdownBracketOpener<T> opener) {
    if (_openers.isNotEmpty) _openers.last.bracketAfter = true;
    _openers.add(opener);
  }

  void pop() => _openers.removeLast();

  /// Deactivates every earlier non-image opener ("no links in links").
  void deactivateEarlierLinks() {
    for (final opener in _openers) {
      if (!opener.image) opener.active = false;
    }
  }
}
