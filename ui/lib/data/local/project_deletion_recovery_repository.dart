import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// How one step of a project deletion ended.
enum ProjectDeletionStepStatus {
  /// Not attempted yet, or attempted and not yet finished.
  pending,

  /// Done. Skipped on a retry -- several of these steps are not safely
  /// repeatable.
  success,

  /// Attempted and failed. The retry will try it again.
  failed,
}

/// One step of a project's server-side cleanup, and how it went.
class ProjectDeletionStepState {
  /// Records one step.
  const ProjectDeletionStepState({
    required this.id,
    required this.label,
    required this.status,
    this.message,
  });

  /// Stable id, e.g. `postgres_project` or `backup_policy:<id>`. What a retry
  /// matches on to know a step is already done.
  final String id;

  /// What to show the user, e.g. `Delete project databases and users`.
  final String label;

  /// How it ended.
  final ProjectDeletionStepStatus status;

  /// Why it failed, already sanitized for display.
  final String? message;

  /// A copy with a new status and message.
  ///
  /// [message] is *not* null-means-keep: passing null clears it, which is what
  /// a step being retried needs.
  ProjectDeletionStepState copyWith({
    ProjectDeletionStepStatus? status,
    String? message,
  }) {
    return ProjectDeletionStepState(
      id: id,
      label: label,
      status: status ?? this.status,
      message: message,
    );
  }

  /// This step as the JSON stored in the recovery row.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'status': status.name,
    if (message != null) 'message': message,
  };

  /// Reads one stored step, or null when it has no id or label.
  ///
  /// Null rather than a placeholder: a step that cannot be identified cannot
  /// be matched on a retry, so keeping it would mean re-running work that may
  /// already be done.
  static ProjectDeletionStepState? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final id = value['id']?.toString().trim() ?? '';
    final label = value['label']?.toString().trim() ?? '';
    if (id.isEmpty || label.isEmpty) {
      return null;
    }
    final status = switch (value['status']?.toString()) {
      'success' => ProjectDeletionStepStatus.success,
      'failed' => ProjectDeletionStepStatus.failed,
      _ => ProjectDeletionStepStatus.pending,
    };
    final message = trimOrNull(value['message']?.toString());
    return ProjectDeletionStepState(
      id: id,
      label: label,
      status: status,
      message: message,
    );
  }
}

/// A project whose deletion has started but not finished.
///
/// The row exists from the moment deletion begins until the server-side work
/// completes, which is what makes an interrupted deletion resumable rather
/// than lost. While it exists, the project is hidden from every ordinary read.
class ProjectDeletionRecoveryRecord {
  /// Records one in-progress deletion.
  const ProjectDeletionRecoveryRecord({
    required this.projectId,
    this.serverId,
    required this.projectName,
    required this.projectSlug,
    required this.status,
    required this.steps,
    this.lastError,
    required this.attemptCount,
    required this.requestedAt,
    this.lastAttemptAt,
    required this.updatedAt,
  });

  /// The project being deleted.
  final String projectId;

  /// Its server, when it had one.
  final String? serverId;

  /// Its name, copied here so the retry screen can still name it after the
  /// project row is gone.
  final String projectName;

  /// Its slug, copied for the same reason: the engine addresses resources by
  /// slug, and a retry needs it after the project row no longer exists.
  final String projectSlug;

  /// `pending_remote` while cleanup can still proceed, `cleanup_failed` once a
  /// step has failed and the user has to decide.
  final String status;

  /// Each step and how it ended. The list a retry works from.
  final List<ProjectDeletionStepState> steps;

  /// The most recent failure message.
  final String? lastError;

  /// How many times cleanup has been attempted.
  final int attemptCount;

  /// When the user asked for the deletion.
  final DateTime requestedAt;

  /// When cleanup was last attempted.
  final DateTime? lastAttemptAt;

  /// When this record last changed.
  final DateTime updatedAt;

  /// Whether the user has to decide what to do about this deletion.
  bool get needsAttention => status == 'cleanup_failed';
}

/// Stores the state of deletions that have not finished.
///
/// The record is what survives a crash or a quit mid-deletion. It is created
/// before any remote work starts and removed only once cleanup completes, so
/// the failure mode is a deletion that resumes -- never one that is silently
/// abandoned with resources still running on a customer's paid server.
class ProjectDeletionRecoveryRepository {
  /// Creates the repository over the app database.
  ProjectDeletionRecoveryRepository(this._database);

  final AppDatabase _database;

  /// Streams unfinished deletions, oldest request first.
  Stream<List<ProjectDeletionRecoveryRecord>> watchRecoveries() {
    final query = _database.select(_database.projectDeletionRecoveryStates)
      ..orderBy([(table) => OrderingTerm.asc(table.requestedAt)]);
    return query.watch().map(
      (rows) => rows.map(_fromRow).toList(growable: false),
    );
  }

  /// Unfinished deletions, oldest request first.
  Future<List<ProjectDeletionRecoveryRecord>> listRecoveries() async {
    final rows = await (_database.select(
      _database.projectDeletionRecoveryStates,
    )..orderBy([(table) => OrderingTerm.asc(table.requestedAt)])).get();
    return rows.map(_fromRow).toList(growable: false);
  }

  /// One project's recovery record, or null when it is not being deleted.
  Future<ProjectDeletionRecoveryRecord?> getRecovery(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return null;
    }
    final row =
        await (_database.select(_database.projectDeletionRecoveryStates)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _fromRow(row);
  }

