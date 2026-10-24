import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/project.dart';
import '../../models/railpack_runtime.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

export '../../domain/project.dart';

/// Reads and writes projects, and owns what a project row may contain.
///
/// Every write normalizes before it stores: a branch defaults to `main`, an
/// out-of-range port to 3000, a health path to one starting with `/`, and an
/// unrecognised TLS provider, SQLite volume name, mount path or filename to
/// null. That is deliberate placement -- these values end up in shell and
/// Docker commands on a customer's server, so the boundary that persists them
/// is the boundary that constrains them, not the form that happened to collect
/// them.
///
/// Reads exclude projects that are mid-deletion unless asked otherwise, so a
/// project whose server-side cleanup is still running does not reappear in the
/// UI as though nothing had happened.
class ProjectRepository {
  /// Creates the repository over the app database.
  ProjectRepository(this._database);

  final AppDatabase _database;

  // coverage-gate: list_projects
  /// Projects by name, optionally for one server.
  ///
  /// Projects with a deletion in progress are hidden unless
  /// [includePendingDeletion] is set -- the retry flow needs them, the rest of
  /// the app does not.
  Future<List<Project>> listProjects({
    String? serverId,
    bool includePendingDeletion = false,
  }) async {
    final normalizedServerId = trimOrNull(serverId);
    final query = _database.select(_database.projects)
      ..orderBy([(table) => OrderingTerm.asc(table.name)]);
    if (normalizedServerId != null) {
      query.where((table) => table.serverId.equals(normalizedServerId));
    }
    final rows = await query.get();
    if (includePendingDeletion || rows.isEmpty) {
      return rows.map(_mapRow).toList(growable: false);
    }
    final pendingRows = await _database
        .select(_database.projectDeletionRecoveryStates)
        .get();
    final pendingProjectIds = pendingRows.map((row) => row.projectId).toSet();
    return rows
        .where((row) => !pendingProjectIds.contains(row.id))
        .map(_mapRow)
        .toList(growable: false);
  }
  // end coverage-gate

  // coverage-gate: read_active_project_id
  /// The active project's id, or the first project's when none is marked, or
  /// null when there are none.
  Future<String?> readActiveProjectId({String? serverId}) async {
    final projects = await listProjects(serverId: serverId);
    for (final project in projects) {
      if (project.isActive) {
        return project.id;
      }
    }
    return projects.isEmpty ? null : projects.first.id;
  }
  // end coverage-gate

