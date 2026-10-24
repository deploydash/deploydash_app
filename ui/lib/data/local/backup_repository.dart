import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/bounded_int.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// Where a backup is written.
enum BackupDestinationType {
  /// An S3-compatible bucket. The server uploads to it directly.
  s3,

  /// A path on the managed server itself.
  ///
  /// Convenient, but on the same machine as the database -- so it protects
  /// against a bad migration, not against losing the server.
  filesystem,
}

/// Which database engine a backup covers.
enum BackupEngine {
  /// Managed PostgreSQL, the only engine with backup plans today.
  postgres,
}

/// Which direction a backup run went.
enum BackupOperationType {
  /// Data was copied out to a destination.
  backup,

  /// Data was copied back in from one.
  restore,

  /// Old artifacts beyond retention were deleted from a destination.
  cleanup,
}

/// A place a project's backups can be written to.
class BackupDestinationRecord {
  /// Records one destination.
  const BackupDestinationRecord({
    required this.id,
    required this.projectId,
    required this.serverId,
    required this.name,
    required this.type,
    required this.config,
    this.createdAt,
    this.updatedAt,
  });

  /// The destination's id, chosen by the caller.
  final String id;

  /// Which project owns it.
  final String projectId;

  /// Which server it is configured for.
  final String serverId;

  /// What the user calls it.
  final String name;

  /// S3 or a filesystem path.
  final BackupDestinationType type;

  /// Type-specific settings -- bucket, keys and region for S3, a path prefix
  /// for a filesystem. Held as an open map because the two shapes have
  /// nothing in common, and the engine reads whichever keys apply.
  final Map<String, dynamic> config;

  /// When it was created.
  final DateTime? createdAt;

  /// When it last changed.
  final DateTime? updatedAt;
}

/// A schedule for backing one database up to one destination.
///
/// The plan lives here, but the schedule that actually fires lives on the
/// server as a managed scheduler task -- see [managedTaskId].
class BackupPolicyRecord {
  /// Records one backup plan.
  const BackupPolicyRecord({
    this.engine = BackupEngine.postgres,
    required this.id,
    required this.projectId,
    required this.serverId,
    required this.name,
    required this.destinationId,
    required this.databaseName,
    required this.scheduleMode,
    required this.time1Hhmm,
    this.time2Hhmm,
    this.retentionKeepLast = 7,
    this.enabled = true,
    required this.managedTaskId,
    this.lastRunAt,
    this.lastStatus,
    this.lastMessage,
    this.createdAt,
    this.updatedAt,
  });

  /// Which engine this plan backs up.
  final BackupEngine engine;

  /// The plan's id. Also what its scheduler task id is derived from.
  final String id;

  /// Which project owns it.
  final String projectId;

  /// Which server it runs on.
  final String serverId;

  /// What the user calls it. Falls back to [id] when left blank.
  final String name;

  /// The destination backups are written to.
  final String destinationId;

  /// The database being backed up.
  final String databaseName;

  /// `daily_once` or `daily_twice`. Anything else normalizes to `daily_once`.
  final String scheduleMode;

  /// The first run time as `HH:MM`, defaulting to `02:00` when unparseable.
  final String time1Hhmm;

  /// The second run time for a twice-daily plan, defaulting to `14:00`. Null
  /// for a once-daily plan; the two are kept consistent on save.
  final String? time2Hhmm;

  /// How many backups to keep, clamped to 1-3650. Never zero: a plan that kept
  /// nothing would delete each backup as soon as it was made.
  final int retentionKeepLast;

  /// Whether the plan should run.
  final bool enabled;

  /// The scheduler task on the server that fires this plan.
  ///
  /// Derived from [id] rather than stored independently, so the desktop app
  /// and the server agree on which task belongs to which plan -- and so
  /// deleting a project can find these tasks by prefix.
  final String managedTaskId;

  /// When the plan last ran.
  final DateTime? lastRunAt;

  /// How that run ended.
  final String? lastStatus;

  /// What it reported.
  final String? lastMessage;

  /// When the plan was created.
  final DateTime? createdAt;

  /// When it last changed.
  final DateTime? updatedAt;
}

