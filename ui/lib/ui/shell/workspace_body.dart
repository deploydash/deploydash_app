/// The body the shell renders for the selected workspace.
///
/// Moved out of `main.dart` by T-3.2.5, which names this class specifically.
/// Public rather than private only because it now lives beside its caller
/// instead of inside the same file.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import '../../providers/pending_enrollment_provider.dart';
import '../../providers/project_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/project_deletion_provider.dart';
import '../../ui/layout/home_dashboard_view.dart';
import '../../ui/project/create_project_view.dart';
import '../../ui/project/project_workspace.dart';
import '../../ui/settings/app_settings_view.dart';
import '../../ui/server/server_management_view.dart';
import '../../ui/server/server_onboarding_view.dart';
import 'workspace_mode.dart';

class WorkspaceBody extends StatelessWidget {
  const WorkspaceBody({
    super.key,
    required this.mode,
    required this.hasServer,
    required this.selectedServer,
    required this.chosenServer,
    required this.homeProjects,
    required this.servers,
    required this.projects,
    required this.serverCount,
    required this.serverManagementInitialTabIndex,
    required this.projectInitialTabIndex,
    required this.isServerLoading,
    required this.onboardingStep,
    required this.pendingSetupServerIds,
    required this.setupRetryServerId,
    this.pendingEnrollment,
    required this.showFirstRunWizard,
    required this.onRetryServerSetup,
    required this.onCancelCreate,
    required this.onCreateProject,
    required this.onSavePendingServer,
    required this.onUpdatePendingServer,
    required this.onAdoptManagedIdentity,
    required this.onCompleteServiceSelection,
    required this.onOpenProject,
    required this.onSelectServer,
    required this.onOpenCreateProject,
    required this.onOpenAddServer,
    required this.onOpenServerManagement,
    required this.onOpenServerServices,
    required this.appSettingsInitialDestinationId,
    required this.onProjectDestinationSelected,
    required this.onServerManagementDestinationSelected,
    required this.onAppSettingsDestinationSelected,
    required this.deletedProjectNotice,
    required this.projectDeletionRecoveries,
    required this.onDismissDeletedProjectNotice,
    required this.onRetryProjectCleanup,
    required this.onRemovePendingProjectLocalRecord,
    required this.onProjectDeleted,
    required this.onRemoveSelectedServer,
    required this.onTerminalLine,
    this.telemetryNagVisible = false,
    this.onShareTelemetryNag,
    this.onDismissTelemetryNag,
  });

  final WorkspaceMode mode;
  final bool hasServer;
  final Server? selectedServer;

  /// The server the user explicitly chose, or null if they have not chosen one
  /// this session. Distinct from [selectedServer], which always resolves to a
  /// server to act on. G-35.
  final Server? chosenServer;

  /// Projects on [chosenServer]; empty when nothing is chosen. Distinct from
  /// [projects], which drives the Home-versus-workspace branch below.
  final List<Project> homeProjects;
  final List<Server> servers;
  final List<Project> projects;
  final int serverCount;
  final int serverManagementInitialTabIndex;
  final int projectInitialTabIndex;
  final bool isServerLoading;
  final String? onboardingStep;

  /// Ids of servers saved before provisioning finished, rendered with
  /// retry-only affordances wherever servers appear.
  final Set<String> pendingSetupServerIds;

  /// Retries setup for this server when the add-server wizard opens.
  final String? setupRetryServerId;

  /// Resumes the first-run wizard with a confirmation-green server that
  /// enrolled before the save. Null in every other opening.
  final PendingEnrollment? pendingEnrollment;

  /// Whether the shell holds the first-run wizard up: a fresh launch
  /// with no servers, or a fresh enrollment whose first setup is still
  /// pending. Computed by the shell, which owns the route; the body
  /// only renders it, so an explicit add-server opening (which shares
  /// the mode) never lands on the first-run wizard by mistake.
  final bool showFirstRunWizard;

