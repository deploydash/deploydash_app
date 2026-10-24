/// The application shell: the frame every route renders inside.
///
/// Moved out of `main.dart` by T-3.2.5, which is the acceptance test for the
/// navigation group: with the domain workflows already lifted out by T-3.2.2,
/// T-3.2.3 and T-3.2.6, what was left in `main.dart` was 575 lines of shell
/// state and 227 of layout, neither of which is bootstrap.
///
/// `main.dart` keeps `main()`, the provider scope, and `runApp`.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yaru/yaru.dart';
import '../../providers/telemetry_settings_provider.dart';
import '../../providers/github_integration_provider.dart';
import '../../providers/desktop_startup_provider.dart';
import '../../providers/project_provider.dart';
import '../../providers/recent_projects_provider.dart';
import '../../providers/server_list_provider.dart';
import '../../providers/pending_enrollment_provider.dart';
import '../../providers/server_onboarding_provider.dart';
import '../../providers/server_provider.dart';
import '../../providers/server_terminal_transcript.dart' as server_transcript;
import '../../providers/shell_terminal_provider.dart';
import '../../services/desktop_update_service.dart';
import '../../providers/agent_access_service.dart';
import '../../services/app_analytics_service.dart';
import '../../providers/project_deletion_provider.dart';
import '../../providers/project_lifecycle_provider.dart';
import '../../services/ssh_service.dart';
import '../../utils/host_format.dart';
import '../../ui/layout/main_layout.dart';
import '../../ui/layout/home_dashboard_view.dart';
import '../../ui/navigation/desktop_route.dart';
import '../../ui/project/create_project_view.dart';
import '../../ui/project/workspace/shell/project_destinations.dart';
import '../../ui/shell/shell_navigation_rail.dart';
import '../../ui/shell/terminal/shell_terminal_panel.dart';
import '../../ui/terminal/github_deployment_transcript.dart'
    as github_transcript;
import 'workspace_body.dart';
import 'workspace_mode.dart';

String formatConnectedServerTerminalMessage(Server savedServer) {
  return '[server] Added "${savedServer.name}" '
      '(${formatHostPort(savedServer.host, savedServer.port)})';
}

String formatGitHubDeploySummaryTerminalMessage(GitHubIntegrationState state) {
  return github_transcript.formatGitHubDeploySummaryTerminalMessage(state);
}

String formatServerVerificationSummaryTerminalMessage(
  ServerState state, {
  required bool succeeded,
}) {
  return server_transcript.serverVerificationSummaryTerminalMessage(
    state,
    succeeded: succeeded,
  );
}

class ShellPage extends ConsumerStatefulWidget {
  const ShellPage({super.key, this.route = const DesktopRoute.home()});

  final DesktopRoute route;

  @override
  ConsumerState<ShellPage> createState() => _ShellPageState();
}

// coverage-gate: shell_state_initialization
class _ShellPageState extends ConsumerState<ShellPage> {
  DesktopRoute? _testRouteOverride;
  var _hasLeftInitialHomeRoute = false;
  DeletedProjectNotice? _deletedProjectNotice;
  Timer? _pythonWarmupTimer;

  /// Retries setup for this early-saved server when the onboarding route
  /// opens. Set by the retry entries, cleared by any other navigation.
  String? _setupRetryServerId;
  late final SSHService _sshService;

