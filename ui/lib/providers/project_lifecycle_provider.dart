import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'backup_provider.dart';
import 'project_deletion_provider.dart';
import 'project_provider.dart';
import 'recent_projects_provider.dart';
import 'scheduler_task_provider.dart';
import 'server_list_provider.dart';
import 'worker_instance_provider.dart';

final projectLifecycleActionsProvider = Provider<ProjectLifecycleActions>(
  ProjectLifecycleActions.new,
);

typedef ProjectInitialVisitWriter =
    Future<void> Function({
      required String projectId,
      required String destinationId,
    });

final projectInitialVisitWriterProvider = Provider<ProjectInitialVisitWriter>(
  (ref) => ({required projectId, required destinationId}) {
    return ref
        .read(recentProjectVisitsProvider.notifier)
        .recordVisit(projectId: projectId, destinationId: destinationId);
  },
);

/// Owns project persistence and cleanup workflows independently of ShellPage.
class ProjectLifecycleActions {
  ProjectLifecycleActions(this._ref);

  final Ref _ref;

  Project createProject({
    String? serverId,
    required String name,
    required String type,
    required String gitUrl,
    required String primaryDomain,
    String? railpackProvider,
    required String railpackBuildCommand,
    required String railpackRunCommand,
    required int appPort,
    required String initialDestinationId,
  }) {
    final project = _ref
        .read(projectListProvider.notifier)
        .addProject(
          serverId: serverId,
          name: name,
          type: type,
          gitUrl: gitUrl,
          primaryDomain: primaryDomain,
          railpackProvider: railpackProvider,
          railpackBuildCommand: railpackBuildCommand,
          railpackRunCommand: railpackRunCommand,
          appPort: appPort,
        );
    _ref.read(selectedProjectIdProvider.notifier).select(project.id);
    unawaited(
      _ref.read(projectInitialVisitWriterProvider)(
        projectId: project.id,
        destinationId: initialDestinationId,
      ),
    );
    return project;
  }

  void openProject({
    required String projectId,
    required String destinationId,
    required bool hasServers,
  }) {
    if (hasServers) {
      unawaited(
        _ref
            .read(serverCatalogProvider.notifier)
            .setOnboardingStep('connected'),
      );
    }
    // G-35: boot no longer selects a server, so a project opened from the
    // rail's recent list must select its own. Without this the workspace
    // falls back to `servers.first` and acts on the wrong server.
    final owningServerId = _ref
        .read(projectListProvider)
        .where((project) => project.id == projectId)
        .map((project) => project.serverId)
        .firstOrNull;
    if (owningServerId != null &&
        owningServerId != _ref.read(serverCatalogProvider).selectedServerId) {
      unawaited(
        _ref.read(serverCatalogProvider.notifier).selectServer(owningServerId),
      );
    }
    _ref.read(selectedProjectIdProvider.notifier).select(projectId);
    unawaited(
      _ref.read(projectInitialVisitWriterProvider)(
        projectId: projectId,
        destinationId: destinationId,
      ),
    );
  }

  Future<ProjectDeletionOutcome> retryProjectCleanup(
    ProjectDeletionRecoveryRecord recovery,
  ) async {
    final server = _ref
        .read(serverCatalogProvider)
        .servers
        .where((candidate) => candidate.id == recovery.serverId)
        .firstOrNull;
    final outcome = await _ref
        .read(projectDeletionCoordinatorProvider)
        .retry(recovery: recovery, server: server);
    _ref.invalidate(projectDeletionRecoveriesProvider);
    if (outcome.completed) {
      await _ref
          .read(projectListProvider.notifier)
          .deleteProject(recovery.projectId);
      forgetProjectState(recovery.projectId);
    }
    return outcome;
  }

  Future<ProjectDeletionOutcome> removePendingProjectLocalRecord(
    ProjectDeletionRecoveryRecord recovery,
  ) async {
    await _ref
        .read(projectListProvider.notifier)
        .deleteProject(recovery.projectId);
    _ref.invalidate(projectDeletionRecoveriesProvider);
    forgetProjectState(recovery.projectId);
    return ProjectDeletionOutcome(
      projectName: recovery.projectName,
      completed: true,
      messages: const [
        'The local project record was removed. Remote resources may still remain.',
      ],
    );
  }

  void forgetProjectState(String projectId) {
    _ref.read(projectWorkerInstancesProvider.notifier).forgetProject(projectId);
    _ref.read(projectSchedulerProvider.notifier).forgetProject(projectId);
    _ref.read(projectBackupProvider.notifier).forgetProject(projectId);
    _ref.read(selectedProjectIdProvider.notifier).clear();
  }
}
