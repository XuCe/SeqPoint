import '../model/note.dart';

/// Match unchanged edges first, then unique moved lines. Ambiguous or replaced
/// lines leave their old items independent instead of assigning them a new task.
///
/// Old lines listed in [similar] may also match a new line that is a light
/// in-place edit of them (a typo fixed, a word added), taken in order.
Map<int, int> movedNoteLines(List<String> before, List<String> after,
    {Set<int> similar = const {}}) {
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

  final taken = result.values.toSet();
  var from = first;
  for (var i = first; i < oldEnd; i++) {
    if (!similar.contains(i) || result.containsKey(i) || oldTitles[i].isEmpty) continue;
    for (var j = from; j < newEnd; j++) {
      if (taken.contains(j) || !_lightlyEdited(oldTitles[i], newTitles[j])) continue;
      result[i] = j;
      taken.add(j);
      from = j + 1;
      break;
    }
  }
  return result;
}

/// Two non-empty lines share at least 60% of their characters in order.
bool _lightlyEdited(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  final x = a.runes.toList();
  final y = b.runes.toList();
  final total = x.length + y.length;
  final shorter = x.length < y.length ? x.length : y.length;
  if (shorter * 2 * 5 < total * 3) return false;
  var previous = List<int>.filled(y.length + 1, 0);
  for (final c in x) {
    final row = List<int>.filled(y.length + 1, 0);
    for (var k = 0; k < y.length; k++) {
      row[k + 1] = c == y[k]
          ? previous[k] + 1
          : (row[k] > previous[k + 1] ? row[k] : previous[k + 1]);
    }
    previous = row;
  }
  return previous[y.length] * 2 * 5 >= total * 3;
}
