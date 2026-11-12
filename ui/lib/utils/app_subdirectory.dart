/// Normalizes an app subdirectory to its canonical `a/b/c` form.
///
/// One owner (D-26 family B): six validators — the github provider, the
/// project provider, the project repository, the workers tab, and the two
/// app-deployment subdirectory readers — shared this identical
/// trim/backslash/edge-slash/segment shape and differed only in what an
/// invalid segment becomes. [invalidValue] is that verdict: the deploy
/// flow distinguishes invalid from absent, so the github provider and the
/// deployment dialogs pass their `__invalid__` sentinel while the
/// repository, project provider, and workers tab keep `null`.
String? normalizeAppSubdirectory(String? raw, {String? invalidValue}) {
  if (raw == null) {
    return null;
  }
  final normalized = raw
      .trim()
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'^/+|/+$'), '');
  if (normalized.isEmpty) {
    return null;
  }
  final segments = normalized.split('/');
  final cleaned = <String>[];
  for (final segment in segments) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
      return invalidValue;
    }
    cleaned.add(trimmed);
  }
  if (cleaned.isEmpty) {
    return null;
  }
  return cleaned.join('/');
}