  /// Opens a recovery record before any remote work begins.
  ///
  /// Re-entrant: starting a deletion that already has a record preserves its
  /// steps, attempt count and original request time, so retrying from the top
  /// does not discard what already succeeded.
  ///
  /// Throws [ArgumentError] without a project id and name -- a record that
  /// cannot name what it is deleting cannot be acted on later.
  Future<ProjectDeletionRecoveryRecord> startRecovery({
    required String projectId,
    required String? serverId,
    required String projectName,
    required String projectSlug,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedProjectName = projectName.trim();
    if (normalizedProjectId.isEmpty || normalizedProjectName.isEmpty) {
      throw ArgumentError('projectId and projectName are required.');
    }
    final existing = await getRecovery(normalizedProjectId);
    final now = DateTime.now();
    await _database
        .into(_database.projectDeletionRecoveryStates)
        .insertOnConflictUpdate(
          ProjectDeletionRecoveryStatesCompanion.insert(
            projectId: normalizedProjectId,
            serverId: Value(trimOrNull(serverId)),
            projectName: normalizedProjectName,
            projectSlug: _normalizedSlug(projectSlug, normalizedProjectName),
            status: const Value('pending_remote'),
            stepStatesJson: Value(_encodeSteps(existing?.steps ?? const [])),
            lastError: const Value(null),
            attemptCount: Value(existing?.attemptCount ?? 0),
            requestedAt: existing?.requestedAt ?? now,
            lastAttemptAt: Value(existing?.lastAttemptAt),
            updatedAt: Value(now),
          ),
        );
    // Kept: the row was upserted two statements above, and `getRecovery`
    // cannot express "present because this method just wrote it".
    return (await getRecovery(normalizedProjectId))!;
  }

  /// Marks a new attempt starting, clearing the previous error.
  ///
  /// Throws [StateError] when there is no record: attempting cleanup for a
  /// project that was never marked for deletion would leave nothing to resume
  /// from if it were interrupted.
  Future<ProjectDeletionRecoveryRecord> beginAttempt(String projectId) async {
    final existing = await getRecovery(projectId);
    if (existing == null) {
      throw StateError('Project deletion recovery record was not found.');
    }
    final now = DateTime.now();
    await (_database.update(
      _database.projectDeletionRecoveryStates,
    )..where((table) => table.projectId.equals(existing.projectId))).write(
      ProjectDeletionRecoveryStatesCompanion(
        status: const Value('pending_remote'),
        lastError: const Value(null),
        attemptCount: Value(existing.attemptCount + 1),
        lastAttemptAt: Value(now),
        updatedAt: Value(now),
      ),
    );
    // Kept, for the same reason as `markPendingRemote` above: the row was
    // written by the update immediately preceding this read.
    return (await getRecovery(existing.projectId))!;
  }

  /// Stores step progress after each step, and whether cleanup has failed.
  ///
  /// Written as the run goes, not at the end -- that is what makes an
  /// interruption resumable at the step it reached.
  Future<void> saveProgress({
    required String projectId,
    required List<ProjectDeletionStepState> steps,
    required bool failed,
    String? lastError,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    await (_database.update(
      _database.projectDeletionRecoveryStates,
    )..where((table) => table.projectId.equals(normalizedProjectId))).write(
      ProjectDeletionRecoveryStatesCompanion(
        status: Value(failed ? 'cleanup_failed' : 'pending_remote'),
        stepStatesJson: Value(_encodeSteps(steps)),
        lastError: Value(trimOrNull(lastError)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  /// Removes the record, ending the deletion.
  ///
  /// Only once every step has succeeded, or the user has explicitly chosen to
  /// drop the local record and accept that remote resources may remain.
  Future<void> removeRecovery(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    await (_database.delete(
      _database.projectDeletionRecoveryStates,
    )..where((table) => table.projectId.equals(normalizedProjectId))).go();
  }

  ProjectDeletionRecoveryRecord _fromRow(ProjectDeletionRecoveryStateRow row) {
    return ProjectDeletionRecoveryRecord(
      projectId: row.projectId,
      serverId: trimOrNull(row.serverId),
      projectName: row.projectName,
      projectSlug: row.projectSlug,
      status: row.status,
      steps: _decodeSteps(row.stepStatesJson),
      lastError: trimOrNull(row.lastError),
      attemptCount: row.attemptCount,
      requestedAt: row.requestedAt,
      lastAttemptAt: row.lastAttemptAt,
      updatedAt: row.updatedAt,
    );
  }

  static String _encodeSteps(List<ProjectDeletionStepState> steps) {
    return jsonEncode(steps.map((step) => step.toJson()).toList());
  }

  static List<ProjectDeletionStepState> _decodeSteps(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .map(ProjectDeletionStepState.fromJson)
          .whereType<ProjectDeletionStepState>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  // D-26 slug census (T-011): left unique — already takes fallback as a
  // parameter AND slugifies the fallback itself; never fold into the owner.
  static String _normalizedSlug(String value, String fallback) {
    final slug = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (slug.isNotEmpty) {
      return slug;
    }
    final fallbackSlug = fallback
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return fallbackSlug.isEmpty ? 'project-app' : fallbackSlug;
  }
}

/// The app-wide deletion recovery repository.
final projectDeletionRecoveryRepositoryProvider =
    Provider<ProjectDeletionRecoveryRepository>((ref) {
      return ProjectDeletionRecoveryRepository(ref.watch(appDatabaseProvider));
    });

/// Unfinished deletions, for the Home warning card and the retry flow.
final projectDeletionRecoveriesProvider =
    FutureProvider<List<ProjectDeletionRecoveryRecord>>((ref) {
      return ref
          .watch(projectDeletionRecoveryRepositoryProvider)
          .listRecoveries();
    });