  @override
  void initState() {
    super.initState();
    _sshService = ref.read(sshServiceProvider);
    unawaited(ref.read(agentAccessServiceProvider).initialize());
    final terminal = ref.read(shellTerminalControllerProvider);
    terminal.updateContext(
      isOnboarding: widget.route.kind == DesktopRouteKind.onboarding,
    );
    terminal.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyRouteSideEffects(widget.route);
      _pythonWarmupTimer = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) {
          return;
        }
        unawaited(
          ref.read(desktopStartupActionsProvider).preloadPythonRuntime(),
        );
      });
      if (desktopDistribution != 'development') {
        unawaited(
          ref.read(desktopStartupActionsProvider).checkForDesktopUpdates(),
        );
      }
      unawaited(
        ref.read(desktopStartupActionsProvider).hydrateAnalyticsContext(),
      );
      unawaited(ref.read(telemetrySettingsProvider.notifier).load());
      unawaited(ref.read(desktopStartupActionsProvider).syncTelemetryEnabled());
    });
  }
  // end coverage-gate

  @override
  void didUpdateWidget(covariant ShellPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route == widget.route) {
      return;
    }
    ref
        .read(shellTerminalControllerProvider)
        .updateContext(
          isOnboarding: widget.route.kind == DesktopRouteKind.onboarding,
        );
    if (oldWidget.route.kind == DesktopRouteKind.onboarding &&
        widget.route.kind == DesktopRouteKind.home) {
      _hasLeftInitialHomeRoute = true;
    }
    _testRouteOverride = null;
    if (oldWidget.route.projectId != widget.route.projectId) {
      _applyRouteSideEffects(widget.route);
    } else if (widget.route.kind == DesktopRouteKind.project) {
      _recordProjectRouteVisit(widget.route);
    }
  }

  DesktopRoute get _activeRoute => _testRouteOverride ?? widget.route;

  void _navigateTo(DesktopRoute route) {
    if (route.kind != DesktopRouteKind.onboarding &&
        _setupRetryServerId != null) {
      setState(() => _setupRetryServerId = null);
    }
    ref
        .read(shellTerminalControllerProvider)
        .updateContext(isOnboarding: route.kind == DesktopRouteKind.onboarding);
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go(route.location);
      return;
    }
    setState(() => _testRouteOverride = route);
    _applyRouteSideEffects(route);
  }

  void _clearDeletedProjectNotice() {
    if (_deletedProjectNotice == null) {
      return;
    }
    setState(() => _deletedProjectNotice = null);
  }

  void _applyRouteSideEffects(DesktopRoute route) {
    final projectId = route.projectId;
    if (route.kind != DesktopRouteKind.project || projectId == null) {
      return;
    }
    if (ref.read(selectedProjectIdProvider) == projectId) {
      _recordProjectRouteVisit(route);
      return;
    }
    ref
        .read(projectLifecycleActionsProvider)
        .openProject(
          projectId: projectId,
          destinationId:
              route.projectDestinationId ?? defaultProjectDestinationId,
          hasServers: ref.read(serverCatalogProvider).hasServers,
        );
  }

  void _recordProjectRouteVisit(DesktopRoute route) {
    final projectId = route.projectId;
    if (projectId == null || route.kind != DesktopRouteKind.project) {
      return;
    }
    unawaited(
      ref.read(projectInitialVisitWriterProvider)(
        projectId: projectId,
        destinationId:
            route.projectDestinationId ?? defaultProjectDestinationId,
      ),
    );
  }

  @override
  void dispose() {
    _pythonWarmupTimer?.cancel();
    _sshService.cancelAllActiveTasksSync();
    super.dispose();
  }

  void _handleRetryServerSetup(String serverId) {
    ref.read(appAnalyticsServiceProvider).trackSetupResumed();
    unawaited(ref.read(serverCatalogProvider.notifier).selectServer(serverId));
    setState(() => _setupRetryServerId = serverId);
    _navigateTo(const DesktopRoute.onboarding());
  }

  void _handleCreateProject(CreateProjectRequest request) {
    final targetServerId = ref.read(selectedServerIdProvider);
    if (targetServerId != null &&
        ref.read(serverCatalogProvider).isServerSetupPending(targetServerId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Finish setting up this server before creating a project.',
          ),
        ),
      );
      return;
    }
    final newProject = ref
        .read(projectLifecycleActionsProvider)
        .createProject(
          serverId: targetServerId,
          name: request.name,
          type: request.type,
          gitUrl: request.gitUrl,
          primaryDomain: request.primaryDomain,
          railpackProvider: request.railpackProvider,
          railpackBuildCommand: request.railpackBuildCommand,
          railpackRunCommand: request.railpackRunCommand,
          appPort: request.appPort,
          initialDestinationId: projectWorkspaceDestinations[0].id,
        );

    _clearDeletedProjectNotice();
    _navigateTo(
      DesktopRoute.project(
        projectId: newProject.id,
        destinationId: defaultProjectDestinationId,
      ),
    );
    ref
        .read(shellTerminalControllerProvider)
        .writeLine(
          '[project] Created "${newProject.name}" (${_displayProjectType(newProject.type)}) for ${newProject.primaryDomain}',
          source: 'ui',
          taskType: 'project',
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Created project "${newProject.name}" for ${newProject.primaryDomain}',
        ),
      ),
    );
  }

  void _handleProjectDeleted(ProjectDeletionOutcome outcome) {
    setState(() {
      _deletedProjectNotice = DeletedProjectNotice(
        projectName: outcome.projectName,
        warnings: outcome.messages,
        completed: outcome.completed,
      );
    });
    _navigateTo(const DesktopRoute.home());
  }

  Future<void> _retryProjectCleanup(
    ProjectDeletionRecoveryRecord recovery,
  ) async {
    final outcome = await ref
        .read(projectLifecycleActionsProvider)
        .retryProjectCleanup(recovery);
    if (!mounted) {
      return;
    }
    _handleProjectDeleted(outcome);
  }

  Future<void> _removePendingProjectLocalRecord(
    ProjectDeletionRecoveryRecord recovery,
  ) async {
    final outcome = await ref
        .read(projectLifecycleActionsProvider)
        .removePendingProjectLocalRecord(recovery);
    if (!mounted) {
      return;
    }
    _handleProjectDeleted(outcome);
  }

  Future<Server> _handleSavePendingServer(
    ServerDraft draft,
    Map<String, dynamic> checkResult,
  ) {
    return ref
        .read(serverOnboardingActionsProvider)
        .savePendingServer(draft: draft, checkResult: checkResult);
  }

  Future<Server> _handleUpdatePendingServer({
    required String serverId,
    required ServerDraft draft,
    required Map<String, dynamic> checkResult,
  }) {
    return ref
        .read(serverOnboardingActionsProvider)
        .updatePendingServer(
          serverId: serverId,
          draft: draft,
          checkResult: checkResult,
        );
  }

  Future<void> _handleAdoptManagedIdentity({
    required String serverId,
    required String sshUser,
    required ServerAuthMethod authMethod,
    String? privateKey,
    String? publicKey,
    String? managedUserPassword,
  }) async {
    final adoptedServer = await ref
        .read(serverOnboardingActionsProvider)
        .completeManagedHandoff(
          serverId: serverId,
          sshUser: sshUser,
          authMethod: authMethod,
          privateKey: privateKey,
          publicKey: publicKey,
          managedUserPassword: managedUserPassword,
        );

    if (!mounted) {
      return;
    }

    final terminalMessage = formatConnectedServerTerminalMessage(
      adoptedServer,
    ); // coverage:ignore-line
    ref
        .read(shellTerminalControllerProvider)
        .writeLine(terminalMessage, source: 'ui', taskType: 'setup');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Connected server "${adoptedServer.name}"')),
    );
  }

  Future<void> _handleRemoveSelectedServer() async {
    final removedName = await ref
        .read(serverOnboardingActionsProvider)
        .removeSelectedServer();
    if (!mounted || removedName == null) {
      return;
    }
    _clearDeletedProjectNotice();
    _navigateTo(const DesktopRoute.home());
    ref
        .read(shellTerminalControllerProvider)
        .writeLine(
          '[ui] Removed server "$removedName" from Deploy Dash.',
          source: 'ui',
          taskType: 'setup',
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed server "$removedName" from Deploy Dash')),
    );
  }

  Future<void> _completeServiceSelectionStep({
    required bool enableEmailAccounts,
    required bool enableDomains,
    required bool enableDatabases,
    required String postgresVersion,
    required List<String> postgresExtensions,
  }) async {
    await ref
        .read(serverOnboardingActionsProvider)
        .completeServiceSelection(
          enableEmailAccounts: enableEmailAccounts,
          enableDomains: enableDomains,
          enableDatabases: enableDatabases,
          postgresVersion: postgresVersion,
          postgresExtensions: postgresExtensions,
          onEvent: (event) {
            ref
                .read(shellTerminalControllerProvider)
                .writeLine(
                  event.message,
                  source: event.source,
                  taskType: 'setup',
                  detail: event.detail,
                );
          },
        );
    if (!mounted) {
      return;
    }
    _clearDeletedProjectNotice();
    _navigateTo(const DesktopRoute.serverManagement());
    ref
        .read(shellTerminalControllerProvider)
        .writeLine(
          '[ui] Completed service selection. Opening server management.',
          source: 'ui',
          taskType: 'setup',
        );
  }

  @override
  Widget build(BuildContext context) {
    final allProjects = ref.watch(projectListProvider);
    final serverCatalog = ref.watch(serverCatalogProvider);
    final projectDeletionRecoveries =
        ref.watch(projectDeletionRecoveriesProvider).value ?? const [];
    final selectedServer = serverCatalog.selectedServer;
    // Hoisted so the `!= null` check promotes it; a public final field on the
    // state object is never promoted.
    final serverCatalogError = serverCatalog.error;
    final projects = _projectsForSelectedServer(
      allProjects,
      selectedServer?.id,
    );
    // G-35: Home shows what the user chose, which is nothing until they
    // choose. `selectedServer` and `projects` above keep resolving a server to
    // act on, because `_WorkspaceBody` uses `projects.isEmpty` to decide
    // between Home and the project workspace.
    final chosenServerId = serverCatalog.selectedServerId;
    final chosenServer = chosenServerId == null
        ? null
        : serverCatalog.servers
              .where((server) => server.id == chosenServerId)
              .firstOrNull;
    final homeProjects = chosenServerId == null
        ? const <Project>[]
        : _projectsForSelectedServer(allProjects, chosenServerId);
    final selectedProject = ref.watch(selectedProjectProvider);

    final hasServers = serverCatalog.hasServers;
    final isServerLoading = serverCatalog.isLoading;
    final pendingEnrollment = ref.watch(pendingEnrollmentProvider);
    final freshEnrollmentSession = ref.watch(freshEnrollmentSessionProvider);
    final telemetryNag = ref.watch(
      telemetrySettingsProvider.select((settings) => settings.homeNag),
    );
    final route = _activeRoute;
    final terminal = ref.read(shellTerminalControllerProvider);
    terminal.updateContext(
      isOnboarding: route.kind == DesktopRouteKind.onboarding,
    );
    // A fresh enrollment's first setup keeps the wizard past the early
    // save: the save flips hasServers while provisioning still runs, and
    // without this the shell drops the wizard to Home mid-setup. Scoped
    // to fresh enrollments so older incomplete servers still land on
    // Home with retry.
    final firstSetupStillPending =
        serverCatalog.servers.length == 1 &&
        serverCatalog.isServerSetupPending(serverCatalog.servers.first.id);
    final showFirstRunOnboarding =
        (!hasServers || (freshEnrollmentSession && firstSetupStillPending)) &&
        route.kind == DesktopRouteKind.home &&
        _testRouteOverride == null &&
        !_hasLeftInitialHomeRoute;
    final workspaceMode = switch (route.kind) {
      DesktopRouteKind.home =>
        showFirstRunOnboarding ? WorkspaceMode.addServer : WorkspaceMode.home,
      DesktopRouteKind.project => WorkspaceMode.project,
      DesktopRouteKind.createProject => WorkspaceMode.createProject,
      DesktopRouteKind.onboarding => WorkspaceMode.addServer,
      DesktopRouteKind.serverManagement => WorkspaceMode.serverManagement,
      DesktopRouteKind.appSettings => WorkspaceMode.appSettings,
      DesktopRouteKind.unlock => WorkspaceMode.unlock,
    };
    final isCreateMode = workspaceMode == WorkspaceMode.createProject;
    final isHomeMode = workspaceMode == WorkspaceMode.home;
    final isAddServerMode = workspaceMode == WorkspaceMode.addServer;
    final isServerManagementMode =
        workspaceMode == WorkspaceMode.serverManagement;
    final isAppSettingsMode = workspaceMode == WorkspaceMode.appSettings;
    final isUnlockMode = workspaceMode == WorkspaceMode.unlock;

    final title = isServerLoading
        ? 'Loading servers'
        : isHomeMode
        ? 'Home'
        : isAppSettingsMode
        ? 'App Settings'
        : isUnlockMode
        ? 'Unlock Deploy Dash'
        : !hasServers
        ? 'Connect your first server'
        : isAddServerMode
        ? 'Add server'
        : isServerManagementMode
        ? 'Server: ${selectedServer?.name ?? 'Unknown'}'
        : isCreateMode
        ? 'Create new project'
        : selectedProject == null
        ? 'Project workspace'
        : 'Project: ${selectedProject.name}';
    final headerSubtitle = isHomeMode
        ? null
        : isAppSettingsMode
        ? 'Application-wide preferences and security'
        : isServerManagementMode
        ? '${selectedServer?.osName ?? 'Ubuntu server'} • '
              'IP: ${selectedServer?.host ?? 'unknown'}'
        : selectedProject == null
        ? null
        : '${_displayProjectType(selectedProject.type)}'
              '${selectedServer == null ? '' : ' • Server: ${selectedServer.name}'}';
    final navigationActions = ShellNavigationActions(
      navigate: _navigateTo,
      clearDeletedProjectNotice: _clearDeletedProjectNotice,
      prepareAddServer: () {
        unawaited(ref.read(serverOnboardingActionsProvider).prepareAddServer());
      },
      selectServer: (serverId) {
        unawaited(
          ref
              .read(serverOnboardingActionsProvider)
              .selectServerIfDifferent(serverId),
        );
      },
      lastVisitedDestination: ref.read(lastVisitedDestinationProvider),
      trackWorkspaceOpened: ({required workspace, entryPoint, tab}) {
        ref
            .read(appAnalyticsServiceProvider)
            .trackWorkspaceOpened(
              workspace: workspace,
              entryPoint: entryPoint,
              tab: tab,
            );
      },
      trackControlUsed: ({required control, tab}) {
        ref
            .read(appAnalyticsServiceProvider)
            .trackControlUsed(control: control, tab: tab);
      },
      writeTerminalNavigationLine: (line) {
        terminal.writeLine(line, source: 'ui', taskType: 'navigation');
      },
    );

    return MainLayout(
      title: const Text('Deploy Dash'),
      child: ShellNavigationSearchShortcutScope(
        child: Row(
          children: [
            ShellNavigationRail(
              route: route,
              showFirstRunOnboarding: showFirstRunOnboarding,
              actions: navigationActions,
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: Material(
                color: Theme.of(context).canvasColor,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (!isServerLoading &&
                              hasServers &&
                              !isCreateMode &&
                              !isAddServerMode &&
                              headerSubtitle != null &&
                              headerSubtitle.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                headerSubtitle,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          if (serverCatalogError != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                serverCatalogError,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: YaruColors.red),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return Stack(
                            children: [
                              Positioned.fill(
                                child: Padding(
                                  key: const Key('shell-workspace-safe-area'),
                                  padding: const EdgeInsets.only(
                                    bottom: ShellTerminalPanel.reservedInset,
                                  ),
                                  child: WorkspaceBody(
                                    mode: workspaceMode,
                                    hasServer: hasServers,
                                    selectedServer: selectedServer,
                                    chosenServer: chosenServer,
                                    homeProjects: homeProjects,
                                    servers: serverCatalog.servers,
                                    projects: projects,
                                    serverCount: serverCatalog.servers.length,
                                    serverManagementInitialTabIndex:
                                        route.serverManagementTabIndex,
                                    projectInitialTabIndex:
                                        route.projectDestinationTabIndex,
                                    isServerLoading: isServerLoading,
                                    onboardingStep:
                                        serverCatalog.onboardingStep,
                                    pendingSetupServerIds:
                                        serverCatalog.pendingSetupServerIds,
                                    setupRetryServerId: _setupRetryServerId,
                                    pendingEnrollment: pendingEnrollment,
                                    showFirstRunWizard: showFirstRunOnboarding,
                                    onRetryServerSetup: _handleRetryServerSetup,
                                    onCancelCreate: navigationActions.openHome,
                                    onCreateProject: _handleCreateProject,
                                    onSavePendingServer:
                                        _handleSavePendingServer,
                                    onUpdatePendingServer:
                                        _handleUpdatePendingServer,
                                    onAdoptManagedIdentity:
                                        _handleAdoptManagedIdentity,
                                    onCompleteServiceSelection:
                                        _completeServiceSelectionStep,
                                    onOpenProject:
                                        navigationActions.openProject,
                                    onSelectServer:
                                        navigationActions.selectServerFromHome,
                                    onOpenCreateProject:
                                        navigationActions.openCreateProject,
                                    onOpenAddServer:
                                        navigationActions.openAddServer,
                                    onOpenServerManagement:
                                        navigationActions.openServerManagement,
                                    onOpenServerServices: navigationActions
                                        .openServerManagementServices,
                                    appSettingsInitialDestinationId:
                                        route.appSettingsDestinationId,
                                    onProjectDestinationSelected:
                                        (destinationId) {
                                          // Placeholder tabs report here, at
                                          // the single funnel every
                                          // destination switch runs through:
                                          // shipped destinations stay silent.
                                          if (destinationId == 'email' ||
                                              destinationId == 'domain') {
                                            ref
                                                .read(
                                                  appAnalyticsServiceProvider,
                                                )
                                                .trackControlUsed(
                                                  control: AppControl
                                                      .placeholderViewed,
                                                  tab: destinationId,
                                                );
                                          }
                                          navigationActions
                                              .openProjectDestination(
                                                projectId:
                                                    route.projectId ??
                                                    selectedProject?.id ??
                                                    '',
                                                destinationId: destinationId,
                                              );
                                        },
                                    onServerManagementDestinationSelected:
                                        navigationActions
                                            .openServerManagementDestination,
                                    onAppSettingsDestinationSelected:
                                        navigationActions
                                            .openAppSettingsDestination,
                                    deletedProjectNotice: _deletedProjectNotice,
                                    projectDeletionRecoveries:
                                        projectDeletionRecoveries,
                                    onDismissDeletedProjectNotice:
                                        _clearDeletedProjectNotice,
                                    onRetryProjectCleanup: _retryProjectCleanup,
                                    onRemovePendingProjectLocalRecord:
                                        _removePendingProjectLocalRecord,
                                    onProjectDeleted: _handleProjectDeleted,
                                    onRemoveSelectedServer:
                                        _handleRemoveSelectedServer,
                                    onTerminalLine: terminal.writeLine,
                                    telemetryNagVisible: telemetryNag != null,
                                    onShareTelemetryNag: () => unawaited(
                                      ref
                                          .read(
                                            telemetrySettingsProvider.notifier,
                                          )
                                          .answerNag(share: true),
                                    ),
                                    onDismissTelemetryNag: () => unawaited(
                                      ref
                                          .read(
                                            telemetrySettingsProvider.notifier,
                                          )
                                          .answerNag(share: false),
                                    ),
                                  ),
                                ),
                              ),
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: ShellTerminalPanel(
                                  maxHeight: constraints.maxHeight,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _displayProjectType(String type) {
    final normalized = type.trim().toLowerCase();
    if (normalized == 'app' || normalized == 'web app') {
      return 'Web app';
    }
    return type.trim().isEmpty ? 'Project' : type.trim();
  }
}

List<Project> _projectsForSelectedServer(
  List<Project> projects,
  String? serverId,
) {
  final normalizedServerId = serverId?.trim();
  if (normalizedServerId == null || normalizedServerId.isEmpty) {
    return projects;
  }
  return projects
      .where((project) => project.serverId == normalizedServerId)
      .toList(growable: false);
}