/// One backup file that exists at a destination.
///
/// Discovered by listing the destination rather than assumed from run history,
/// so what the restore picker offers is what is actually there.
class BackupArtifactRecord {
  /// Records one discovered backup.
  const BackupArtifactRecord({
    required this.id,
    this.engine = BackupEngine.postgres,
    required this.policyId,
    required this.projectId,
    required this.serverId,
    required this.destinationId,
    required this.databaseName,
    required this.remotePath,
    this.createdAtRemote,
    this.sizeBytes,
    this.metadataJson,
    this.discoveredAt,
  });

  /// Derived from the policy and the remote path, so re-listing a destination
  /// produces the same ids and does not duplicate rows.
  final String id;

  /// Which engine produced it.
  final BackupEngine engine;

  /// The plan it belongs to.
  final String policyId;

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// The destination it lives at.
  final String destinationId;

  /// The database it holds.
  final String databaseName;

  /// Its path at the destination. The artifact's real identity, and what a
  /// restore acts on.
  final String remotePath;

  /// When the destination says it was created.
  final DateTime? createdAtRemote;

  /// Its size in bytes, when reported.
  final int? sizeBytes;

  /// Format and build metadata as JSON, for restore diagnostics.
  final String? metadataJson;

  /// When Deploy Dash last saw it in a listing.
  final DateTime? discoveredAt;
}

/// One backup or restore that happened.
class BackupRunRecord {
  /// Records one run.
  const BackupRunRecord({
    this.id,
    this.engine = BackupEngine.postgres,
    required this.projectId,
    required this.serverId,
    this.policyId,
    required this.operationType,
    required this.status,
    this.message,
    this.triggeredManually = false,
    this.taskId,
    this.artifactId,
    this.startedAt,
    this.finishedAt,
    this.createdAt,
  });

  /// Autoincrement row id, null before the run is stored.
  final int? id;

  /// Which engine.
  final BackupEngine engine;

  /// Which project.
  final String projectId;

  /// Which server.
  final String serverId;

  /// The plan behind it, or null for a one-off restore that no plan scheduled.
  final String? policyId;

  /// Whether data went out or came back.
  final BackupOperationType operationType;

  /// How it ended. `unknown` when the caller did not say.
  final String status;

  /// What it reported.
  final String? message;

  /// Whether a person started it rather than the schedule.
  final bool triggeredManually;

  /// The scheduler task that fired it, when one did.
  final String? taskId;

  /// The artifact it produced or restored from.
  final String? artifactId;

  /// When it began. Defaults to now, in UTC.
  final DateTime? startedAt;

  /// When it ended, or null while still running.
  final DateTime? finishedAt;

  /// When the row was written.
  final DateTime? createdAt;
}

/// Stores backup destinations, plans, discovered artifacts and run history.
///
/// Scoped by project and server together throughout, since a project can move
/// between servers and a plan is meaningless away from the machine that runs
/// it. Schedule times and retention are normalized on write, because both end
/// up in a scheduler task on a customer's server.
///
/// The `switch (engine)` blocks look redundant with one engine, and are
/// deliberate: they make the compiler name every site that a second engine
/// would have to touch.
class BackupRepository {
  /// Creates the repository over the app database.
  const BackupRepository(this._database);

  final AppDatabase _database;

  /// Lists rows for a project+server scope.
  ///
  /// Why: the four scope lists share trim-guard + select + map and differ in
  /// table, predicates, ordering, mapper, and post-processing; one owner keeps
  /// the guard and the empty-scope contract in one place. The fetch callback
  /// (not table-plumbing generics) carries the per-list query: Drift table
  /// types differ per list, so a fuller parameterized helper would read worse
  /// than one guard plus four query bodies (D-14 executor decision).
  Future<List<R>> _listForScope<R>(
    String projectId,
    String serverId, {
    required Future<List<R>> Function(String projectId, String serverId) fetch,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedProjectId.isEmpty || normalizedServerId.isEmpty) {
      return const [];
    }
    return fetch(normalizedProjectId, normalizedServerId);
  }

