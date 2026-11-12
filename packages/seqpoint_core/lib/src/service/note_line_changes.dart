import '../model/note.dart';

/// Match unchanged edges first, then unique moved lines. Ambiguous or replaced
/// lines leave their old items independent instead of assigning them a new task.
Map<int, int> movedNoteLines(List<String> before, List<String> after) {
  final oldTitles = before.map(Note.lineTitle).toList();
  final newTitles = after.map(Note.lineTitle).toList();
  final result = <int, int>{};
  var first = 0;
  while (first < oldTitles.length &&
      first < newTitles.length &&
      oldTitles[first] == newTitles[first]) {
    result[first] = first;
    first++;
  }
  var oldEnd = oldTitles.length;
  var newEnd = newTitles.length;
  while (first < oldEnd && first < newEnd && oldTitles[oldEnd - 1] == newTitles[newEnd - 1]) {
    result[--oldEnd] = --newEnd;
  }
  Map<String, int> unique(List<String> titles, int end) {
    final indexes = <String, int>{};
    for (var i = first; i < end; i++) {
      indexes.update(titles[i], (_) => -1, ifAbsent: () => i);
    }
    return indexes;
  }

  final destinations = unique(newTitles, newEnd);
  for (final entry in unique(oldTitles, oldEnd).entries) {
    final target = destinations[entry.key];
    if (entry.value >= 0 && target != null && target >= 0) result[entry.value] = target;
  }
  return result;
}
