import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';
import '../../models/app_user_attribute.dart';

/// Agent Access may inspect, and nothing else. The default.
const String agentAccessPermissionReadOnly = 'read_only';

/// Agent Access may also redeploy an existing web app.
const String agentAccessPermissionRedeploy = 'redeploy';

/// The stored permission mode for [mode], defaulting to read-only.
///
/// Fails closed: anything unrecognised -- an older spelling, a corrupted row,
/// a value from a newer build -- becomes [agentAccessPermissionReadOnly]. The
/// alternative would be granting an external agent redeploy rights on the
/// strength of a value nothing understood.
String normalizeAgentAccessPermissionMode(String mode) {
  final normalized = mode.trim().toLowerCase();
  return switch (normalized) {
    agentAccessPermissionRedeploy => agentAccessPermissionRedeploy,
    _ => agentAccessPermissionReadOnly,
  };
}

/// The app's single settings row.
///
/// One row, not a key-value store: the settings are few and known, and a typed
/// record means a misspelled key is a compile error rather than a silently
/// missing preference.
class AppPreferencesRecord {
  /// Records the current preferences.
  const AppPreferencesRecord({
    required this.terminalDebugView,
    required this.themeMode,
    this.gitHubPendingOauthState,
    required this.sqliteBackupS3Config,
    this.sqliteBackupLastRunAt,
    this.sqliteBackupLastStatus,
    this.sqliteBackupLastMessage,
    required this.agentAccessEnabled,
    required this.agentAccessPermissionMode,
    this.agentSessionToken,
    this.agentSessionExpiresAt,
    this.analyticsOnboardingCompletedAt,
    this.analyticsFirstDeploySucceededAt,
    this.analyticsGitHubConnectedAt,
    this.telemetryEnabled,
    this.telemetryNoticeShownAt,
    this.telemetryNagShownAt,
    required this.updatedAt,
  });

  /// Whether the terminal shows raw engine detail rather than the calm view.
  final bool terminalDebugView;

  /// `light`, `dark`, or `system`.
  final String themeMode;

  /// The OAuth `state` for a GitHub sign-in that is still in the browser.
  ///
  /// Persisted rather than held in memory so a cold-launch callback -- the app
  /// was closed while the user authorised -- can still be matched. An
  /// unmatched callback is refused, which is what makes it a CSRF defence
  /// rather than a convenience.
  final String? gitHubPendingOauthState;

  /// Where the encrypted database is backed up to, decoded, or null when not
  /// configured.
  final Map<String, dynamic>? sqliteBackupS3Config;

  /// When the last local-database backup ran.
  final DateTime? sqliteBackupLastRunAt;

  /// How it ended, lower-cased. `unknown` when the caller did not say.
  final String? sqliteBackupLastStatus;

  /// What it reported, including any note about retention pruning.
  final String? sqliteBackupLastMessage;

  /// Whether the local MCP endpoint is bound.
  final bool agentAccessEnabled;

  /// What an agent is permitted to do. See
  /// [normalizeAgentAccessPermissionMode].
  final String agentAccessPermissionMode;

  /// The current agent session token, when one has been issued.
  ///
  /// One at a time, short-lived. Stored so the endpoint can validate a request
  /// without keeping session state that a restart would lose.
  final String? agentSessionToken;

  /// When that token stops being accepted.
  final DateTime? agentSessionExpiresAt;

  /// When server onboarding first completed, or null before it has.
  final DateTime? analyticsOnboardingCompletedAt;

  /// When the first deploy first succeeded, or null before it has.
  final DateTime? analyticsFirstDeploySucceededAt;

  /// When GitHub first connected, or null before it has.
  final DateTime? analyticsGitHubConnectedAt;

  /// Whether anonymous usage reporting is on, off, or never answered
  /// (null). Null reads as on: telemetry is default-on behind a notice, and
  /// only an explicit `false` silences the backends.
  final bool? telemetryEnabled;

