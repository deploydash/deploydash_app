/// Returns [value] trimmed, or `null` when it is absent or blank.
///
/// The single owner of "a blank string means absent" for the desktop app.
/// Fifteen private copies of this in eleven spellings preceded it (T-3.8.3),
/// which is why it is a top-level function in `utils/` rather than a static
/// on whichever class happened to need it first: a helper that can only be
/// reached through one class is a helper the next class will rewrite.
///
/// Blank means absent throughout the local database layer, so a column
/// holding `'   '` reads back as `null` rather than as whitespace.
String? trimOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
