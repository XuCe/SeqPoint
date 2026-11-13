import '../model/source_range.dart';

/// The visual behavior of a source-backed projection segment.
///
/// [text] preserves one visual UTF-16 position per source position. [hidden]
/// and [decoration] collapse their source ranges to one visual boundary.
/// [widget] is atomic and occupies exactly one visual placeholder.
enum MarkdownProjectionSegmentKind { text, hidden, widget, decoration }

/// One ordered piece of a source-to-visual Markdown projection.
final class MarkdownProjectionSegment {
  const MarkdownProjectionSegment.text({
    required this.sourceRange,
    required this.text,
  }) : kind = MarkdownProjectionSegmentKind.text,
       id = null;

  const MarkdownProjectionSegment.hidden({required this.sourceRange})
    : kind = MarkdownProjectionSegmentKind.hidden,
      text = null,
      id = null;

  const MarkdownProjectionSegment.widget({
    required this.sourceRange,
    required this.id,
  }) : kind = MarkdownProjectionSegmentKind.widget,
       text = null;

  const MarkdownProjectionSegment.decoration({
    required this.sourceRange,
    required this.id,
  }) : kind = MarkdownProjectionSegmentKind.decoration,
       text = null;

  final SourceRange sourceRange;
  final MarkdownProjectionSegmentKind kind;
  final String? text;
  final Object? id;

  /// Number of visual UTF-16 positions occupied by this segment.
  int get visualLength => switch (kind) {
    MarkdownProjectionSegmentKind.text => text!.length,
    MarkdownProjectionSegmentKind.widget => 1,
    MarkdownProjectionSegmentKind.hidden ||
    MarkdownProjectionSegmentKind.decoration => 0,
  };
}
