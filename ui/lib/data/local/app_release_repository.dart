import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/safe_token.dart';
import '../../utils/sensitive_data_sanitizer.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// One versioned release of a project's web app on a server.
///
/// Deploys are versioned rather than in-place: a candidate is built, probed,
/// and only then made live, and previous releases are retained so a rollback
/// is a traffic switch rather than a rebuild. These rows are the local mirror
/// of what the server holds.
class AppReleaseRecord {
  /// Records one release.
  const AppReleaseRecord({
    required this.id,
    required this.projectId,
    required this.serverId,
    required this.releaseId,
    required this.status,
    this.deploymentKind = 'deploy',
    this.branch = 'main',
    this.commitSha,
    this.imageName,
    this.webContainerName,
    this.appPort,
    this.createdAtRemote,
    this.liveAt,
    this.rollbackFromReleaseId,
    this.rollbackReason,
    this.runtimeEnvJson,
    this.workersJson,
    this.lastObservedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Derived from the server, project and release id, so re-observing the same
  /// release updates one row rather than adding another.
  final String id;

  /// Which project this release is of.
  final String projectId;

  /// Which server it lives on.
  final String serverId;

  /// The server's own id for the release.
  final String releaseId;

  /// `live`, `candidate`, `retained`, or `failed`. Anything unrecognised
  /// becomes `retained` -- the status that claims least.
  final String status;

  /// `deploy`, or a rollback.
  final String deploymentKind;

  /// The branch deployed. `main` when unstated.
  final String branch;

  /// The commit deployed.
  final String? commitSha;

  /// The image built for it.
  final String? imageName;

  /// The container running it.
  final String? webContainerName;

  /// The port the app listens on inside that container.
  final int? appPort;

  /// When the server created it.
  final DateTime? createdAtRemote;

  /// When it took live traffic, or null if it never did.
  final DateTime? liveAt;

  /// For a rollback, the release that was live before it.
  final String? rollbackFromReleaseId;

  /// Why the rollback happened -- typically a failed health gate.
  final String? rollbackReason;

  /// The runtime environment as JSON, as the server reported it.
  final String? runtimeEnvJson;

  /// The workers bound to this release, as JSON.
  final String? workersJson;

  /// When the server last confirmed this release still exists.
  final DateTime? lastObservedAt;

  /// When the row was first written.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;

  /// Whether this release is the one serving traffic.
  bool get isLive => status == 'live';
}

/// The last observed runtime state of a project's app on a server.
///
/// One row per project and server, overwritten rather than appended: this is
/// the current picture, not a history.
class AppRuntimeSnapshotRecord {
  /// Records one runtime observation.
  const AppRuntimeSnapshotRecord({
    required this.projectId,
    required this.serverId,
    this.resourceUsageJson,
    this.healthStatus,
    this.publicHealthJson,
    this.healthCheckedAt,
    this.resourceCheckedAt,
    required this.updatedAt,
  });

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// CPU, memory and disk as JSON.
  final String? resourceUsageJson;

  /// The container's effective status, as one word.
  final String? healthStatus;

  /// The public-URL check result as JSON, decoded by
  /// `AppPublicHealthSnapshot`.
  final String? publicHealthJson;

  /// When health was last checked.
  final DateTime? healthCheckedAt;

  /// When resource usage was last read. Separate from [healthCheckedAt]
  /// because the two are polled independently -- resource usage is expensive
  /// and health is not.
  final DateTime? resourceCheckedAt;

  /// When this row last changed.
  final DateTime updatedAt;
}

/// The last observed state of a project's workers on a server.
class WorkerRuntimeSnapshotRecord {
  /// Records one worker observation.
  const WorkerRuntimeSnapshotRecord({
    required this.projectId,
    required this.serverId,
    required this.snapshotJson,
    this.lastCheckedAt,
    required this.updatedAt,
  });

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// The whole worker status payload as JSON. Stored opaquely, because the
  /// shape belongs to the workers workflow rather than to this table.
  final String snapshotJson;

  /// When the workers were last inspected.
  final DateTime? lastCheckedAt;

  /// When this row last changed.
  final DateTime updatedAt;
}

/// How far the first import of a project's existing server state has got.
///
/// A project added for a server that already has resources has to discover
/// them once. This row is what stops that rerunning on every open, and what
/// lets a failed import be reported rather than silently retried forever.
class ProjectWorkspaceImportStateRecord {
  /// Records one import's state.
  const ProjectWorkspaceImportStateRecord({
    required this.projectId,
    required this.serverId,
    required this.status,
    this.startedAt,
    this.finishedAt,
    this.errorMessage,
    required this.updatedAt,
  });

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// `pending`, `importing`, `imported`, `failed`, or `skipped`. Anything
  /// unrecognised becomes `pending`, so an unreadable status means the import
  /// is retried rather than assumed done.
  final String status;

  /// When the import began.
  final DateTime? startedAt;

  /// When it ended.
  final DateTime? finishedAt;

  /// Why it failed.
  final String? errorMessage;

  /// When this row last changed.
  final DateTime updatedAt;
}

/// One managed operation, recorded before it runs and updated after.
///
/// The journal exists so an operation that succeeded remotely while the app
/// was closing is not lost: on next launch, `remote_success` entries are
/// replayed into the local mirror, and `failed` ones are surfaced. Without it,
/// the app's picture of a customer's server would silently drift from reality
/// every time a deploy outlived the window it was started from.
class ProjectManagedOperationJournalRecord {
  /// Records one journalled operation.
  const ProjectManagedOperationJournalRecord({
    required this.id,
    required this.projectId,
    required this.serverId,
    required this.surface,
    required this.operationType,
    required this.status,
    this.requestJson,
    this.resultJson,
    this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
  });

  /// The entry's id, generated from the time, surface and operation.
  final String id;

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// Which part of the app started it.
  final String surface;

  /// Which operation was run.
  final String operationType;

  /// `pending_remote`, `remote_success`, or `failed`.
  final String status;

  /// The request as JSON, **with sensitive fields redacted**.
  ///
  /// Journal entries outlive the operation and are read back on a later
  /// launch, so a credential written here would be a credential kept
  /// indefinitely for no reason.
  final String? requestJson;

  /// The result as JSON, redacted the same way unless the caller opted out
  /// because the payload is needed intact to update the mirror.
  final String? resultJson;

  /// Why it failed.
  final String? errorMessage;

  /// When the entry was created, which is before the operation ran.
  final DateTime createdAt;

  /// When it last changed.
  final DateTime updatedAt;
}

/// Mirrors a project's releases and runtime state, and journals the
/// operations that change them.
///
/// Scoped by project and server together throughout: a project can move
/// between servers, and one server's releases must never be shown as another's.
class AppReleaseRepository {
  /// Creates the repository over the app database.
  const AppReleaseRepository(this._database);

  final AppDatabase _database;

  /// A project's releases on one server, most recently live first.
  Future<List<AppReleaseRecord>> listReleasesForScope({
    required String projectId,
    required String serverId,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    if (scope == null) {
      return const [];
    }
    final rows =
        await (_database.select(_database.appReleases)
              ..where(
                (table) =>
                    table.projectId.equals(scope.projectId) &
                    table.serverId.equals(scope.serverId),
              )
              ..orderBy([
                (table) => OrderingTerm.desc(table.liveAt),
                (table) => OrderingTerm.desc(table.createdAtRemote),
                (table) => OrderingTerm.desc(table.updatedAt),
              ]))
            .get();
    return rows.map(_releaseFromRow).toList(growable: false);
  }

  /// Replaces the known releases for one scope, in one transaction.
  ///
  /// The server's inventory is the truth, so a release it no longer lists is
  /// removed rather than left as a rollback target that would fail.
  Future<void> replaceReleasesForScope({
    required String projectId,
    required String serverId,
    required List<AppReleaseRecord> releases,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    if (scope == null) {
      return;
    }
    final normalized = releases
        .map(_normalizeRelease)
        .whereType<AppReleaseRecord>()
        .toList(growable: false);
    await _database.transaction(() async {
      await (_database.delete(_database.appReleases)..where(
            (table) =>
                table.projectId.equals(scope.projectId) &
                table.serverId.equals(scope.serverId),
          ))
          .go();
      for (final release in normalized) {
        await upsertRelease(release);
      }
    });
  }

  /// Stores one release, preserving its original creation time.
  ///
  /// A record without a project, server or release id is dropped: its derived
  /// id would not identify anything.
  Future<void> upsertRelease(AppReleaseRecord record) async {
    final normalized = _normalizeRelease(record);
    if (normalized == null) {
      return;
    }
    final existing =
        await (_database.select(_database.appReleases)
              ..where((table) => table.id.equals(normalized.id))
              ..limit(1))
            .getSingleOrNull();
    await _database
        .into(_database.appReleases)
        .insertOnConflictUpdate(
          AppReleasesCompanion.insert(
            id: normalized.id,
            projectId: normalized.projectId,
            serverId: normalized.serverId,
            releaseId: normalized.releaseId,
            status: normalized.status,
            deploymentKind: Value(normalized.deploymentKind),
            branch: Value(normalized.branch),
            commitSha: Value(normalized.commitSha),
            imageName: Value(normalized.imageName),
            webContainerName: Value(normalized.webContainerName),
            appPort: Value(normalized.appPort),
            createdAtRemote: Value(normalized.createdAtRemote),
            liveAt: Value(normalized.liveAt),
            rollbackFromReleaseId: Value(normalized.rollbackFromReleaseId),
            rollbackReason: Value(normalized.rollbackReason),
            runtimeEnvJson: Value(normalized.runtimeEnvJson),
            workersJson: Value(normalized.workersJson),
            lastObservedAt: Value(normalized.lastObservedAt),
            createdAt: Value(existing?.createdAt ?? normalized.createdAt),
            updatedAt: Value(normalized.updatedAt),
          ),
        );
  }

  // coverage-gate: release_runtime_snapshot_repository
  /// The last runtime observation for one scope, or null when none was made.
  Future<AppRuntimeSnapshotRecord?> readRuntimeSnapshot({
    required String projectId,
    required String serverId,
  }) {
    return _readSingletonRow(
      projectId: projectId,
      serverId: serverId,
      table: _database.appRuntimeSnapshots,
      where: (table, projectId, serverId) =>
          table.projectId.equals(projectId) & table.serverId.equals(serverId),
      fromRow: (row) => AppRuntimeSnapshotRecord(
        projectId: row.projectId,
        serverId: row.serverId,
        resourceUsageJson: row.resourceUsageJson,
        healthStatus: row.healthStatus,
        publicHealthJson: row.publicHealthJson,
        healthCheckedAt: row.healthCheckedAt,
        resourceCheckedAt: row.resourceCheckedAt,
        updatedAt: row.updatedAt,
      ),
    );
  }

  /// Stores the current runtime observation, replacing the previous one.
  Future<void> upsertRuntimeSnapshot(AppRuntimeSnapshotRecord record) async {
    final scope = _normalizeScope(
      projectId: record.projectId,
      serverId: record.serverId,
    );
    if (scope == null) {
      return;
    }
    await _database
        .into(_database.appRuntimeSnapshots)
        .insertOnConflictUpdate(
          AppRuntimeSnapshotsCompanion.insert(
            projectId: scope.projectId,
            serverId: scope.serverId,
            resourceUsageJson: Value(trimOrNull(record.resourceUsageJson)),
            healthStatus: Value(trimOrNull(record.healthStatus)),
            publicHealthJson: Value(trimOrNull(record.publicHealthJson)),
            healthCheckedAt: Value(record.healthCheckedAt),
            resourceCheckedAt: Value(record.resourceCheckedAt),
            updatedAt: Value(record.updatedAt),
          ),
        );
  }

  // end coverage-gate
  /// The last worker observation for one scope, or null when none was made.
  Future<WorkerRuntimeSnapshotRecord?> readWorkerRuntimeSnapshot({
    required String projectId,
    required String serverId,
  }) {
    return _readSingletonRow(
      projectId: projectId,
      serverId: serverId,
      table: _database.workerRuntimeSnapshots,
      where: (table, projectId, serverId) =>
          table.projectId.equals(projectId) & table.serverId.equals(serverId),
      fromRow: (row) => WorkerRuntimeSnapshotRecord(
        projectId: row.projectId,
        serverId: row.serverId,
        snapshotJson: row.snapshotJson,
        lastCheckedAt: row.lastCheckedAt,
        updatedAt: row.updatedAt,
      ),
    );
  }

  /// Stores the current worker observation, ignoring an empty payload.
  ///
  /// Empty is dropped rather than stored: overwriting a real snapshot with
  /// nothing would make a running set of workers look like none at all.
  Future<void> upsertWorkerRuntimeSnapshot(
    WorkerRuntimeSnapshotRecord record,
  ) async {
    final scope = _normalizeScope(
      projectId: record.projectId,
      serverId: record.serverId,
    );
    if (scope == null || record.snapshotJson.trim().isEmpty) {
      return;
    }
    await _database
        .into(_database.workerRuntimeSnapshots)
        .insertOnConflictUpdate(
          WorkerRuntimeSnapshotsCompanion.insert(
            projectId: scope.projectId,
            serverId: scope.serverId,
            snapshotJson: record.snapshotJson,
            lastCheckedAt: Value(record.lastCheckedAt),
            updatedAt: Value(record.updatedAt),
          ),
        );
  }

  /// The import state for one scope, or null before any import is attempted.
  Future<ProjectWorkspaceImportStateRecord?> readImportState({
    required String projectId,
    required String serverId,
  }) {
    return _readSingletonRow(
      projectId: projectId,
      serverId: serverId,
      table: _database.projectWorkspaceImportStates,
      where: (table, projectId, serverId) =>
          table.projectId.equals(projectId) & table.serverId.equals(serverId),
      fromRow: _importStateFromRow,
    );
  }

  /// Records how the first import of existing server state is going.
  Future<void> upsertImportState({
    required String projectId,
    required String serverId,
    required String status,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? errorMessage,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    if (scope == null) {
      return;
    }
    await _database
        .into(_database.projectWorkspaceImportStates)
        .insertOnConflictUpdate(
          ProjectWorkspaceImportStatesCompanion.insert(
            projectId: scope.projectId,
            serverId: scope.serverId,
            status: Value(_normalizeImportStatus(status)),
            startedAt: Value(startedAt),
            finishedAt: Value(finishedAt),
            errorMessage: Value(trimOrNull(errorMessage)),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  /// Opens a journal entry *before* an operation runs.
  ///
  /// Before, not after: an entry written afterwards would not exist for the
  /// operations this journal is for -- the ones interrupted partway.
  ///
  /// The request is redacted before it is stored. Throws [ArgumentError]
  /// without a project and server, since an entry that cannot be attributed
  /// cannot be replayed.
  Future<ProjectManagedOperationJournalRecord> createJournalEntry({
    required String projectId,
    required String serverId,
    required String surface,
    required String operationType,
    Map<String, dynamic>? request,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    if (scope == null) {
      throw ArgumentError('projectId and serverId are required.');
    }
    final now = DateTime.now();
    final id =
        'journal-${now.microsecondsSinceEpoch}-${safeToken(surface)}-${safeToken(operationType)}';
    final row = ProjectManagedOperationJournalRecord(
      id: id,
      projectId: scope.projectId,
      serverId: scope.serverId,
      surface: surface.trim(),
      operationType: operationType.trim(),
      status: 'pending_remote',
      // coverage-gate: diagnostic_journal_request
      requestJson: request == null
          ? null
          : jsonEncode(sanitizeSensitiveData(request)),
      // end coverage-gate
      createdAt: now,
      updatedAt: now,
    );
    await _database
        .into(_database.projectManagedOperationJournal)
        .insert(_journalCompanion(row));
    return row;
  }

  /// Records how a journalled operation ended.
  ///
  /// The result is always redacted before persistence.
  ///
  /// [sanitizeResult] remains temporarily for source compatibility with older
  /// callers, but it can no longer disable the journal security boundary.
  Future<void> updateJournalStatus({
    required String id,
    required String status,
    Map<String, dynamic>? result,
    String? errorMessage,
    bool sanitizeResult = true,
  }) async {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      return;
    }
    await (_database.update(
      _database.projectManagedOperationJournal,
    )..where((table) => table.id.equals(normalizedId))).write(
      ProjectManagedOperationJournalCompanion(
        status: Value(status.trim()),
        // coverage-gate: diagnostic_journal_result
        resultJson: Value(
          result == null ? null : jsonEncode(sanitizeSensitiveData(result)),
        ),
        // end coverage-gate
        errorMessage: Value(trimOrNull(errorMessage)),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  // coverage-gate: journal_status_lists
  /// Lists journal entries with one status, oldest first.
  ///
  /// Why one owner with a status parameter: the success and failed listings
  /// share clamp + filter + ascending-createdAt + map and differ only in
  /// the status literal; one owner keeps the replay order (oldest first)
  /// and the 1-1000 clamp from drifting apart between the two.
  Future<List<ProjectManagedOperationJournalRecord>> _listJournalByStatus({
    required String status,
    int limit = 100,
  }) async {
    final boundedLimit = limit < 1 ? 1 : (limit > 1000 ? 1000 : limit);
    final rows =
        await (_database.select(_database.projectManagedOperationJournal)
              ..where((table) => table.status.equals(status))
              ..orderBy([(table) => OrderingTerm.asc(table.createdAt)])
              ..limit(boundedLimit))
            .get();
    return rows.map(_journalFromRow).toList(growable: false);
  }
  // end coverage-gate

  /// Operations that succeeded remotely and have not been applied locally,
  /// oldest first.
  ///
  /// Oldest first matters: these are replayed in order, and applying a later
  /// result before an earlier one would leave the mirror describing a state
  /// the server passed through rather than the one it is in. [limit] is
  /// clamped to 1-1000.
  Future<List<ProjectManagedOperationJournalRecord>> listRemoteSuccessJournal({
    int limit = 100,
  }) {
    return _listJournalByStatus(status: 'remote_success', limit: limit);
  }

  /// Operations that failed, oldest first, for reporting to the user.
  Future<List<ProjectManagedOperationJournalRecord>> listFailedJournal({
    int limit = 100,
  }) {
    return _listJournalByStatus(status: 'failed', limit: limit);
  }

  // coverage-gate: latest_failed_deploy_journal
  /// Finds a recoverable failed outcome only when it is still the latest one.
  Future<ProjectManagedOperationJournalRecord?>
  readLatestFailedJournalForOperation({
    required String projectId,
    required String serverId,
    required String surface,
    required String operationType,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    final normalizedSurface = surface.trim();
    final normalizedOperationType = operationType.trim();
    if (scope == null ||
        normalizedSurface.isEmpty ||
        normalizedOperationType.isEmpty) {
      return null;
    }
    final row =
        await (_database.select(_database.projectManagedOperationJournal)
              ..where(
                (table) =>
                    table.projectId.equals(scope.projectId) &
                    table.serverId.equals(scope.serverId) &
                    table.surface.equals(normalizedSurface) &
                    table.operationType.equals(normalizedOperationType),
              )
              ..orderBy([
                (table) => OrderingTerm.desc(table.createdAt),
                (table) => OrderingTerm.desc(table.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (row == null || row.status != 'failed') {
      return null;
    }
    return _journalFromRow(row);
  }
  // end coverage-gate

  /// Builds a release record from an engine payload, or null when it has no
  /// project, server or release id.
  ///
  /// Tolerant about everything else: an unrecognised status becomes
  /// `retained`, a missing branch becomes `main`, and unparseable timestamps
  /// become null -- a release that exists on the server should appear in the
  /// list even when part of its description is unreadable.
  static AppReleaseRecord? fromBackendRelease({
    required String projectId,
    required String serverId,
    required Map<dynamic, dynamic> payload,
    DateTime? observedAt,
  }) {
    final releaseId = payload['release_id']?.toString().trim() ?? '';
    if (projectId.trim().isEmpty ||
        serverId.trim().isEmpty ||
        releaseId.isEmpty) {
      return null;
    }
    final now = DateTime.now();
    return AppReleaseRecord(
      id: _releaseId(
        projectId: projectId,
        serverId: serverId,
        releaseId: releaseId,
      ),
      projectId: projectId.trim(),
      serverId: serverId.trim(),
      releaseId: releaseId,
      status: _normalizeReleaseStatus(payload['status']?.toString()),
      deploymentKind: _trimOrDefault(
        payload['deployment_kind']?.toString(),
        'deploy',
      ),
      branch: _trimOrDefault(payload['branch']?.toString(), 'main'),
      commitSha: trimOrNull(
        payload['commit_sha']?.toString() ?? payload['commit']?.toString(),
      ),
      imageName: trimOrNull(payload['image_name']?.toString()),
      webContainerName: trimOrNull(payload['web_container_name']?.toString()),
      appPort: _asInt(payload['app_port']),
      createdAtRemote: _asDateTime(payload['created_at']),
      liveAt: _asDateTime(payload['live_at']),
      rollbackFromReleaseId: trimOrNull(
        payload['rollback_from_release_id']?.toString(),
      ),
      rollbackReason: trimOrNull(payload['rollback_reason']?.toString()),
      runtimeEnvJson: payload['runtime_env'] is Map
          ? jsonEncode(payload['runtime_env'])
          : null,
      workersJson: payload['workers'] is List
          ? jsonEncode(payload['workers'])
          : null,
      lastObservedAt: observedAt ?? now,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Extracts every release an engine response mentions.
  ///
  /// The engine reports releases in three shapes depending on the operation --
  /// a `release_inventory`, a flat `releases` list, or a single release inline
  /// -- and all three are read here so callers do not each guess. Duplicates
  /// collapse by release id, first mention winning, since an inventory is more
  /// complete than an inline echo of one entry.
  static List<AppReleaseRecord> recordsFromBackendResponse({
    required String projectId,
    required String serverId,
    required Map<dynamic, dynamic> payload,
    DateTime? observedAt,
  }) {
    final observed = observedAt ?? DateTime.now();
    final entries = <Map<dynamic, dynamic>>[];
    final releaseInventory = payload['release_inventory'];
    final inventoryReleases = releaseInventory is Map
        ? releaseInventory['releases']
        : null;
    final releasesPayload = inventoryReleases is List
        ? inventoryReleases
        : payload['releases'];
    if (releasesPayload is List) {
      entries.addAll(releasesPayload.whereType<Map<dynamic, dynamic>>());
    }
    final releaseEntry = payload['release_entry'];
    if (releaseEntry is Map) {
      entries.add(releaseEntry);
    } else if (payload['release_id']?.toString().trim().isNotEmpty == true) {
      entries.add(payload);
    }

    final byReleaseId = <String, AppReleaseRecord>{};
    for (final entry in entries) {
      final release = fromBackendRelease(
        projectId: projectId,
        serverId: serverId,
        payload: entry,
        observedAt: observed,
      );
      if (release != null) {
        byReleaseId.putIfAbsent(release.releaseId, () => release);
      }
    }
    return byReleaseId.values.toList(growable: false);
  }

  static AppReleaseRecord? _normalizeRelease(AppReleaseRecord row) {
    if (row.projectId.trim().isEmpty ||
        row.serverId.trim().isEmpty ||
        row.releaseId.trim().isEmpty) {
      return null;
    }
    final now = DateTime.now();
    return AppReleaseRecord(
      id: _releaseId(
        projectId: row.projectId,
        serverId: row.serverId,
        releaseId: row.releaseId,
      ),
      projectId: row.projectId.trim(),
      serverId: row.serverId.trim(),
      releaseId: row.releaseId.trim(),
      status: _normalizeReleaseStatus(row.status),
      deploymentKind: _trimOrDefault(row.deploymentKind, 'deploy'),
      branch: _trimOrDefault(row.branch, 'main'),
      commitSha: trimOrNull(row.commitSha),
      imageName: trimOrNull(row.imageName),
      webContainerName: trimOrNull(row.webContainerName),
      appPort: row.appPort,
      createdAtRemote: row.createdAtRemote,
      liveAt: row.liveAt,
      rollbackFromReleaseId: trimOrNull(row.rollbackFromReleaseId),
      rollbackReason: trimOrNull(row.rollbackReason),
      runtimeEnvJson: trimOrNull(row.runtimeEnvJson),
      workersJson: trimOrNull(row.workersJson),
      lastObservedAt: row.lastObservedAt,
      createdAt: row.createdAt,
      updatedAt: now,
    );
  }

  static AppReleaseRecord _releaseFromRow(AppReleaseRow row) {
    return AppReleaseRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      releaseId: row.releaseId,
      status: row.status,
      deploymentKind: row.deploymentKind,
      branch: row.branch,
      commitSha: row.commitSha,
      imageName: row.imageName,
      webContainerName: row.webContainerName,
      appPort: row.appPort,
      createdAtRemote: row.createdAtRemote,
      liveAt: row.liveAt,
      rollbackFromReleaseId: row.rollbackFromReleaseId,
      rollbackReason: row.rollbackReason,
      runtimeEnvJson: row.runtimeEnvJson,
      workersJson: row.workersJson,
      lastObservedAt: row.lastObservedAt,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static ProjectWorkspaceImportStateRecord _importStateFromRow(
    ProjectWorkspaceImportStateRow row,
  ) {
    return ProjectWorkspaceImportStateRecord(
      projectId: row.projectId,
      serverId: row.serverId,
      status: row.status,
      startedAt: row.startedAt,
      finishedAt: row.finishedAt,
      errorMessage: row.errorMessage,
      updatedAt: row.updatedAt,
    );
  }

  static ProjectManagedOperationJournalRecord _journalFromRow(
    ProjectManagedOperationJournalRow row,
  ) {
    return ProjectManagedOperationJournalRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      surface: row.surface,
      operationType: row.operationType,
      status: row.status,
      requestJson: row.requestJson,
      resultJson: row.resultJson,
      errorMessage: row.errorMessage,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  static ProjectManagedOperationJournalCompanion _journalCompanion(
    ProjectManagedOperationJournalRecord row,
  ) {
    return ProjectManagedOperationJournalCompanion.insert(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      surface: row.surface,
      operationType: row.operationType,
      status: row.status,
      requestJson: Value(row.requestJson),
      resultJson: Value(row.resultJson),
      errorMessage: Value(row.errorMessage),
      createdAt: Value(row.createdAt),
      updatedAt: Value(row.updatedAt),
    );
  }

  static ({String projectId, String serverId})? _normalizeScope({
    required String projectId,
    required String serverId,
  }) {
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedProjectId.isEmpty || normalizedServerId.isEmpty) {
      return null;
    }
    return (projectId: normalizedProjectId, serverId: normalizedServerId);
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  static DateTime? _asDateTime(dynamic value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return DateTime.tryParse(raw);
  }

  static String _normalizeReleaseStatus(String? value) {
    final normalized = value?.trim().toLowerCase();
    return switch (normalized) {
      'live' => 'live',
      'retained' => 'retained',
      'failed' => 'failed',
      'candidate' => 'candidate',
      _ => 'retained',
    };
  }

  static String _normalizeImportStatus(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'importing' => 'importing',
      'imported' => 'imported',
      'completed' => 'imported',
      'failed' => 'failed',
      'skipped' => 'skipped',
      _ => 'pending',
    };
  }

  static String _trimOrDefault(String? value, String fallback) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
  }

  static String _releaseId({
    required String projectId,
    required String serverId,
    required String releaseId,
  }) {
    return 'release-${safeToken(serverId)}-${safeToken(projectId)}-${safeToken(releaseId)}';
  }

  // coverage-gate: release_singleton_reader
  /// Reads one scope-keyed singleton row, or null when there is none.
  ///
  /// Why one owner: the runtime, worker-runtime, and import-state readers
  /// share scope-guard + select-by-scope + null-or-map and differ only in
  /// table and mapper; one owner keeps the empty-scope contract (null, never
  /// throw) and the singleton select shape in one place. [where] scopes the
  /// select to one project and server and [fromRow] maps a found row -- both
  /// stay with the caller because their column and record types differ per
  /// table.
  Future<TRecord?>
  _readSingletonRow<TTable extends HasResultSet, TRow, TRecord>({
    required String projectId,
    required String serverId,
    required ResultSetImplementation<TTable, TRow> table,
    required Expression<bool> Function(
      TTable table,
      String projectId,
      String serverId,
    )
    where,
    required TRecord Function(TRow row) fromRow,
  }) async {
    final scope = _normalizeScope(projectId: projectId, serverId: serverId);
    if (scope == null) {
      return null;
    }
    final row =
        await (_database.select(table)
              ..where((t) => where(t, scope.projectId, scope.serverId))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return null;
    }
    return fromRow(row);
  }
  // end coverage-gate
}

/// The app-wide release repository.
final appReleaseRepositoryProvider = Provider<AppReleaseRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return AppReleaseRepository(database);
});
