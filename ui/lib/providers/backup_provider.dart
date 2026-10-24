import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/backup_repository.dart';
import '../domain/project.dart';
import '../models/result.dart';
import '../models/workspace_scope.dart';
import '../services/backup_logic.dart';
import '../services/project_database_settings.dart';
import 'server_provider.dart';

export '../data/local/backup_repository.dart';

class ProjectBackupScopeState {
  const ProjectBackupScopeState({
    this.destinations = const <BackupDestinationRecord>[],
    this.policies = const <BackupPolicyRecord>[],
    this.artifacts = const <BackupArtifactRecord>[],
    this.runs = const <BackupRunRecord>[],
  });

  final List<BackupDestinationRecord> destinations;
  final List<BackupPolicyRecord> policies;
  final List<BackupArtifactRecord> artifacts;
  final List<BackupRunRecord> runs;

  ProjectBackupScopeState copyWith({
    List<BackupDestinationRecord>? destinations,
    List<BackupPolicyRecord>? policies,
    List<BackupArtifactRecord>? artifacts,
    List<BackupRunRecord>? runs,
  }) {
    return ProjectBackupScopeState(
      destinations: destinations ?? this.destinations,
      policies: policies ?? this.policies,
      artifacts: artifacts ?? this.artifacts,
      runs: runs ?? this.runs,
    );
  }
}

class ProjectBackupState {
  const ProjectBackupState({
    this.scopes = const <String, ProjectBackupScopeState>{},
  });

  final Map<String, ProjectBackupScopeState> scopes;

  ProjectBackupScopeState scopeFor({
    required String projectId,
    required String serverId,
  }) {
    final key = _scopeKey(projectId: projectId, serverId: serverId);
    if (key == null) {
      return const ProjectBackupScopeState();
    }
    return scopes[key] ?? const ProjectBackupScopeState();
  }

  ProjectBackupState copyWith({Map<String, ProjectBackupScopeState>? scopes}) {
    return ProjectBackupState(scopes: scopes ?? this.scopes);
  }

  static String? _scopeKey({
    required String projectId,
    required String serverId,
  }) {
    return WorkspaceScope.fromIds(
      projectId: projectId,
      serverId: serverId,
    )?.cacheKey;
  }
}

class ProjectBackupNotifier extends Notifier<ProjectBackupState> {
  @override
  ProjectBackupState build() => const ProjectBackupState();

