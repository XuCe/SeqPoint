/// A half-open range of UTF-16 code-unit offsets into Markdown source.
///
/// Offsets match Flutter's `TextEditingValue` coordinate space; grapheme
/// navigation still uses Flutter's Unicode boundaries.
final class SourceRange {
  /// Creates a range from [start] to [end], both inclusive-exclusive.
  const SourceRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  /// First offset included by the range.
  final int start;

  /// First offset not included by the range.
  final int end;

  /// Number of UTF-16 code units covered by the range.
  int get length => end - start;

  /// Whether [offset] lies inside the range (including [start], excluding
  /// [end]).
  bool contains(int offset) => start <= offset && offset < end;

  /// Whether this range overlaps [other] in at least one offset.
  bool intersects(SourceRange other) => start < other.end && other.start < end;

  /// Returns a copy moved by [delta] code units.
  SourceRange shift(int delta) => SourceRange(start + delta, end + delta);

  /// Returns the substring of [source] covered by this range.
  String slice(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is SourceRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SourceRange($start, $end)';
}