  /// When the setup-progress telemetry notice was shown, or null before it
  /// has. Stamped at setup completion, at most once.
  final DateTime? telemetryNoticeShownAt;

  /// When the post-first-deploy telemetry nag was shown, or null before it
  /// has. At most once, and only for explicitly opted-out installs.
  final DateTime? telemetryNagShownAt;

  /// When these preferences last changed.
  final DateTime updatedAt;

  /// Whether an unexpired agent session exists right now.
  ///
  /// Expiry is checked here rather than at issue time, so a session left open
  /// while the app was closed is not honoured on the strength of having once
  /// been valid.
  bool get hasActiveAgentSession {
    final token = agentSessionToken?.trim();
    final expiresAt = agentSessionExpiresAt;
    if (token == null || token.isEmpty || expiresAt == null) {
      return false;
    }
    return expiresAt.isAfter(DateTime.now());
  }
}

/// Reads and writes the single preferences row.
///
/// Every write is an upsert on row id 1, so a preference can be set before the
/// row exists and no caller has to check first.
class AppPreferencesRepository {
  /// Creates the repository over the app database.
  const AppPreferencesRepository(this._database);

  final AppDatabase _database;

  /// The current preferences, creating the row with defaults on first read.
  ///
  /// Values are normalized on the way out as well as in: a blank theme reads
  /// as `system`, and an unreadable backup configuration reads as null rather
  /// than throwing -- a corrupt settings row must not stop the app opening.
  Future<AppPreferencesRecord> read() async {
    final row =
        await (_database.select(_database.appPreferences)
              ..where((table) => table.id.equals(1))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      final now = DateTime.now();
      await _database
          .into(_database.appPreferences)
          .insert(
            AppPreferencesCompanion.insert(
              id: const Value(1),
              terminalDebugView: const Value(false),
              themeMode: const Value('system'),
              updatedAt: Value(now),
            ),
          );
      return AppPreferencesRecord(
        terminalDebugView: false,
        themeMode: 'system',
        gitHubPendingOauthState: null,
        sqliteBackupS3Config: null,
        sqliteBackupLastRunAt: null,
        sqliteBackupLastStatus: null,
        sqliteBackupLastMessage: null,
        agentAccessEnabled: false,
        agentAccessPermissionMode: agentAccessPermissionReadOnly,
        agentSessionToken: null,
        agentSessionExpiresAt: null,
        analyticsOnboardingCompletedAt: null,
        analyticsFirstDeploySucceededAt: null,
        analyticsGitHubConnectedAt: null,
        telemetryEnabled: null,
        telemetryNoticeShownAt: null,
        telemetryNagShownAt: null,
        updatedAt: now,
      );
    }
    return AppPreferencesRecord(
      terminalDebugView: row.terminalDebugView,
      themeMode: row.themeMode.trim().isEmpty ? 'system' : row.themeMode,
      gitHubPendingOauthState: row.gitHubPendingOauthState?.trim(),
      sqliteBackupS3Config: _decodeJsonMap(row.sqliteBackupS3ConfigJson),
      sqliteBackupLastRunAt: row.sqliteBackupLastRunAt,
      sqliteBackupLastStatus: row.sqliteBackupLastStatus,
      sqliteBackupLastMessage: row.sqliteBackupLastMessage,
      agentAccessEnabled: row.agentAccessEnabled,
      agentAccessPermissionMode: normalizeAgentAccessPermissionMode(
        row.agentAccessPermissionMode,
      ),
      agentSessionToken: row.agentSessionToken?.trim(),
      agentSessionExpiresAt: row.agentSessionExpiresAt,
      analyticsOnboardingCompletedAt: row.analyticsOnboardingCompletedAt,
      analyticsFirstDeploySucceededAt: row.analyticsFirstDeploySucceededAt,
      analyticsGitHubConnectedAt: row.analyticsGitHubConnectedAt,
      telemetryEnabled: row.telemetryEnabled,
      telemetryNoticeShownAt: row.telemetryNoticeShownAt,
      telemetryNagShownAt: row.telemetryNagShownAt,
      updatedAt: row.updatedAt,
    );
  }

