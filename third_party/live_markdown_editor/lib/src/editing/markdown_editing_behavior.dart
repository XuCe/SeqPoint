/// Independently configurable typing assistance for the Markdown surface.
///
/// All behaviors default to enabled; disable any of them for a plain
/// text-editing experience. IME composing edits bypass these transforms.
final class MarkdownEditingBehavior {
  /// Creates a behavior with the given toggles and [indentWidth].
  const MarkdownEditingBehavior({
    this.autoPair = true,
    this.wrapSelection = true,
    this.smartLists = true,
    this.autoCloseFences = true,
    this.indentWidth = 4,
  }) : assert(indentWidth > 0);

  /// Pairs markdown delimiters such as `*`, `_`, and backticks as typed.
  final bool autoPair;

  /// Wraps the current selection when a delimiter is typed around it.
  final bool wrapSelection;

  /// Auto-continues ordered, unordered, and task list items on Enter.
  final bool smartLists;

  /// Completes a fenced code block by adding a closing fence on the final
  /// line when the opening fence is left empty.
  final bool autoCloseFences;

  /// Number of spaces inserted for Tab and list continuation indentation.
  final int indentWidth;
}