  /// Retries setup for an incomplete server id.
  final ValueChanged<String> onRetryServerSetup;
  final VoidCallback onCancelCreate;
  final ValueChanged<CreateProjectRequest> onCreateProject;
  final Future<Server> Function(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
  )
  onSavePendingServer;
  final Future<Server> Function({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  })
  onUpdatePendingServer;
  final Future<void> Function({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  })
  onAdoptManagedIdentity;
  final Future<void> Function({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  })
  onCompleteServiceSelection;
  final ValueChanged<String> onOpenProject;
  final ValueChanged<String> onSelectServer;
  final VoidCallback onOpenCreateProject;
  final VoidCallback onOpenAddServer;
  final VoidCallback onOpenServerManagement;
  final VoidCallback onOpenServerServices;
  final String appSettingsInitialDestinationId;
  final ValueChanged<String> onProjectDestinationSelected;
  final ValueChanged<int> onServerManagementDestinationSelected;
  final ValueChanged<String> onAppSettingsDestinationSelected;
  final DeletedProjectNotice? deletedProjectNotice;
  final List<ProjectDeletionRecoveryRecord> projectDeletionRecoveries;
  final VoidCallback onDismissDeletedProjectNotice;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)
  onRetryProjectCleanup;
  final Future<void> Function(ProjectDeletionRecoveryRecord recovery)
  onRemovePendingProjectLocalRecord;
  final ValueChanged<ProjectDeletionOutcome> onProjectDeleted;
  final Future<void> Function() onRemoveSelectedServer;
  final void Function(
    String line, {
    String source,
    String? taskType,
    bool detail,
  })
  onTerminalLine;

  /// Whether the once-ever telemetry nag renders above Home.
  final bool telemetryNagVisible;

  /// Switches reporting back on. Null while the nag is hidden.
  final VoidCallback? onShareTelemetryNag;

  /// Records the nag as shown without switching on. Null while hidden.
  final VoidCallback? onDismissTelemetryNag;

  @override
  Widget build(BuildContext context) {
    final showFirstRunWizard =
        this.showFirstRunWizard && mode != WorkspaceMode.home;
    // Loading windows (the early save's own flip, a reload) must not
    // unmount a held-up first-run wizard: it remounts blank and saves
    // the server a second time.
    if (isServerLoading && !showFirstRunWizard) {
      return const Center(child: CircularProgressIndicator());
    }

    if (mode == WorkspaceMode.appSettings) {
      return AppSettingsView(
        initialDestinationId: appSettingsInitialDestinationId,
        onDestinationSelected: onAppSettingsDestinationSelected,
      );
    }

    if (mode == WorkspaceMode.unlock) {
      return const Center(
        child: Text('Deploy Dash is already unlocked in this session.'),
      );
    }

    if (showFirstRunWizard) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: ServerOnboardingView(
          key: const Key('server-onboarding-first-run'),
          firstRun: true,
          pendingEnrollment: pendingEnrollment,
          onSavePendingServer: onSavePendingServer,
          onUpdatePendingServer: onUpdatePendingServer,
          onAdoptManagedIdentity: onAdoptManagedIdentity,
        ),
      );
    }

    if (mode == WorkspaceMode.addServer) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: ServerOnboardingView(
          key: const Key('server-onboarding-additional'),
          firstRun: false,
          initialStep: onboardingStep == 'services_selection'
              ? 'services_selection'
              : null,
          retryServerId: setupRetryServerId,
          onSavePendingServer: onSavePendingServer,
          onUpdatePendingServer: onUpdatePendingServer,
          onAdoptManagedIdentity: onAdoptManagedIdentity,
          onCompleteServiceSelection: onCompleteServiceSelection,
        ),
      );
    }

    if (mode == WorkspaceMode.serverManagement) {
      final managedServer = selectedServer;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: ServerManagementView(
          server: managedServer,
          initialTabIndex: serverManagementInitialTabIndex,
          isSetupPending:
              managedServer != null &&
              pendingSetupServerIds.contains(managedServer.id),
          onDestinationSelected: onServerManagementDestinationSelected,
          onTerminalLine: onTerminalLine,
          onRemoveServer: onRemoveSelectedServer,
          onRetrySetup: managedServer == null
              ? null
              : () => onRetryServerSetup(managedServer.id),
        ),
      );
    }

    if (mode == WorkspaceMode.project &&
        onboardingStep == 'services_selection') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: ServerOnboardingView(
          key: const Key('server-onboarding-services-selection'),
          firstRun: false,
          initialStep: 'services_selection',
          onSavePendingServer: onSavePendingServer,
          onUpdatePendingServer: onUpdatePendingServer,
          onAdoptManagedIdentity: onAdoptManagedIdentity,
          onCompleteServiceSelection: onCompleteServiceSelection,
        ),
      );
    }

    if (mode == WorkspaceMode.createProject) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: CreateProjectView(
          onCancel: onCancelCreate,
          onCreate: onCreateProject,
        ),
      );
    }

    if (onboardingStep == 'services_selection') {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: ServerOnboardingView(
          key: const Key('server-onboarding-services-selection'),
          firstRun: false,
          initialStep: 'services_selection',
          onSavePendingServer: onSavePendingServer,
          onUpdatePendingServer: onUpdatePendingServer,
          onAdoptManagedIdentity: onAdoptManagedIdentity,
          onCompleteServiceSelection: onCompleteServiceSelection,
        ),
      );
    }

    if (mode == WorkspaceMode.home || projects.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0),
        child: HomeDashboardView(
          projects: homeProjects,
          servers: servers,
          selectedServer: chosenServer,
          serverCount: serverCount,
          deletedProjectNotice: deletedProjectNotice,
          projectDeletionRecoveries: projectDeletionRecoveries,
          pendingSetupServerIds: pendingSetupServerIds,
          onDismissDeletedProjectNotice: onDismissDeletedProjectNotice,
          onRetryProjectCleanup: onRetryProjectCleanup,
          onRemovePendingProjectLocalRecord: onRemovePendingProjectLocalRecord,
          onOpenProject: onOpenProject,
          onSelectServer: onSelectServer,
          onRetryServerSetup: onRetryServerSetup,
          onCreateProject: onOpenCreateProject,
          onAddServer: onOpenAddServer,
          onOpenServerManagement: onOpenServerManagement,
          telemetryNagVisible: telemetryNagVisible,
          onShareTelemetryNag: onShareTelemetryNag,
          onDismissTelemetryNag: onDismissTelemetryNag,
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24.0),
      child: ProjectWorkspace(
        initialTabIndex: projectInitialTabIndex,
        onDestinationSelected: onProjectDestinationSelected,
        onOpenServerServices: onOpenServerServices,
        onProjectDeleted: onProjectDeleted,
        onTerminalLine: onTerminalLine,
      ),
    );
  }
}
