import 'package:flutter/services.dart';

import 'markdown_projection_segment.dart';

/// Deterministic mapping between canonical source offsets and projected
/// visual offsets.
final class MarkdownSourcePositionMapper {
  /// When [source] is supplied, caret offsets also snap to its global grapheme
  /// boundaries, including graphemes split across adjacent segments.
  MarkdownSourcePositionMapper(
    List<MarkdownProjectionSegment> segments, {
    String? source,
  }) : segments = List.unmodifiable(segments),
       _source = source,
       _sourceBoundary = source == null ? null : CharacterBoundary(source),
       _entries = _buildEntries(segments, sourceLength: source?.length);

  final List<MarkdownProjectionSegment> segments;
  final String? _source;
  final CharacterBoundary? _sourceBoundary;
  final List<_MappedSegment> _entries;

  int get visualLength => _entries.isEmpty ? 0 : _entries.last.visualEnd;

  int get _sourceLength =>
      _source?.length ??
      (_entries.isEmpty ? 0 : _entries.last.segment.sourceRange.end);

  int sourceToVisual(
    int sourceOffset, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    if (_entries.isEmpty) return 0;
    final clamped = _snapSourceOffset(
      sourceOffset.clamp(0, _sourceLength),
      affinity: affinity,
    );
    int? upstreamBoundary;
    int? downstreamBoundary;
    _MappedSegment? previous;

    // Entries are ordered and non-overlapping, so the first entry that can
    // touch the offset is the first whose source range ends at or after it;
    // everything earlier only matters as the upstream neighbour.
    var index = _firstEntryEndingAtOrAfter(clamped);
    if (index > 0) previous = _entries[index - 1];

    for (; index < _entries.length; index++) {
      final entry = _entries[index];
      final range = entry.segment.sourceRange;
      if (clamped < range.start) {
        if (upstreamBoundary != null) break;
        return affinity == TextAffinity.upstream
            ? previous?.visualEnd ?? 0
            : entry.visualStart;
      }
      if (clamped > range.start && clamped < range.end) {
        if (entry.segment.kind == MarkdownProjectionSegmentKind.text) {
          return entry.visualStart +
              entry.snapTextOffset(clamped - range.start, affinity: affinity);
        }
        if (entry.segment.kind == MarkdownProjectionSegmentKind.widget) {
          return affinity == TextAffinity.upstream
              ? entry.visualStart
              : entry.visualEnd;
        }
        return entry.visualStart;
      }
      if (clamped == range.start) {
        upstreamBoundary = upstreamBoundary == null
            ? entry.visualStart
            : upstreamBoundary < entry.visualStart
            ? upstreamBoundary
            : entry.visualStart;
        downstreamBoundary = downstreamBoundary == null
            ? entry.visualStart
            : downstreamBoundary > entry.visualStart
            ? downstreamBoundary
            : entry.visualStart;
      }
      if (clamped == range.end) {
        upstreamBoundary = upstreamBoundary == null
            ? entry.visualEnd
            : upstreamBoundary < entry.visualEnd
            ? upstreamBoundary
            : entry.visualEnd;
        downstreamBoundary = downstreamBoundary == null
            ? entry.visualEnd
            : downstreamBoundary > entry.visualEnd
            ? downstreamBoundary
            : entry.visualEnd;
      }
      previous = entry;
    }
    if (upstreamBoundary != null) {
      return affinity == TextAffinity.upstream
          ? upstreamBoundary
          : downstreamBoundary!;
    }
    return visualLength;
  }

  int visualToSource(
    int visualOffset, {
    TextAffinity affinity = TextAffinity.downstream,
  }) {
    if (_entries.isEmpty) return 0;
    final clamped = visualOffset.clamp(0, visualLength);
    int? upstreamBoundary;
    int? downstreamBoundary;

    // Mirrors sourceToVisual: start at the first entry whose visual range
    // ends at or after the offset and stop once entries begin past it.
    for (
      var index = _firstEntryEndingAtOrAfter(clamped, visual: true);
      index < _entries.length;
      index++
    ) {
      final entry = _entries[index];
      if (entry.visualStart > clamped) break;
      final range = entry.segment.sourceRange;
      if (clamped == entry.visualStart) {
        upstreamBoundary = upstreamBoundary == null
            ? range.start
            : upstreamBoundary < range.start
            ? upstreamBoundary
            : range.start;
        downstreamBoundary = downstreamBoundary == null
            ? range.start
            : downstreamBoundary > range.start
            ? downstreamBoundary
            : range.start;
      }
      if (clamped == entry.visualEnd) {
        upstreamBoundary = upstreamBoundary == null
            ? range.end
            : upstreamBoundary < range.end
            ? upstreamBoundary
            : range.end;
        downstreamBoundary = downstreamBoundary == null
            ? range.end
            : downstreamBoundary > range.end
            ? downstreamBoundary
            : range.end;
      }
      if (clamped > entry.visualStart && clamped < entry.visualEnd) {
        if (entry.segment.kind == MarkdownProjectionSegmentKind.text) {
          return _snapSourceOffset(
            range.start +
                entry.snapTextOffset(
                  clamped - entry.visualStart,
                  affinity: affinity,
                ),
            affinity: affinity,
          );
        }
        return _snapSourceOffset(
          affinity == TextAffinity.upstream ? range.start : range.end,
          affinity: affinity,
        );
      }
    }

    if (upstreamBoundary != null) {
      return _snapSourceOffset(
        affinity == TextAffinity.upstream
            ? upstreamBoundary
            : downstreamBoundary!,
        affinity: affinity,
      );
    }
    return _snapSourceOffset(_sourceLength, affinity: affinity);
  }