  // coverage-gate: read_project
  /// One project, or null when it does not exist or is mid-deletion.
  Future<Project?> readProject(
    String projectId, {
    bool includePendingDeletion = false,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return null;
    }
    if (!includePendingDeletion) {
      final pending =
          await (_database.select(_database.projectDeletionRecoveryStates)
                ..where((table) => table.projectId.equals(normalizedProjectId))
                ..limit(1))
              .getSingleOrNull();
      if (pending != null) {
        return null;
      }
    }
    final row =
        await (_database.select(_database.projects)
              ..where((table) => table.id.equals(normalizedProjectId))
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }
  // end coverage-gate

  /// Stores a new project, normalizing every field it can.
  ///
  /// Creating a project marked active demotes the others on the same server
  /// first, in the same transaction, so two projects can never both be active.
  Future<void> createProject(Project project) async {
    final now = DateTime.now();
    final normalizedDomainConfig = _normalizedDomainConfig(
      primaryDomain: project.primaryDomain,
      domainRoutingMode: project.domainRoutingMode,
    );
    final normalizedServerId = trimOrNull(project.serverId);
    await _database.transaction(() async {
      if (project.isActive) {
        final update = _database.update(_database.projects);
        if (normalizedServerId != null) {
          update.where((table) => table.serverId.equals(normalizedServerId));
        }
        await update.write(ProjectsCompanion(isActive: const Value(false)));
      }
      await _database
          .into(_database.projects)
          .insertOnConflictUpdate(
            ProjectsCompanion.insert(
              id: project.id,
              serverId: Value(normalizedServerId),
              name: project.name,
              type: project.type,
              gitUrl: project.gitUrl,
              primaryDomain: normalizedDomainConfig.primaryDomain,
              domainRoutingMode: Value(
                normalizedDomainConfig.domainRoutingMode,
              ),
              repositoryFullName: Value(trimOrNull(project.repositoryFullName)),
              appSubdirectory: Value(
                _normalizedAppSubdirectory(project.appSubdirectory),
              ),
              deployBranch: Value(_normalizedBranch(project.deployBranch)),
              appPort: Value(_normalizedPort(project.appPort)),
              publicHealthCheckEnabled: Value(project.publicHealthCheckEnabled),
              publicHealthCheckPath: Value(
                _normalizedPublicHealthPath(project.publicHealthCheckPath),
              ),
              lastDeployCommit: Value(trimOrNull(project.lastDeployCommit)),
              lastDeployedAt: Value(project.lastDeployedAt),
              railpackBuildCommand: Value(
                _normalizedCommand(project.railpackBuildCommand),
              ),
              railpackRunCommand: Value(
                _normalizedCommand(project.railpackRunCommand),
              ),
              railpackProvider: Value(
                normalizeRailpackProvider(project.railpackProvider),
              ),
              railpackNodeMode: Value(
                _normalizedRailpackNodeMode(project.railpackNodeMode),
              ),
              tlsChallengeMode: Value(
                _normalizedTlsChallengeMode(project.tlsChallengeMode),
              ),
              tlsDnsProvider: Value(
                _normalizedTlsDnsProvider(project.tlsDnsProvider),
              ),
              tlsDnsConfigJson: Value(
                _encodeTlsDnsCredentials(project.tlsDnsCredentials),
              ),
              appDisconnected: Value(project.appDisconnected),
              injectPostgresEnv: Value(project.injectPostgresEnv),
              sqliteStorageEnabled: Value(project.sqliteStorageEnabled),
              sqliteVolumeName: Value(
                _normalizedSqliteVolumeName(project.sqliteVolumeName),
              ),
              sqliteMountPath: Value(
                _normalizedSqliteMountPath(project.sqliteMountPath),
              ),
              sqliteFileName: Value(
                _normalizedSqliteFileName(project.sqliteFileName),
              ),
              isActive: Value(project.isActive),
              createdAt: Value(now),
              updatedAt: Value(now),
            ),
          );
    });
  }

  // coverage-gate: update_deployment_config
  /// Saves everything the deploy form owns.
  ///
  /// Two normalizations matter beyond the obvious. A redirect routing mode
  /// stores the apex domain with any leading `www.` stripped, so the redirect
  /// has a fixed point to redirect to. And switching TLS away from `dns`
  /// clears the DNS provider and its credentials rather than leaving them
  /// behind -- stale credentials for a challenge that no longer runs are a
  /// secret kept for no reason.
  ///
  /// The nullable command parameters distinguish "leave as it was" from "set
  /// to blank", which for Railpack means "detect it".
  Future<void> updateDeploymentConfig({
    required String projectId,
    required String primaryDomain,
    required String domainRoutingMode,
    required String repositoryFullName,
    required String? appSubdirectory,
    required String deployBranch,
    required int appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    required String railpackNodeMode,
    String? railpackProvider,
    required String tlsChallengeMode,
    required String? tlsDnsProvider,
    required Map<String, String> tlsDnsCredentials,
    required bool sqliteStorageEnabled,
    String? sqliteVolumeName,
    String? sqliteMountPath,
    String? sqliteFileName,
    String? railpackBuildCommand,
    String? railpackRunCommand,
  }) async {
    final now = DateTime.now();
    final normalizedDomainConfig = _normalizedDomainConfig(
      primaryDomain: primaryDomain,
      domainRoutingMode: domainRoutingMode,
    );
    final normalizedBuildCommand = railpackBuildCommand == null
        ? const Value<String>.absent()
        : Value(_normalizedCommand(railpackBuildCommand));
    final normalizedRunCommand = railpackRunCommand == null
        ? const Value<String>.absent()
        : Value(_normalizedCommand(railpackRunCommand));
    final normalizedTlsMode = _normalizedTlsChallengeMode(tlsChallengeMode);
    final normalizedTlsProvider = normalizedTlsMode == 'dns'
        ? _normalizedTlsDnsProvider(tlsDnsProvider)
        : null;
    final normalizedTlsCredentials = normalizedTlsMode == 'dns'
        ? tlsDnsCredentials
        : const <String, String>{};
    final normalizedSqliteVolumeName = sqliteStorageEnabled
        ? _normalizedSqliteVolumeName(sqliteVolumeName)
        : null;
    final normalizedSqliteMountPath = sqliteStorageEnabled
        ? _normalizedSqliteMountPath(sqliteMountPath)
        : null;
    final normalizedSqliteFileName = sqliteStorageEnabled
        ? _normalizedSqliteFileName(sqliteFileName)
        : null;
    await (_database.update(
      _database.projects,
    )..where((table) => table.id.equals(projectId))).write(
      ProjectsCompanion(
        primaryDomain: Value(normalizedDomainConfig.primaryDomain),
        domainRoutingMode: Value(normalizedDomainConfig.domainRoutingMode),
        repositoryFullName: Value(repositoryFullName.trim()),
        appSubdirectory: Value(_normalizedAppSubdirectory(appSubdirectory)),
        deployBranch: Value(_normalizedBranch(deployBranch)),
        appPort: Value(_normalizedPort(appPort)),
        publicHealthCheckEnabled: publicHealthCheckEnabled == null
            ? const Value<bool>.absent()
            : Value(publicHealthCheckEnabled),
        publicHealthCheckPath: publicHealthCheckPath == null
            ? const Value<String>.absent()
            : Value(_normalizedPublicHealthPath(publicHealthCheckPath)),
        railpackBuildCommand: normalizedBuildCommand,
        railpackRunCommand: normalizedRunCommand,
        railpackProvider: Value(normalizeRailpackProvider(railpackProvider)),
        railpackNodeMode: Value(_normalizedRailpackNodeMode(railpackNodeMode)),
        tlsChallengeMode: Value(normalizedTlsMode),
        tlsDnsProvider: Value(normalizedTlsProvider),
        tlsDnsConfigJson: Value(
          _encodeTlsDnsCredentials(normalizedTlsCredentials),
        ),
        sqliteStorageEnabled: Value(sqliteStorageEnabled),
        sqliteVolumeName: Value(normalizedSqliteVolumeName),
        sqliteMountPath: Value(normalizedSqliteMountPath),
        sqliteFileName: Value(normalizedSqliteFileName),
        updatedAt: Value(now),
      ),
    );
  }
  // end coverage-gate

  // coverage-gate: update_last_deploy_state
  /// Records the commit and time of the most recent successful deploy.
  Future<void> updateLastDeployState({
    required String projectId,
    String? commit,
    required DateTime deployedAt,
  }) async {
    final now = DateTime.now();
    await (_database.update(
      _database.projects,
    )..where((table) => table.id.equals(projectId))).write(
      ProjectsCompanion(
        lastDeployCommit: Value(trimOrNull(commit)),
        lastDeployedAt: Value(deployedAt),
        updatedAt: Value(now),
      ),
    );
  }
  // end coverage-gate

  // coverage-gate: set_active_project
  /// Makes one project active, demoting the others on its server.
  ///
  /// Silently does nothing for a project that does not exist or is
  /// mid-deletion: activating a project that is being torn down would point
  /// the whole workspace at it.
  Future<void> setActiveProject(String projectId) async {
    final now = DateTime.now();
    final pending =
        await (_database.select(_database.projectDeletionRecoveryStates)
              ..where((table) => table.projectId.equals(projectId))
              ..limit(1))
            .getSingleOrNull();
    if (pending != null) {
      return;
    }
    final target =
        await (_database.select(_database.projects)
              ..where((table) => table.id.equals(projectId))
              ..limit(1))
            .getSingleOrNull();
    if (target == null) {
      return;
    }
    final normalizedServerId = trimOrNull(target.serverId);
    await _database.transaction(() async {
      final update = _database.update(_database.projects);
      if (normalizedServerId != null) {
        update.where((table) => table.serverId.equals(normalizedServerId));
      }
      await update.write(ProjectsCompanion(isActive: const Value(false)));
      await (_database.update(
        _database.projects,
      )..where((table) => table.id.equals(projectId))).write(
        ProjectsCompanion(isActive: const Value(true), updatedAt: Value(now)),
      );
    });
  }
  // end coverage-gate

  // coverage-gate: update_runtime_state
  /// Records whether the project's app has been disconnected from its server.
  Future<void> updateRuntimeState({
    required String projectId,
    bool? appDisconnected,
  }) async {
    final now = DateTime.now();
    await (_database.update(
      _database.projects,
    )..where((table) => table.id.equals(projectId))).write(
      ProjectsCompanion(
        appDisconnected: appDisconnected == null
            ? const Value.absent()
            : Value(appDisconnected),
        updatedAt: Value(now),
      ),
    );
  }
  // end coverage-gate

  // coverage-gate: update_database_wiring
  /// Records whether managed PostgreSQL credentials are wired into this
  /// project.
  Future<void> updateDatabaseWiring({
    required String projectId,
    required bool injectPostgresEnv,
  }) async {
    final now = DateTime.now();
    await (_database.update(
      _database.projects,
    )..where((table) => table.id.equals(projectId))).write(
      ProjectsCompanion(
        injectPostgresEnv: Value(injectPostgresEnv),
        updatedAt: Value(now),
      ),
    );
  }
  // end coverage-gate

  // coverage-gate: delete_project_records
  /// Deletes a project and everything that references it, returning the id of
  /// whichever project is active afterwards.
  ///
  /// One transaction over twenty-odd tables, children before parents. Three
  /// parts are not mechanical:
  ///
  /// - Snapshot exports and database-access grants are deleted where this
  ///   project is on *either* side, because a shared database has two owners
  ///   and leaving the other half would orphan it.
  /// - A network group that drops below two members is deleted with its
  ///   remaining membership: a group of one connects nothing.
  /// - Activation is reassigned before returning, so deleting the active
  ///   project leaves the app pointing at a real one rather than at nothing.
  ///
  /// This removes only *local* records. Server-side cleanup is
  /// `ProjectDeletionCoordinator`'s job, and this should run after it reports
  /// completion.
  Future<String?> deleteProjectAndRelatedRecords(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return readActiveProjectId();
    }

    final deletedProject =
        await (_database.select(_database.projects)
              ..where((table) => table.id.equals(normalizedProjectId))
              ..limit(1))
            .getSingleOrNull();
    final deletedServerId = trimOrNull(deletedProject?.serverId);
    final now = DateTime.now();
    return _database.transaction(() async {
      await (_database.delete(
        _database.appEnvironmentVariables,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.appDeploymentHistory,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.appReleases,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.appRuntimeSnapshots,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.workerInstances,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.workerRuntimeSnapshots,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.schedulerTaskRuns,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.schedulerTasks,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.backupRuns,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.backupArtifacts,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.postgresBackupPolicies,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.backupDestinations,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projectManagedDatabaseUsers,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projectManagedDatabases,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projectWorkspaceImportStates,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projectManagedOperationJournal,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projectDeletionRecoveryStates,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(_database.projectSqliteSnapshotExports)
            ..where((table) {
              return table.ownerProjectId.equals(normalizedProjectId) |
                  table.consumerProjectId.equals(normalizedProjectId);
            }))
          .go();
      final networkMemberships = await (_database.select(
        _database.projectNetworkGroupMembers,
      )..where((table) => table.projectId.equals(normalizedProjectId))).get();
      final networkGroupIds = networkMemberships
          .map((membership) => membership.groupId)
          .toSet();
      await (_database.delete(
        _database.projectNetworkGroupMembers,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      for (final groupId in networkGroupIds) {
        final remainingMembers = await (_database.select(
          _database.projectNetworkGroupMembers,
        )..where((table) => table.groupId.equals(groupId))).get();
        if (remainingMembers.length >= 2) {
          continue;
        }
        await (_database.delete(
          _database.projectNetworkGroupMembers,
        )..where((table) => table.groupId.equals(groupId))).go();
        await (_database.delete(
          _database.projectNetworkGroups,
        )..where((table) => table.id.equals(groupId))).go();
      }
      final grantRows =
          await (_database.select(_database.projectDatabaseAccessGrants)
                ..where((table) {
                  return table.ownerProjectId.equals(normalizedProjectId) |
                      table.consumerProjectId.equals(normalizedProjectId);
                }))
              .get();
      final grantIds = grantRows
          .map((grant) => grant.id)
          .toList(growable: false);
      if (grantIds.isNotEmpty) {
        await (_database.delete(
          _database.projectDatabaseAccessUsers,
        )..where((table) => table.grantId.isIn(grantIds))).go();
      }
      await (_database.delete(_database.projectDatabaseAccessGrants)
            ..where((table) {
              return table.ownerProjectId.equals(normalizedProjectId) |
                  table.consumerProjectId.equals(normalizedProjectId);
            }))
          .go();
      await (_database.delete(
        _database.projectScreenVisits,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      await (_database.delete(
        _database.projects,
      )..where((table) => table.id.equals(normalizedProjectId))).go();

      final remainingQuery = _database.select(_database.projects)
        ..orderBy([(table) => OrderingTerm.asc(table.name)]);
      if (deletedServerId != null) {
        remainingQuery.where((table) => table.serverId.equals(deletedServerId));
      }
      final remainingRows = await remainingQuery.get();
      final pendingRows = await _database
          .select(_database.projectDeletionRecoveryStates)
          .get();
      final pendingProjectIds = pendingRows.map((row) => row.projectId).toSet();
      final remaining = remainingRows
          .where((row) => !pendingProjectIds.contains(row.id))
          .toList(growable: false);
      if (remaining.isEmpty) {
        return null;
      }

      String? firstActiveId;
      for (final project in remaining) {
        if (project.isActive) {
          firstActiveId = project.id;
          break;
        }
      }
      final nextActiveId = firstActiveId ?? remaining.first.id;

      final update = _database.update(_database.projects);
      if (deletedServerId != null) {
        update.where((table) => table.serverId.equals(deletedServerId));
      }
      await update.write(ProjectsCompanion(isActive: const Value(false)));
      await (_database.update(
        _database.projects,
      )..where((table) => table.id.equals(nextActiveId))).write(
        ProjectsCompanion(isActive: const Value(true), updatedAt: Value(now)),
      );
      return nextActiveId;
    });
  }
  // end coverage-gate

  Project _mapRow(ProjectRow row) {
    return Project(
      id: row.id,
      serverId: trimOrNull(row.serverId),
      name: row.name,
      type: row.type,
      gitUrl: row.gitUrl,
      primaryDomain: row.primaryDomain,
      domainRoutingMode: _normalizedDomainRoutingMode(row.domainRoutingMode),
      repositoryFullName: row.repositoryFullName,
      appSubdirectory: row.appSubdirectory,
      deployBranch: row.deployBranch,
      appPort: row.appPort,
      publicHealthCheckEnabled: row.publicHealthCheckEnabled,
      publicHealthCheckPath: _normalizedPublicHealthPath(
        row.publicHealthCheckPath,
      ),
      lastDeployCommit: row.lastDeployCommit,
      lastDeployedAt: row.lastDeployedAt,
      railpackBuildCommand: row.railpackBuildCommand,
      railpackRunCommand: row.railpackRunCommand,
      railpackProvider: normalizeRailpackProvider(row.railpackProvider),
      railpackNodeMode: row.railpackNodeMode,
      tlsChallengeMode: _normalizedTlsChallengeMode(row.tlsChallengeMode),
      tlsDnsProvider: _normalizedTlsDnsProvider(row.tlsDnsProvider),
      tlsDnsCredentials: _decodeTlsDnsCredentials(row.tlsDnsConfigJson),
      appDisconnected: row.appDisconnected,
      injectPostgresEnv: row.injectPostgresEnv,
      sqliteStorageEnabled: row.sqliteStorageEnabled,
      sqliteVolumeName: _normalizedSqliteVolumeName(row.sqliteVolumeName),
      sqliteMountPath: _normalizedSqliteMountPath(row.sqliteMountPath),
      sqliteFileName: _normalizedSqliteFileName(row.sqliteFileName),
      isActive: row.isActive,
    );
  }

  static String _normalizedBranch(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'main' : trimmed;
  }

  static int _normalizedPort(int value) {
    if (value < 1 || value > 65535) {
      return 3000;
    }
    return value;
  }

  static String _normalizedPublicHealthPath(String value) {
    final normalized = value.trim();
    return normalized.startsWith('/') ? normalized : '/';
  }

  static String _normalizedRailpackNodeMode(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'runtime') {
      return 'runtime';
    }
    return 'auto';
  }

  static String _normalizedCommand(String value) {
    return value.trim();
  }

  static String? _normalizedAppSubdirectory(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value
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
        return null;
      }
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join('/');
  }

  static String _normalizedTlsChallengeMode(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'dns' ? 'dns' : 'http';
  }

  static ({String primaryDomain, String domainRoutingMode})
  _normalizedDomainConfig({
    required String primaryDomain,
    required String domainRoutingMode,
  }) {
    final normalizedDomain = primaryDomain.trim().toLowerCase();
    final normalizedMode = _normalizedDomainRoutingMode(domainRoutingMode);
    if (normalizedMode == 'single_host') {
      return (
        primaryDomain: normalizedDomain,
        domainRoutingMode: normalizedMode,
      );
    }
    return (
      primaryDomain: _stripLeadingWww(normalizedDomain),
      domainRoutingMode: normalizedMode,
    );
  }

  static String _normalizedDomainRoutingMode(String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'redirect_www_to_apex' => 'redirect_www_to_apex',
      'redirect_apex_to_www' => 'redirect_apex_to_www',
      _ => 'single_host',
    };
  }

  static String _stripLeadingWww(String value) {
    if (value.startsWith('www.') && value.length > 4) {
      return value.substring(4);
    }
    return value;
  }

  static String? _normalizedSqliteVolumeName(String? value) {
    final normalized = trimOrNull(value);
    if (normalized == null) {
      return null;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static String? _normalizedSqliteMountPath(String? value) {
    final normalized = trimOrNull(value);
    if (normalized == null) {
      return null;
    }
    if (!normalized.startsWith('/')) {
      return null;
    }
    final parts = normalized.split('/');
    final cleaned = <String>[];
    for (final part in parts) {
      final segment = part.trim();
      if (segment.isEmpty) {
        continue;
      }
      if (segment == '.' || segment == '..') {
        return null;
      }
      cleaned.add(segment);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return '/${cleaned.join('/')}';
  }

  static String? _normalizedSqliteFileName(String? value) {
    final normalized = trimOrNull(value);
    if (normalized == null) {
      return null;
    }
    if (normalized.contains('/')) {
      return null;
    }
    if (normalized == '.' || normalized == '..') {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static String? _normalizedTlsDnsProvider(String? value) {
    if (value == null) {
      return null;
    }
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }
    const allowed = <String>{
      'cloudflare',
      'porkbun',
      'namecheap',
      'cloudns',
      'easydns',
    };
    if (!allowed.contains(normalized)) {
      return null;
    }
    return normalized;
  }

  static String? _encodeTlsDnsCredentials(Map<String, String> credentials) {
    if (credentials.isEmpty) {
      return null;
    }
    final normalized = <String, String>{};
    for (final entry in credentials.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) {
        continue;
      }
      normalized[key] = value;
    }
    if (normalized.isEmpty) {
      return null;
    }
    return jsonEncode(normalized);
  }

  static Map<String, String> _decodeTlsDnsCredentials(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const <String, String>{};
    }
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) {
        return const <String, String>{};
      }
      final normalized = <String, String>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString().trim().toLowerCase();
        final value = entry.value?.toString().trim() ?? '';
        if (key.isEmpty || value.isEmpty) {
          continue;
        }
        normalized[key] = value;
      }
      return normalized;
    } on FormatException {
      return const <String, String>{};
    }
  }
}

/// The app-wide project repository.
final projectRepositoryProvider = Provider<ProjectRepository>((ref) {
  final database = ref.watch(appDatabaseProvider);
  return ProjectRepository(database);
});
