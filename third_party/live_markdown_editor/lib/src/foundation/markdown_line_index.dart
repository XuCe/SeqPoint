/// Physical line starts for [source], one entry per line (the first is 0).
///
/// Shared by the rendering paths that need a source line index without
/// copying prefixes of the document (`substring(0, offset)` + newline scan).
List<int> markdownLineStarts(String source) {
  final starts = <int>[0];
  for (var index = 0; index < source.length; index++) {
    if (source.codeUnitAt(index) == 0x0A) starts.add(index + 1);
  }
  return starts;
}

/// Zero-based physical line index containing [offset].
///
/// Equivalent to counting the newlines before [offset], but O(log n) once the
/// [lineStarts] index exists. Offsets past the last line clamp to it.
int markdownLineIndexFor(List<int> lineStarts, int offset) {
  var low = 0;
  var high = lineStarts.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (lineStarts[middle] > offset) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  return low == 0 ? 0 : low - 1;
}
