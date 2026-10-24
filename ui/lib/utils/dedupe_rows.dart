/// Deduplicates rows by key, last value winning at its first position.
///
/// Why one owner: the worker list, the env-var list, and the env-editor
/// dialog each carried the same insertion-ordered-map loop -- skip blanks,
/// last duplicate wins, first-appearance order -- differing only in what
/// counts as a key and how a kept row is rebuilt (D-18/D-42). The loop is
/// the part that must not drift (a key kept at the wrong slot silently
/// reorders a saved list), so it lives here once, with the per-side key
/// extraction ([keyOf]), row rebuild ([rebuild]), and extra skip rule
/// ([keep]) travelling with the caller.
///
/// Contract: rows are visited in order; a row is dropped when [keep] says
/// no or [keyOf] returns null; otherwise [rebuild] builds the stored row
/// and it is filed under its key. A reassigned key keeps its first slot
/// (a Dart map literal is insertion-ordered), so the result is
/// first-appearance order with last values winning.
List<R> dedupeRowsByKey<R>({
  required List<R> rows,
  required String? Function(R row) keyOf,
  required R Function(R row, String key) rebuild,
  bool Function(R row)? keep,
}) {
  // Insertion-ordered by construction: a Dart map literal is a
  // LinkedHashMap, and re-assigning an existing key updates it in place
  // without moving it. So `deduped.values` is already first-seen order.
  final deduped = <String, R>{};
  for (final row in rows) {
    if (keep != null && !keep(row)) {
      continue;
    }
    final key = keyOf(row);
    if (key == null) {
      continue;
    }
    deduped[key] = rebuild(row, key);
  }
  return deduped.values.toList(growable: false);
}