  Future<void> loadScope({
    required String projectId,
    required String serverId,
  }) async {
    final scopeKey = ProjectBackupState._scopeKey(
      projectId: projectId,
      serverId: serverId,
    );
    if (scopeKey == null) {
      return;
    }
    final repository = ref.read(backupRepositoryProvider);
    final destinations = await repository.listDestinationsForScope(
      projectId: projectId,
      serverId: serverId,
    );
    final policies = await repository.listPoliciesForScope(
      projectId: projectId,
      serverId: serverId,
    );
    final artifacts = await repository.listArtifactsForScope(
      projectId: projectId,
      serverId: serverId,
    );
    final runs = await repository.listRunsForScope(
      projectId: projectId,
      serverId: serverId,
    );
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      scopes: {
        ...state.scopes,
        scopeKey: ProjectBackupScopeState(
          destinations: destinations,
          policies: policies,
          artifacts: artifacts,
          runs: runs,
        ),
      },
    );
  }

  Future<void> upsertDestination(BackupDestinationRecord destination) async {
    await ref.read(backupRepositoryProvider).upsertDestination(destination);
    await loadScope(
      projectId: destination.projectId,
      serverId: destination.serverId,
    );
  }

  Future<void> deleteDestination({
    required String id,
    required String projectId,
    required String serverId,
  }) async {
    await ref
        .read(backupRepositoryProvider)
        .deleteDestination(id: id, projectId: projectId, serverId: serverId);
    await loadScope(projectId: projectId, serverId: serverId);
  }

  Future<void> upsertPolicy(BackupPolicyRecord policy) async {
    await ref.read(backupRepositoryProvider).upsertPolicy(policy);
    await loadScope(projectId: policy.projectId, serverId: policy.serverId);
  }

  Future<void> deletePolicy({
    BackupEngine engine = BackupEngine.postgres,
    required String id,
    required String projectId,
    required String serverId,
  }) async {
    await ref
        .read(backupRepositoryProvider)
        .deletePolicy(
          engine: engine,
          id: id,
          projectId: projectId,
          serverId: serverId,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }

  // coverage-gate: backup_service_policy_cache_cleanup
  /// Purges deleted service plans and evicts only that server's cached scopes.
  Future<void> deletePoliciesForServer(String serverId) async {
    final normalizedServerId = serverId.trim();
    if (normalizedServerId.isEmpty) {
      return;
    }
    await ref
        .read(backupRepositoryProvider)
        .deletePoliciesForServer(normalizedServerId);
    if (!ref.mounted) {
      return;
    }
    final suffix = '::$normalizedServerId';
    state = state.copyWith(
      scopes: {
        for (final entry in state.scopes.entries)
          if (!entry.key.endsWith(suffix)) entry.key: entry.value,
      },
    );
  }
  // end coverage-gate

  Future<void> replaceArtifactsForPolicy({
    BackupEngine engine = BackupEngine.postgres,
    required String policyId,
    required String projectId,
    required String serverId,
    required List<BackupArtifactRecord> artifacts,
  }) async {
    await ref
        .read(backupRepositoryProvider)
        .replaceArtifactsForPolicy(
          engine: engine,
          policyId: policyId,
          projectId: projectId,
          serverId: serverId,
          artifacts: artifacts,
        );
    await loadScope(projectId: projectId, serverId: serverId);
  }

  /// Lists the newest backup artifacts for every policy in a scope and
  /// replaces the stored set for each.
  ///
  /// **Returns** a message on failure rather than throwing, because its
  /// callers disagree about what a failure means: the pending-import flow
  /// aborts its transaction, while the backup screen must stay usable and
  /// keep showing the artifacts it already has. A shared helper that threw
  /// would force the screen to catch and swallow. G-42.
  ///
  /// Returns null when there was nothing to refresh or everything succeeded.
  Future<String?> refreshArtifactsForScope({
    required Project project,
    required Server server,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final connection = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null || !server.serviceDatabaseEnabled) {
      return null;
    }

    await loadScope(projectId: project.id, serverId: server.id);
    final scope = state.scopeFor(projectId: project.id, serverId: server.id);
    if (scope.policies.isEmpty) {
      return null;
    }
    final destinationsById = {
      for (final destination in scope.destinations) destination.id: destination,
    };

    for (final policy in scope.policies) {
      final destination = destinationsById[policy.destinationId];
      if (destination == null || policy.engine != BackupEngine.postgres) {
        continue;
      }
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'postgres',
                    operationId: 'backup_artifact_list',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'settings': <String, dynamic>{
                        ...buildBackupBasePostgresSettings(
                          projectName: project.name,
                          server: server,
                        ),
                        ...buildBackupDestinationSettings(
                          engine: BackupWorkspaceEngineChoice.postgres,
                          destinationType: destination.type,
                          destinationConfig: destination.config,
                        ),
                        'backup_policy_id': policy.id,
                        'backup_policy_name': policy.name,
                        'backup_task_id': policy.managedTaskId,
                        'backup_database_name': logicalManagedPostgresName(
                          projectName: project.name,
                          remoteName: policy.databaseName,
                        ),
                      },
                    },
                    onEvent: onEvent,
                  ))
              .diagnosticPayload;
      if (isBackupArtifactRefreshDuplicate(response)) {
        // The identical listing is still queued or running; there is no
        // artifact list in this answer, so report the wait rather than the
        // generic missing-list message below.
        return backupArtifactRefreshDuplicateMessage();
      }
      if (response['status'] != 'success') {
        return response['msg']?.toString() ??
            'Could not import backup artifacts.';
      }
      final artifactsPayload = response['artifacts'];
      if (artifactsPayload is! List) {
        // A success with no artifact list is not the same as "there are none".
        // Replacing on this would delete every stored artifact for the policy
        // on a malformed or partial response, which is unrecoverable from the
        // app. Leave what is stored and report it. G-42.
        return 'The server did not return a backup list for '
            '"${policy.name}".';
      }
      await replaceArtifactsForPolicy(
        engine: policy.engine,
        policyId: policy.id,
        projectId: project.id,
        serverId: server.id,
        artifacts: backupArtifactsFromBackendPayload(
          artifactsPayload: artifactsPayload,
          policy: policy,
          destination: destination,
        ),
      );
      if (!ref.mounted) {
        return null;
      }
    }
    return null;
  }

  Future<void> appendRun(BackupRunRecord run) async {
    await ref.read(backupRepositoryProvider).appendRun(run);
    await loadScope(projectId: run.projectId, serverId: run.serverId);
  }

  void forgetProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final prefix = '$normalizedProjectId::';
    final nextScopes = <String, ProjectBackupScopeState>{};
    for (final entry in state.scopes.entries) {
      if (entry.key.startsWith(prefix)) {
        continue;
      }
      nextScopes[entry.key] = entry.value;
    }
    if (nextScopes.length == state.scopes.length) {
      return;
    }
    state = state.copyWith(scopes: nextScopes);
  }
}

final projectBackupProvider =
    NotifierProvider<ProjectBackupNotifier, ProjectBackupState>(
      ProjectBackupNotifier.new,
    );