  /// Single owner for preference writes: every setter normalizes its value
  /// first where needed, then funnels the row upsert through here, so the
  /// insert shape cannot drift into per-setter copies.
  Future<void> _writePreferences(AppPreferencesCompanion companion) {
    return _database
        .into(_database.appPreferences)
        .insertOnConflictUpdate(companion);
  }

  /// Sets whether the terminal shows raw engine detail.
  Future<void> setTerminalDebugView(bool enabled) async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        terminalDebugView: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Sets the theme, storing anything unrecognised as `system`.
  Future<void> setThemeMode(String mode) async {
    final normalizedMode = mode.trim().toLowerCase();
    final storedMode = switch (normalizedMode) {
      'light' => 'light',
      'dark' => 'dark',
      _ => 'system',
    };
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        themeMode: Value(storedMode),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stores the pending OAuth `state`, or clears it when null or blank.
  ///
  /// Cleared once a callback is matched, so the same state cannot be replayed.
  Future<void> setGitHubPendingOauthState(String? oauthState) async {
    final normalized = oauthState?.trim();
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        gitHubPendingOauthState: Value(
          normalized == null || normalized.isEmpty ? null : normalized,
        ),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Stores the local-database backup destination, or clears it when null.
  Future<void> setSqliteBackupS3Config(Map<String, dynamic>? config) async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        sqliteBackupS3ConfigJson: Value(
          config == null ? null : jsonEncode(config),
        ),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Records the outcome of a local-database backup, successful or not.
  Future<void> recordSqliteBackupRun({
    required String status,
    String? message,
    DateTime? runAt,
  }) async {
    final normalizedStatus = status.trim().isEmpty
        ? 'unknown'
        : status.trim().toLowerCase();
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        sqliteBackupLastRunAt: Value(runAt ?? DateTime.now()),
        sqliteBackupLastStatus: Value(normalizedStatus),
        sqliteBackupLastMessage: Value(message?.trim()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Records when a first-reached milestone was reached. Write-once: a second
  /// call keeps the first-reached timestamp, so the milestone answers "when
  /// did this install activate" rather than "when did it last repeat".
  ///
  /// One method for all three milestones rather than one writer per column:
  /// the read-check-write shape is the concept and the milestone is the
  /// parameter. Value buckets return early (recomputed, never stored). The
  /// exhaustive switches (no default) fail compilation when a new attribute
  /// value arrives without its storage decision.
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {
    if (attribute == AppUserAttribute.serverCountBucket ||
        attribute == AppUserAttribute.projectCountBucket ||
        attribute == AppUserAttribute.deploysPerWeekBucket) {
      // Value buckets are recomputed from live counts on every lifecycle
      // event and never persisted: recording one is a no-op. Stated
      // explicitly so a future attribute value still fails compilation in
      // the exhaustive switches below until its storage is decided.
      return;
    }
    final record = await read();
    final alreadyReached = switch (attribute) {
      AppUserAttribute.hasCompletedOnboarding =>
        record.analyticsOnboardingCompletedAt != null,
      AppUserAttribute.hasFirstDeploySucceeded =>
        record.analyticsFirstDeploySucceededAt != null,
      AppUserAttribute.hasConnectedGitHub =>
        record.analyticsGitHubConnectedAt != null,
      // Unreachable: buckets return early above with the same silent
      // outcome. Present only so the switch stays exhaustive and a future
      // value fails compilation until its storage is decided.
      AppUserAttribute.serverCountBucket ||
      AppUserAttribute.projectCountBucket ||
      AppUserAttribute.deploysPerWeekBucket => true,
    };
    if (alreadyReached) {
      return;
    }
    final timestamp = Value(reachedAt ?? DateTime.now());
    final companion = switch (attribute) {
      AppUserAttribute.hasCompletedOnboarding => AppPreferencesCompanion(
        id: const Value(1),
        analyticsOnboardingCompletedAt: timestamp,
        updatedAt: Value(DateTime.now()),
      ),
      AppUserAttribute.hasFirstDeploySucceeded => AppPreferencesCompanion(
        id: const Value(1),
        analyticsFirstDeploySucceededAt: timestamp,
        updatedAt: Value(DateTime.now()),
      ),
      AppUserAttribute.hasConnectedGitHub => AppPreferencesCompanion(
        id: const Value(1),
        analyticsGitHubConnectedAt: timestamp,
        updatedAt: Value(DateTime.now()),
      ),
      // Unreachable: buckets return early above before any write. Present
      // only so the switch stays exhaustive and a future value fails
      // compilation until its storage is decided.
      AppUserAttribute.serverCountBucket ||
      AppUserAttribute.projectCountBucket ||
      AppUserAttribute.deploysPerWeekBucket => AppPreferencesCompanion(
        id: const Value(1),
        updatedAt: Value(DateTime.now()),
      ),
    };
    await _writePreferences(companion);
  }

  /// Records the usage-reporting switch. Overwritable: a later answer
  /// replaces the earlier one, so the setup notice and Settings can always
  /// flip it either way.
  Future<void> setTelemetryEnabled({required bool enabled}) async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        telemetryEnabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Records that the setup-progress telemetry notice was shown. Write-once:
  /// a second call keeps the first-shown timestamp, so the notice moment is
  /// recorded at most once no matter how often setup progress rebuilds.
  Future<void> markTelemetryNoticeShown() async {
    final record = await read();
    if (record.telemetryNoticeShownAt != null) {
      return;
    }
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        telemetryNoticeShownAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Records that the post-first-deploy telemetry nag was shown. Write-once:
  /// a second call keeps the first-shown timestamp, so an opted-out install
  /// is nagged at most once no matter how often Home rebuilds.
  Future<void> markTelemetryNagShown() async {
    final record = await read();
    if (record.telemetryNagShownAt != null) {
      return;
    }
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        telemetryNagShownAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Turns the local MCP endpoint on or off.
  Future<void> setAgentAccessEnabled(bool enabled) async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        agentAccessEnabled: Value(enabled),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Sets what an agent may do, normalized to a known mode.
  Future<void> setAgentAccessPermissionMode(String mode) async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        agentAccessPermissionMode: Value(
          normalizeAgentAccessPermissionMode(mode),
        ),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Records a newly issued agent session, replacing any previous one.
  ///
  /// A blank token clears the session rather than storing an empty one, so a
  /// failed issue cannot leave something that reads as a live session.
  Future<void> issueAgentSession({
    required String token,
    required DateTime expiresAt,
  }) async {
    final normalizedToken = token.trim();
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        agentSessionToken: Value(
          normalizedToken.isEmpty ? null : normalizedToken,
        ),
        agentSessionExpiresAt: Value(
          normalizedToken.isEmpty ? null : expiresAt,
        ),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Ends the current agent session immediately.
  Future<void> clearAgentSession() async {
    await _writePreferences(
      AppPreferencesCompanion(
        id: const Value(1),
        agentSessionToken: const Value(null),
        agentSessionExpiresAt: const Value(null),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // D-58 (T-014): left — null-on-blank/unparseable with try/catch; the
  // four _decodeJsonMap defs differ in nullability + exception behavior.
  Map<String, dynamic>? _decodeJsonMap(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
  }
}

/// The app-wide preferences repository.
final appPreferencesRepositoryProvider = Provider<AppPreferencesRepository>((
  ref,
) {
  final database = ref.watch(appDatabaseProvider);
  return AppPreferencesRepository(database);
});
