/// Renders [value] safe for container and database identifiers.
///
/// The single owner of the dot/underscore-preserving scrub (D-16): the
/// release repository and the managed-database repository carried
/// byte-identical copies under the same private name. Dots and underscores
/// survive on purpose -- these tokens name containers and database objects,
/// not URL slugs (compare `slugifyProjectName`, which strips them, and the
/// D-17/D-6 `dockerSafeToken` family, which caps length and falls back to
/// `'group'`/`'sqlite'`). A value that scrubs away entirely becomes
/// `'item'`, and there is no length cap.
///
/// (D-26 slug census, T-011: both former sites recorded here as left unique
/// for container/db identifiers rather than folded into URL slugs.)
String safeToken(String value) {
  final normalized = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '-')
      .replaceAll(RegExp(r'^[-_.]+|[-_.]+$'), '');
  return normalized.isEmpty ? 'item' : normalized;
}