  /// A project's destinations on one server, by name.
  Future<List<BackupDestinationRecord>> listDestinationsForScope({
    required String projectId,
    required String serverId,
  }) {
    return _listForScope(
      projectId,
      serverId,
      fetch: (normalizedProjectId, normalizedServerId) async {
        final rows =
            await (_database.select(_database.backupDestinations)
                  ..where(
                    (table) =>
                        table.projectId.equals(normalizedProjectId) &
                        table.serverId.equals(normalizedServerId),
                  )
                  ..orderBy([(table) => OrderingTerm.asc(table.name)]))
                .get();

        return rows.map(_destinationFromRow).toList(growable: false);
      },
    );
  }

  /// Creates or updates a destination, preserving its creation time.
  ///
  /// Blank config keys are dropped, so a stray empty key cannot reach the
  /// engine as part of a destination's settings.
  Future<void> upsertDestination(BackupDestinationRecord input) async {
    final normalized = _normalizeDestination(input);
    final now = DateTime.now();
    final existing =
        await (_database.select(_database.backupDestinations)
              ..where((table) => table.id.equals(normalized.id))
              ..limit(1))
            .getSingleOrNull();

    final companion = BackupDestinationsCompanion(
      id: Value(normalized.id),
      projectId: Value(normalized.projectId),
      serverId: Value(normalized.serverId),
      name: Value(normalized.name),
      type: Value(_destinationTypeStorage(normalized.type)),
      configJson: Value(jsonEncode(normalized.config)),
      createdAt: Value(existing?.createdAt ?? now),
      updatedAt: Value(now),
    );
    await _database
        .into(_database.backupDestinations)
        .insertOnConflictUpdate(companion);
  }

