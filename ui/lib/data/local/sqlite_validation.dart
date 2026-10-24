/// Shared validators for the two SQLite repositories (D-6).
///
/// Why one file: `ProjectSqliteDatabaseRepository` and
/// `ProjectSqliteSnapshotRepository` validated the same five concepts -- a
/// required field, a SQLite name, a Docker name, a mount path, a filename --
/// under different private names with ledger-recorded semantic splits. Each
/// split travels with the caller as a parameter instead of forking the check:
/// the 64-char cap as `lengthCap`, the normalize-vs-passthrough mount-path
/// contract as `normalize`, every per-site [ArgumentError] message verbatim,
/// and the Docker-name character-class spelling unified (both spellings
/// denote the same class).
///
/// The Docker-safe token sibling lives apart: `dockerSafeToken` in
/// `project_network_trust_repository.dart` (D-17) already owns it with the
/// `maxLength` + fallback parameters, so this file does not re-own it.
library;

/// Trims [value] or throws when it is blank.
///
/// Why the shared trim-or-throw: both repositories carried this body
/// byte-identically (`_required` / `_requiredString`). The throw keeps
/// [ArgumentError.value] with the original [value] so the failure names what
/// the caller passed, not the trimmed result.
String requiredSqliteField(String value, String fieldName) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, fieldName, 'must not be empty');
  }
  return normalized;
}

/// Requires a SQLite display name: leading alphanumeric, then letters,
/// numbers, spaces, `_`, `-`, `.`.
///
/// Why [lengthCap] travels as one record: only database callers cap names at
/// 64 characters, and the cap is meaningless without its message -- the record
/// keeps the pair structural instead of two nullable parameters that could
/// arrive half-set. Snapshot callers pass no cap and keep the lenient
/// contract.
String requiredSqliteName(
  String value,
  String fieldName, {
  required String patternMessage,
  ({int max, String message})? lengthCap,
}) => _requirePattern(
  value,
  fieldName,
  RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _.-]*$'),
  patternMessage,
  lengthCap: lengthCap,
);

/// Requires a Docker-safe name: leading alphanumeric, then letters, numbers,
/// `_`, `-`, `.` (no spaces).
///
/// Why this spelling of the character class: snapshot's `A-Za-z` and the
/// database's `a-zA-Z` denote the same class; one owner keeps one spelling.
String requiredDockerName(
  String value,
  String fieldName, {
  required String patternMessage,
}) => _requirePattern(
  value,
  fieldName,
  RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$'),
  patternMessage,
);

/// Requires a mount path starting with `/` and free of `.`/`..` segments.
///
/// Why [normalize] decides the return, not just the checks: snapshot callers
/// pass `normalize: false` and get the input back verbatim (bare `/`
/// accepted); database callers pass `normalize: true` and get a rebuilt
/// `'/${segments}'` with empties dropped and bare `/` rejected via
/// [emptySegmentsMessage]. Same input can legitimately store differently per
/// caller, so the flag is required -- there is no safe default.
String requiredMountPath(
  String value,
  String fieldName, {
  required bool normalize,
  required String absoluteMessage,
  required String dotSegmentMessage,
  String? emptySegmentsMessage,
}) {
  final normalized = requiredSqliteField(value, fieldName);
  if (!normalized.startsWith('/')) {
    throw ArgumentError.value(value, fieldName, absoluteMessage);
  }
  if (!normalize) {
    if (normalized.split('/').any((part) => part == '.' || part == '..')) {
      throw ArgumentError.value(value, fieldName, dotSegmentMessage);
    }
    return normalized;
  }
  final segments = normalized.split('/');
  final cleaned = <String>[];
  for (final segment in segments) {
    final candidate = segment.trim();
    if (candidate.isEmpty) {
      continue;
    }
    if (candidate == '.' || candidate == '..') {
      throw ArgumentError.value(value, fieldName, dotSegmentMessage);
    }
    cleaned.add(candidate);
  }
  if (cleaned.isEmpty) {
    throw ArgumentError.value(value, fieldName, emptySegmentsMessage);
  }
  return '/${cleaned.join('/')}';
}

/// Requires a plain filename: leading alphanumeric, then letters, numbers,
/// `_`, `-`, `.`.
///
/// Why [slashMessage] is the whole extra check: database callers reject `/`,
/// `.`, and `..` up front with their own message (subsumed by the pattern --
/// message-only effect); snapshot callers pass nothing and let the pattern
/// message fire. A non-null message enables that exact check.
String requiredFileName(
  String value,
  String fieldName, {
  required String patternMessage,
  String? slashMessage,
}) => _requirePattern(
  value,
  fieldName,
  RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$'),
  patternMessage,
  slashMessage: slashMessage,
);

/// The single trim-then-cap-then-slash-then-pattern engine behind the name,
/// Docker-name, and filename owners.
///
/// Why one engine with nullable splits instead of three lookalikes: the three
/// checks share the trim/throw skeleton and differ only in which extra gates
/// fire. Each gate is null-off, so every branch is reachable from some
/// caller and no caller pays for another's gate.
String _requirePattern(
  String value,
  String fieldName,
  RegExp pattern,
  String patternMessage, {
  ({int max, String message})? lengthCap,
  String? slashMessage,
}) {
  final normalized = requiredSqliteField(value, fieldName);
  if (lengthCap != null && normalized.length > lengthCap.max) {
    throw ArgumentError.value(value, fieldName, lengthCap.message);
  }
  if (slashMessage != null &&
      (normalized.contains('/') || normalized == '.' || normalized == '..')) {
    throw ArgumentError.value(value, fieldName, slashMessage);
  }
  if (!pattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, fieldName, patternMessage);
  }
  return normalized;
}