  /// First entry whose source (or visual) range ends at or after [offset].
  ///
  /// Entry ranges are ordered and non-overlapping, so both the source ends and
  /// the visual ends are non-decreasing and can be binary searched.
  int _firstEntryEndingAtOrAfter(int offset, {bool visual = false}) {
    var low = 0;
    var high = _entries.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      final end = visual
          ? _entries[middle].visualEnd
          : _entries[middle].segment.sourceRange.end;
      if (end >= offset) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return low;
  }

  int _snapSourceOffset(int offset, {required TextAffinity affinity}) {
    final clamped = offset.clamp(0, _sourceLength);
    final boundary = _sourceBoundary;
    if (boundary == null || clamped == 0 || clamped == _sourceLength) {
      return clamped;
    }
    final leading = boundary.getLeadingTextBoundaryAt(clamped) ?? 0;
    if (leading == clamped) return clamped;
    if (affinity == TextAffinity.upstream) return leading;
    return boundary.getTrailingTextBoundaryAt(clamped) ?? _sourceLength;
  }

  static List<_MappedSegment> _buildEntries(
    List<MarkdownProjectionSegment> segments, {
    int? sourceLength,
  }) {
    final entries = <_MappedSegment>[];
    var previousSourceEnd = 0;
    var visualOffset = 0;
    for (var index = 0; index < segments.length; index += 1) {
      final segment = segments[index];
      final range = segment.sourceRange;
      if (range.start < 0 || range.end < range.start) {
        throw ArgumentError.value(
          range,
          'segments',
          'Source ranges must be non-negative and half-open.',
        );
      }
      if (sourceLength != null && range.end > sourceLength) {
        throw ArgumentError.value(
          range,
          'segments',
          'Source ranges must be inside the supplied source.',
        );
      }
      if (index > 0 && segment.sourceRange.start < previousSourceEnd) {
        throw ArgumentError.value(
          segments,
          'segments',
          'Source ranges must be ordered and non-overlapping.',
        );
      }
      if (segment.kind == MarkdownProjectionSegmentKind.text &&
          segment.text!.length != segment.sourceRange.length) {
        throw ArgumentError.value(
          segment.text,
          'segment.text',
          'Visible text must preserve its source UTF-16 length.',
        );
      }
      entries.add(
        _MappedSegment(
          segment: segment,
          visualStart: visualOffset,
          visualEnd: visualOffset + segment.visualLength,
        ),
      );
      previousSourceEnd = segment.sourceRange.end;
      visualOffset += segment.visualLength;
    }
    return List.unmodifiable(entries);
  }
}

final class _MappedSegment {
  _MappedSegment({
    required this.segment,
    required this.visualStart,
    required this.visualEnd,
  }) : _characterBoundary = segment.kind == MarkdownProjectionSegmentKind.text
           ? CharacterBoundary(segment.text!)
           : null;

  final MarkdownProjectionSegment segment;
  final int visualStart;
  final int visualEnd;
  final CharacterBoundary? _characterBoundary;

  int snapTextOffset(int offset, {required TextAffinity affinity}) {
    final textLength = segment.text!.length;
    final clamped = offset.clamp(0, textLength);
    if (clamped == 0 || clamped == textLength) return clamped;
    final boundary = _characterBoundary!;
    final leading = boundary.getLeadingTextBoundaryAt(clamped) ?? 0;
    if (leading == clamped) return clamped;
    if (affinity == TextAffinity.upstream) return leading;
    return boundary.getTrailingTextBoundaryAt(clamped) ?? textLength;
  }
}