  /// Removes a destination.
  ///
  /// Plans that pointed at it are left alone deliberately: silently deleting
  /// a user's backup schedule as a side effect of removing a destination is a
  /// bigger action than they asked for. The plan will fail visibly instead.
  Future<void> deleteDestination({
    required String id,
    required String projectId,
    required String serverId,
  }) async {
    final normalizedId = id.trim();
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedId.isEmpty ||
        normalizedProjectId.isEmpty ||
        normalizedServerId.isEmpty) {
      return;
    }
    await (_database.delete(_database.backupDestinations)..where(
          (table) =>
              table.id.equals(normalizedId) &
              table.projectId.equals(normalizedProjectId) &
              table.serverId.equals(normalizedServerId),
        ))
        .go();
  }

  /// A project's backup plans on one server, by name.
  Future<List<BackupPolicyRecord>> listPoliciesForScope({
    required String projectId,
    required String serverId,
  }) {
    return _listForScope(
      projectId,
      serverId,
      fetch: (normalizedProjectId, normalizedServerId) async {
        final postgresRows =
            await (_database.select(_database.postgresBackupPolicies)..where(
                  (table) =>
                      table.projectId.equals(normalizedProjectId) &
                      table.serverId.equals(normalizedServerId),
                ))
                .get();
        final policies = <BackupPolicyRecord>[
          ...postgresRows.map(_postgresPolicyFromRow),
        ];
        policies.sort((left, right) {
          final nameCompare = left.name.compareTo(right.name);
          if (nameCompare != 0) {
            return nameCompare;
          }
          return left.engine.name.compareTo(right.engine.name);
        });
        return policies;
      },
    );
  }

  /// Creates or updates a plan, preserving its creation time.
  ///
  /// The schedule is normalized first: times to `HH:MM`, the second time
  /// present only for a twice-daily plan, and retention clamped to 1-3650.
  Future<void> upsertPolicy(BackupPolicyRecord input) async {
    final normalized = _normalizePolicy(input);
    final now = DateTime.now();
    switch (normalized.engine) {
      case BackupEngine.postgres:
        final existing =
            await (_database.select(_database.postgresBackupPolicies)
                  ..where((table) => table.id.equals(normalized.id))
                  ..limit(1))
                .getSingleOrNull();
        final companion = PostgresBackupPoliciesCompanion(
          id: Value(normalized.id),
          projectId: Value(normalized.projectId),
          serverId: Value(normalized.serverId),
          name: Value(normalized.name),
          destinationId: Value(normalized.destinationId),
          databaseName: Value(normalized.databaseName),
          scheduleMode: Value(normalized.scheduleMode),
          time1Hhmm: Value(normalized.time1Hhmm),
          time2Hhmm: Value(normalized.time2Hhmm),
          retentionKeepLast: Value(normalized.retentionKeepLast),
          enabled: Value(normalized.enabled),
          managedTaskId: Value(normalized.managedTaskId),
          lastRunAt: Value(normalized.lastRunAt),
          lastStatus: Value(normalized.lastStatus),
          lastMessage: Value(normalized.lastMessage),
          createdAt: Value(existing?.createdAt ?? now),
          updatedAt: Value(now),
        );
        await _database
            .into(_database.postgresBackupPolicies)
            .insertOnConflictUpdate(companion);
    }
  }

  /// Records how a plan's last run went.
  ///
  /// Separate from [upsertPolicy] because these are observations rather than
  /// configuration. Omitting [enabled] leaves it alone.
  Future<void> updatePolicyRuntime({
    BackupEngine engine = BackupEngine.postgres,
    required String policyId,
    required String projectId,
    required String serverId,
    DateTime? lastRunAt,
    String? lastStatus,
    String? lastMessage,
    bool? enabled,
  }) async {
    final normalizedPolicyId = policyId.trim();
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedPolicyId.isEmpty ||
        normalizedProjectId.isEmpty ||
        normalizedServerId.isEmpty) {
      return;
    }

    switch (engine) {
      case BackupEngine.postgres:
        await (_database.update(_database.postgresBackupPolicies)..where(
              (table) =>
                  table.id.equals(normalizedPolicyId) &
                  table.projectId.equals(normalizedProjectId) &
                  table.serverId.equals(normalizedServerId),
            ))
            .write(
              PostgresBackupPoliciesCompanion(
                lastRunAt: Value(lastRunAt),
                lastStatus: Value(trimOrNull(lastStatus)),
                lastMessage: Value(trimOrNull(lastMessage)),
                enabled: enabled == null
                    ? const Value.absent()
                    : Value(enabled),
                updatedAt: Value(DateTime.now()),
              ),
            );
    }
  }

  /// Deletes a plan with its artifacts and run history, in one transaction.
  ///
  /// The artifact *rows* go, not the backups themselves -- those are the
  /// user's data at their destination, and deleting a schedule is not consent
  /// to destroy what it produced.
  Future<void> deletePolicy({
    BackupEngine engine = BackupEngine.postgres,
    required String id,
    required String projectId,
    required String serverId,
  }) async {
    final normalizedId = id.trim();
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedId.isEmpty ||
        normalizedProjectId.isEmpty ||
        normalizedServerId.isEmpty) {
      return;
    }
    await _database.transaction(() async {
      await (_database.delete(_database.backupArtifacts)..where(
            (table) =>
                table.engine.equals(_engineStorage(engine)) &
                table.policyId.equals(normalizedId) &
                table.projectId.equals(normalizedProjectId) &
                table.serverId.equals(normalizedServerId),
          ))
          .go();
      await (_database.delete(_database.backupRuns)..where(
            (table) =>
                table.engine.equals(_engineStorage(engine)) &
                table.policyId.equals(normalizedId) &
                table.projectId.equals(normalizedProjectId) &
                table.serverId.equals(normalizedServerId),
          ))
          .go();
      switch (engine) {
        case BackupEngine.postgres:
          await (_database.delete(_database.postgresBackupPolicies)..where(
                (table) =>
                    table.id.equals(normalizedId) &
                    table.projectId.equals(normalizedProjectId) &
                    table.serverId.equals(normalizedServerId),
              ))
              .go();
      }
    });
  }

  // coverage-gate: backup_service_policy_catalog_cleanup
  /// Removes every server-side plan record after that database service is gone.
  ///
  /// Artifacts and run rows are observations owned by those plans, so they
  /// leave in the same transaction. Destinations remain: they may point at
  /// durable storage the user wants to reuse after enabling PostgreSQL again.
  Future<void> deletePoliciesForServer(String serverId) async {
    final normalizedServerId = serverId.trim();
    if (normalizedServerId.isEmpty) {
      return;
    }
    await _database.transaction(() async {
      await (_database.delete(
        _database.backupArtifacts,
      )..where((table) => table.serverId.equals(normalizedServerId))).go();
      await (_database.delete(
        _database.backupRuns,
      )..where((table) => table.serverId.equals(normalizedServerId))).go();
      await (_database.delete(
        _database.postgresBackupPolicies,
      )..where((table) => table.serverId.equals(normalizedServerId))).go();
    });
  }
  // end coverage-gate

  /// Discovered artifacts for one scope, newest first, optionally narrowed to
  /// one engine or plan.
  Future<List<BackupArtifactRecord>> listArtifactsForScope({
    required String projectId,
    required String serverId,
    BackupEngine? engine,
    String? policyId,
  }) {
    return _listForScope(
      projectId,
      serverId,
      fetch: (normalizedProjectId, normalizedServerId) async {
        final query = _database.select(_database.backupArtifacts)
          ..where(
            (table) =>
                table.projectId.equals(normalizedProjectId) &
                table.serverId.equals(normalizedServerId),
          )
          ..orderBy([
            (table) => OrderingTerm.desc(table.createdAtRemote),
            (table) => OrderingTerm.desc(table.discoveredAt),
            (table) => OrderingTerm.asc(table.remotePath),
          ]);
        final normalizedPolicyId = trimOrNull(policyId);
        if (engine != null) {
          query.where((table) => table.engine.equals(_engineStorage(engine)));
        }
        if (normalizedPolicyId != null) {
          query.where((table) => table.policyId.equals(normalizedPolicyId));
        }
        final rows = await query.get();
        return rows.map(_artifactFromRow).toList(growable: false);
      },
    );
  }

  /// Replaces the known artifacts for one plan, in one transaction.
  ///
  /// The destination's listing is the truth: an artifact no longer there is
  /// removed rather than left as a restore option that would fail. Entries
  /// without an id are skipped.
  Future<void> replaceArtifactsForPolicy({
    BackupEngine engine = BackupEngine.postgres,
    required String policyId,
    required String projectId,
    required String serverId,
    required List<BackupArtifactRecord> artifacts,
  }) async {
    final normalizedPolicyId = policyId.trim();
    final normalizedProjectId = projectId.trim();
    final normalizedServerId = serverId.trim();
    if (normalizedPolicyId.isEmpty ||
        normalizedProjectId.isEmpty ||
        normalizedServerId.isEmpty) {
      return;
    }

    final normalized = artifacts
        .where((item) => item.id.trim().isNotEmpty)
        .map(
          (item) => BackupArtifactRecord(
            id: item.id.trim(),
            engine: engine,
            policyId: normalizedPolicyId,
            projectId: normalizedProjectId,
            serverId: normalizedServerId,
            destinationId: item.destinationId.trim(),
            databaseName: item.databaseName.trim(),
            remotePath: item.remotePath.trim(),
            createdAtRemote: item.createdAtRemote,
            sizeBytes: item.sizeBytes,
            metadataJson: trimOrNull(item.metadataJson),
            discoveredAt: item.discoveredAt,
          ),
        )
        .toList(growable: false);

    await _database.transaction(() async {
      await (_database.delete(_database.backupArtifacts)..where(
            (table) =>
                table.engine.equals(_engineStorage(engine)) &
                table.policyId.equals(normalizedPolicyId) &
                table.projectId.equals(normalizedProjectId) &
                table.serverId.equals(normalizedServerId),
          ))
          .go();
      for (final item in normalized) {
        await _database
            .into(_database.backupArtifacts)
            .insert(
              BackupArtifactsCompanion.insert(
                id: item.id,
                engine: Value(_engineStorage(item.engine)),
                policyId: item.policyId,
                projectId: item.projectId,
                serverId: item.serverId,
                destinationId: item.destinationId,
                databaseName: item.databaseName,
                remotePath: item.remotePath,
                createdAtRemote: Value(item.createdAtRemote),
                sizeBytes: Value(item.sizeBytes),
                metadataJson: Value(item.metadataJson),
                discoveredAt: Value(
                  item.discoveredAt ?? DateTime.now().toUtc(),
                ),
              ),
            );
      }
    });
  }

  /// Recent runs for one scope, newest first. [limit] is clamped to 1-1000.
  Future<List<BackupRunRecord>> listRunsForScope({
    required String projectId,
    required String serverId,
    BackupEngine? engine,
    int limit = 200,
  }) {
    final boundedLimit = boundedInt(limit, fallback: 1, max: 1000);
    return _listForScope(
      projectId,
      serverId,
      fetch: (normalizedProjectId, normalizedServerId) async {
        final query = _database.select(_database.backupRuns)
          ..where(
            (table) =>
                table.projectId.equals(normalizedProjectId) &
                table.serverId.equals(normalizedServerId),
          )
          ..orderBy([
            (table) => OrderingTerm.desc(table.startedAt),
            (table) => OrderingTerm.desc(table.id),
          ])
          ..limit(boundedLimit);
        if (engine != null) {
          query.where((table) => table.engine.equals(_engineStorage(engine)));
        }
        final rows = await query.get();

        return rows.map(_runFromRow).toList(growable: false);
      },
    );
  }

  /// Records one run. A run without a project and server is dropped, since it
  /// could not be shown against anything.
  Future<void> appendRun(BackupRunRecord run) async {
    final normalizedProjectId = run.projectId.trim();
    final normalizedServerId = run.serverId.trim();
    if (normalizedProjectId.isEmpty || normalizedServerId.isEmpty) {
      return;
    }
    await _database
        .into(_database.backupRuns)
        .insert(
          BackupRunsCompanion.insert(
            engine: Value(_engineStorage(run.engine)),
            projectId: normalizedProjectId,
            serverId: normalizedServerId,
            policyId: Value(trimOrNull(run.policyId)),
            operationType: _operationTypeStorage(run.operationType),
            status: run.status.trim().isEmpty ? 'unknown' : run.status.trim(),
            message: Value(trimOrNull(run.message)),
            triggeredManually: Value(run.triggeredManually),
            taskId: Value(trimOrNull(run.taskId)),
            artifactId: Value(trimOrNull(run.artifactId)),
            startedAt: Value(run.startedAt ?? DateTime.now().toUtc()),
            finishedAt: Value(run.finishedAt),
            createdAt: Value(run.createdAt ?? DateTime.now().toUtc()),
          ),
        );
  }

  BackupDestinationRecord _destinationFromRow(BackupDestinationRow row) {
    final config = _decodeJsonMap(row.configJson);
    return BackupDestinationRecord(
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      name: row.name,
      type: _destinationTypeFromStorage(row.type),
      config: config,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  BackupDestinationRecord _normalizeDestination(BackupDestinationRecord input) {
    final type = input.type;
    final config = <String, dynamic>{};
    for (final entry in input.config.entries) {
      final key = entry.key.trim();
      if (key.isEmpty) {
        continue;
      }
      config[key] = entry.value;
    }
    return BackupDestinationRecord(
      id: input.id.trim(),
      projectId: input.projectId.trim(),
      serverId: input.serverId.trim(),
      name: input.name.trim(),
      type: type,
      config: config,
      createdAt: input.createdAt,
      updatedAt: input.updatedAt,
    );
  }

  BackupPolicyRecord _postgresPolicyFromRow(PostgresBackupPolicyRow row) {
    return BackupPolicyRecord(
      engine: BackupEngine.postgres,
      id: row.id,
      projectId: row.projectId,
      serverId: row.serverId,
      name: row.name,
      destinationId: row.destinationId,
      databaseName: row.databaseName,
      scheduleMode: row.scheduleMode,
      time1Hhmm: row.time1Hhmm,
      time2Hhmm: row.time2Hhmm,
      retentionKeepLast: row.retentionKeepLast,
      enabled: row.enabled,
      managedTaskId: row.managedTaskId,
      lastRunAt: row.lastRunAt,
      lastStatus: row.lastStatus,
      lastMessage: row.lastMessage,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  BackupPolicyRecord _normalizePolicy(BackupPolicyRecord input) {
    final time1 = _normalizeHhmm(input.time1Hhmm) ?? '02:00';
    final normalizedMode = _normalizeScheduleMode(input.scheduleMode);
    final time2 = normalizedMode == 'daily_twice'
        ? (_normalizeHhmm(input.time2Hhmm) ?? '14:00')
        : null;
    final retention = input.retentionKeepLast < 1
        ? 1
        : (input.retentionKeepLast > 3650 ? 3650 : input.retentionKeepLast);

    return BackupPolicyRecord(
      engine: input.engine,
      id: input.id.trim(),
      projectId: input.projectId.trim(),
      serverId: input.serverId.trim(),
      name: input.name.trim().isEmpty ? input.id.trim() : input.name.trim(),
      destinationId: input.destinationId.trim(),
      databaseName: input.databaseName.trim(),
      scheduleMode: normalizedMode,
      time1Hhmm: time1,
      time2Hhmm: time2,
      retentionKeepLast: retention,
      enabled: input.enabled,
      managedTaskId: input.managedTaskId.trim(),
      lastRunAt: input.lastRunAt,
      lastStatus: trimOrNull(input.lastStatus),
      lastMessage: trimOrNull(input.lastMessage),
      createdAt: input.createdAt,
      updatedAt: input.updatedAt,
    );
  }

  BackupArtifactRecord _artifactFromRow(BackupArtifactRow row) {
    return BackupArtifactRecord(
      id: row.id,
      engine: _engineFromStorage(row.engine),
      policyId: row.policyId,
      projectId: row.projectId,
      serverId: row.serverId,
      destinationId: row.destinationId,
      databaseName: row.databaseName,
      remotePath: row.remotePath,
      createdAtRemote: row.createdAtRemote,
      sizeBytes: row.sizeBytes,
      metadataJson: row.metadataJson,
      discoveredAt: row.discoveredAt,
    );
  }

  BackupRunRecord _runFromRow(BackupRunRow row) {
    return BackupRunRecord(
      id: row.id,
      engine: _engineFromStorage(row.engine),
      projectId: row.projectId,
      serverId: row.serverId,
      policyId: row.policyId,
      operationType: _operationTypeFromStorage(row.operationType),
      status: row.status,
      message: row.message,
      triggeredManually: row.triggeredManually,
      taskId: row.taskId,
      artifactId: row.artifactId,
      startedAt: row.startedAt,
      finishedAt: row.finishedAt,
      createdAt: row.createdAt,
    );
  }

  static BackupDestinationType _destinationTypeFromStorage(String raw) {
    return raw.trim().toLowerCase() == 'filesystem'
        ? BackupDestinationType.filesystem
        : BackupDestinationType.s3;
  }

  static String _destinationTypeStorage(BackupDestinationType type) {
    return switch (type) {
      BackupDestinationType.s3 => 's3',
      BackupDestinationType.filesystem => 'filesystem',
    };
  }

  static BackupOperationType _operationTypeFromStorage(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'restore') {
      return BackupOperationType.restore;
    }
    if (normalized == 'cleanup') {
      return BackupOperationType.cleanup;
    }
    return BackupOperationType.backup;
  }

  static String _operationTypeStorage(BackupOperationType type) {
    return switch (type) {
      BackupOperationType.backup => 'backup',
      BackupOperationType.restore => 'restore',
      BackupOperationType.cleanup => 'cleanup',
    };
  }

  static BackupEngine _engineFromStorage(String raw) {
    return BackupEngine.postgres;
  }

  static String _engineStorage(BackupEngine engine) {
    return switch (engine) {
      BackupEngine.postgres => 'postgres',
    };
  }

  static String _normalizeScheduleMode(String raw) {
    final normalized = raw.trim().toLowerCase();
    if (normalized == 'daily_twice') {
      return 'daily_twice';
    }
    return 'daily_once';
  }

  static String? _normalizeHhmm(String? raw) {
    if (raw == null) {
      return null;
    }
    final trimmed = raw.trim();
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(trimmed);
    if (match == null) {
      return null;
    }
    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    if (hour == null || minute == null || hour < 0 || hour > 23) {
      return null;
    }
    if (minute < 0 || minute > 59) {
      return null;
    }
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  // D-58 (T-014): left — non-null contract (blank/unparseable/non-map →
  // const {}); the other three _decodeJsonMap defs return null instead.
  static Map<String, dynamic> _decodeJsonMap(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return const <String, dynamic>{};
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
}

/// The app-wide backup repository.
final backupRepositoryProvider = Provider<BackupRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return BackupRepository(database);
});
