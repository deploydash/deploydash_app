import 'dart:convert';

/// The outcome of the most recent public-URL check for a deployed web app.
///
/// [skipped] and [unknown] are deliberately distinct: the first means the user
/// turned the check off, the second means it has not run yet. Collapsing them
/// would let "we never looked" render as "nothing to worry about."
enum AppPublicHealthStatus {
  /// The public URL answered as expected.
  healthy,

  /// The public URL answered, but not as expected -- or not at all.
  unhealthy,

  /// The check is switched off for this app, so nothing was attempted.
  skipped,

  /// No check has run yet, or the stored result could not be read.
  unknown,
}

/// The stored result of checking a deployed app's public URL.
///
/// Persisted as JSON in one local-database column, which is why [encode] and
/// [fromJson] are here rather than in a repository: the shape is written and
/// read by this class alone. Every reader is defensive by design -- a column
/// holding an older shape, truncated text, or nothing at all decodes to
/// [AppPublicHealthSnapshot.unknown] instead of throwing.
class AppPublicHealthSnapshot {
  /// Creates a snapshot of one completed (or skipped) check.
  const AppPublicHealthSnapshot({
    required this.enabled,
    required this.status,
    required this.path,
    this.httpStatus,
    this.checkedAt,
    this.error,
  });

  /// A snapshot for an app whose URL has not been checked yet.
  ///
  /// Used for a freshly deployed app and as the fallback for any payload this
  /// class cannot read.
  const AppPublicHealthSnapshot.unknown({this.enabled = true, this.path = '/'})
    : status = AppPublicHealthStatus.unknown,
      httpStatus = null,
      checkedAt = null,
      error = null;

  /// Whether the user has the public-URL check switched on for this app.
  final bool enabled;

  /// What the last check concluded.
  final AppPublicHealthStatus status;

  /// The path that was requested, always starting with `/`.
  final String path;

  /// The HTTP status the app answered with, or null when nothing answered.
  final int? httpStatus;

  /// When the check ran, or null when it has not.
  final DateTime? checkedAt;

  /// The transport-level failure text, or null when the request completed.
  final String? error;

  /// Whether the app answered as expected.
  ///
  /// False for [AppPublicHealthStatus.skipped] and
  /// [AppPublicHealthStatus.unknown] too: only a passed check is healthy.
  bool get isHealthy => status == AppPublicHealthStatus.healthy;

  /// Whether to draw the user's attention to this app.
  ///
  /// Deliberately narrower than `!isHealthy` -- a check that was skipped or
  /// has not run is not a problem to report.
  bool get needsAttention => status == AppPublicHealthStatus.unhealthy;

  /// One sentence naming the outcome, for a status row or badge tooltip.
  ///
  /// Includes the HTTP status only when there is one, so a connection failure
  /// does not read as an HTTP result.
  String get detail {
    if (status == AppPublicHealthStatus.skipped) {
      return 'Public URL check disabled';
    }
    if (status == AppPublicHealthStatus.healthy) {
      return httpStatus == null
          ? 'Public URL check passed'
          : 'Public URL check passed (HTTP $httpStatus)';
    }
    if (status == AppPublicHealthStatus.unhealthy) {
      return httpStatus == null
          ? 'Public URL check failed'
          : 'Public URL check failed (HTTP $httpStatus)';
    }
    return 'Public URL not checked';
  }

  /// This snapshot as the JSON map persisted in the local database.
  ///
  /// [checkedAt] is normalised to UTC so a snapshot written in one timezone
  /// reads back the same instant in another.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'enabled': enabled,
    'status': status.name,
    'path': path,
    'http_status': httpStatus,
    'checked_at': checkedAt?.toUtc().toIso8601String(),
    'error': error,
  };

  /// [toJson] rendered as the string stored in the database column.
  String encode() => jsonEncode(toJson());

  /// Decodes a stored column value, or [AppPublicHealthSnapshot.unknown].
  ///
  /// Null, blank, unparseable, and non-map JSON all decode to unknown rather
  /// than throwing: a snapshot is a display detail, and failing to read one
  /// must never stop an app's row from rendering.
  static AppPublicHealthSnapshot fromJson(String? value) {
    if (value == null || value.trim().isEmpty) {
      return const AppPublicHealthSnapshot.unknown();
    }
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return fromPayload(decoded);
      }
    } on FormatException {
      return const AppPublicHealthSnapshot.unknown();
    }
    return const AppPublicHealthSnapshot.unknown();
  }

  /// Reads a decoded payload, from the database or straight off the engine.
  ///
  /// Every field is coerced rather than trusted: a path that does not start
  /// with `/` becomes `/`, an unrecognised status becomes
  /// [AppPublicHealthStatus.unknown], an out-of-range HTTP status becomes
  /// null, and a blank error becomes null. A disabled check reports
  /// [AppPublicHealthStatus.skipped] whatever status the payload carries, so
  /// a stale stored result cannot outlive the setting that produced it.
  static AppPublicHealthSnapshot fromPayload(Map<dynamic, dynamic>? payload) {
    if (payload == null) {
      return const AppPublicHealthSnapshot.unknown();
    }
    final enabled = payload['enabled'] is bool
        ? payload['enabled'] as bool
        : true;
    final rawPath = payload['path']?.toString().trim() ?? '';
    final path = rawPath.startsWith('/') ? rawPath : '/';
    final status = !enabled
        ? AppPublicHealthStatus.skipped
        : switch (payload['status']?.toString().trim().toLowerCase()) {
            'healthy' => AppPublicHealthStatus.healthy,
            'unhealthy' => AppPublicHealthStatus.unhealthy,
            'skipped' => AppPublicHealthStatus.skipped,
            _ => AppPublicHealthStatus.unknown,
          };
    final httpStatus = _asHttpStatus(payload['http_status']);
    final checkedAt = DateTime.tryParse(
      payload['checked_at']?.toString() ?? '',
    );
    final rawError = payload['error']?.toString().trim();
    return AppPublicHealthSnapshot(
      enabled: enabled,
      status: status,
      path: path,
      httpStatus: httpStatus,
      checkedAt: checkedAt,
      error: rawError == null || rawError.isEmpty ? null : rawError,
    );
  }

  static int? _asHttpStatus(Object? value) {
    final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed < 100 || parsed > 599) {
      return null;
    }
    return parsed;
  }
}
