part of '../../project_workspace.dart';

const bool _showManualGitHubCallbackTools = bool.fromEnvironment(
  'DEPLOYDASH_SHOW_MANUAL_GITHUB_CALLBACK',
  defaultValue: false,
);
const String _defaultBuildCommand = 'npm run build';
const String _defaultRunCommand = 'npm run start';
const String _defaultAppSubdirectory = '';
const String _defaultSqliteMountPath = '/var/lib/deploydash/sqlite';
const String _defaultSqliteFileName = 'app.sqlite3';
const String _invalidAppSubdirectory = '__invalid__';
const String _clearRepositorySelectionToken = '__clear_repo__';
const int _scrollableEnvVarThreshold = 10;
const double _scrollableEnvVarListMaxHeight = 320;
const String _resourceUsageRunKind = 'resource_usage';
const String _resourceUsageBusyId = 'poll';

class _OneOffCommandHistoryEntry {
  const _OneOffCommandHistoryEntry({
    required this.command,
    required this.startedAt,
    required this.status,
    this.completedAt,
    this.exitCode,
  });

  final String command;
  final DateTime startedAt;
  final String status;
  final DateTime? completedAt;
  final int? exitCode;
}

/// Truncates a raw commit sha for display, naming the empty case.
///
/// Why a named top level: every release row renders its sha through one
/// closure today; naming the raw-string contract (12 chars, 'Unknown'
/// when empty) keeps the display rule in one place. The D-45 hash owners
/// work a different contract (timeline lists to hash, not raw strings to
/// display text), so there is nothing to merge there.
String _truncateCommit(
  String raw, {
  int maxLength = 12,
  String emptyLabel = 'Unknown',
}) {
  if (raw.isEmpty) {
    return emptyLabel;
  }
  return raw.length <= maxLength ? raw : raw.substring(0, maxLength);
}

class _AppDeploymentSummary extends ConsumerStatefulWidget {
  const _AppDeploymentSummary({this.onOpenRuntimeLogs});

  final VoidCallback? onOpenRuntimeLogs;

  @override
  ConsumerState<_AppDeploymentSummary> createState() =>
      _AppDeploymentSummaryState();
}

class _AppDeploymentSummaryState extends ConsumerState<_AppDeploymentSummary>
    with AutomaticKeepAliveClientMixin<_AppDeploymentSummary> {
  final TextEditingController _callbackController = TextEditingController();
  final TextEditingController _primaryDomainController =
      TextEditingController();
  final TextEditingController _branchController = TextEditingController();
  final TextEditingController _appPortController = TextEditingController(
    text: '3000',
  );
  final TextEditingController _oneOffCommandController =
      TextEditingController();
  final TextEditingController _oneOffCommandTimeoutController =
      TextEditingController(text: '600');
  final TextEditingController _disconnectConfirmController =
      TextEditingController();

  String? _boundProjectId;
  bool _disconnectAcknowledge = false;
  bool _isRunningPreflight = false;
  _PreflightReport? _lastPreflightReport;
  DateTime? _activeDeployStartedAt;

  final Map<String, List<_EnvVarRowState>> _envVarsByProject = {};
  final Map<String, int> _loadedEnvRevisionByProject = <String, int>{};
  final Set<String> _loadedWorkerProjects = <String>{};
  final Set<String> _loadedSqliteProjects = <String>{};
  final Map<String, Map<String, String>> _lastDeployedEnvByProject = {};
  final Map<String, bool> _appDisconnectedByProject = {};
  final Map<String, _LiveAppSnapshot> _liveSnapshotByProject = {};
  final Map<String, ProjectWebAppReadModel> _webAppReadModelByProject = {};
  final Map<String, bool> _runtimeActionInFlightByProject = {};
  final ScopedRunRegistry _resourceUsageRuns = ScopedRunRegistry();
  final ScopedBusyRegistry _resourceUsageBusyRegistry = ScopedBusyRegistry();
  final Map<String, bool> _resourceUsageRequestedByProject = {};
  final Map<String, DateTime> _lastResourceUsageRequestedAtByProject = {};
  final Map<String, _ResourceUsageSnapshot?> _resourceUsageByProject = {};
  final Map<String, _SqliteStorageSnapshot?> _sqliteStorageByProject = {};
  final Map<String, String?> _resourceUsageErrorByProject = {};
  final Map<String, List<Map<String, dynamic>>> _releaseInventoryByProject = {};
  final Map<String, bool> _releaseInventoryLoadingByProject = {};
  final Map<String, String?> _releaseInventoryErrorByProject = {};
  final Map<String, String?> _railpackProviderByProject = {};
  final Map<String, String> _buildCommandByProject = {};
  final Map<String, String> _runCommandByProject = {};
  final Map<String, String> _appSubdirectoryByProject = {};
  final Map<String, bool> _sqliteStorageEnabledByProject = {};
  final Map<String, String> _sqliteVolumeNameByProject = {};
  final Map<String, String> _sqliteMountPathByProject = {};
  final Map<String, String> _sqliteFileNameByProject = {};
  final Map<String, String> _domainRoutingModeByProject = {};
  final Map<String, String> _repositoryHostKeyPromptIdByProject = {};
  final Map<String, String> _tlsChallengeModeByProject = {};
  final Map<String, String?> _tlsDnsProviderByProject = {};
  final Map<String, Map<String, String>> _tlsDnsCredentialsByProject = {};
  final Map<String, String> _oneOffCommandDraftByProject = {};
  final Map<String, String> _oneOffCommandTimeoutByProject = {};
  final Map<String, List<String>> _oneOffCommandOutputByProject = {};
  final Map<String, String?> _oneOffCommandStatusByProject = {};
  final Map<String, int?> _oneOffCommandTaskIdByProject = {};
  final Map<String, bool> _oneOffCommandInFlightByProject = {};
  final Map<String, bool> _oneOffCommandCancelRequestedByProject = {};
  final Map<String, int?> _oneOffCommandExitCodeByProject = {};
  final Map<String, List<_OneOffCommandHistoryEntry>>
  _oneOffCommandHistoryByProject = {};
  String? _pendingRepositorySelection;
  String? _repositorySelectionSyncedProjectId;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _callbackController.dispose();
    _primaryDomainController.dispose();
    _branchController.dispose();
    _appPortController.dispose();
    _oneOffCommandController.dispose();
    _oneOffCommandTimeoutController.dispose();
    _disconnectConfirmController.dispose();
    super.dispose();
  }

  @override
  // coverage-gate: app_deployment_tab_build
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen<GitHubIntegrationState>(gitHubIntegrationProvider, (
      previous,
      next,
    ) {
      _handleGitHubTransition(previous, next);
    });

    final gitState = ref.watch(gitHubIntegrationProvider);
    final gitNotifier = ref.read(gitHubIntegrationProvider.notifier);
    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted.
    final lastPreflightReport = _lastPreflightReport;
    final selectedProject = ref.watch(selectedProjectProvider);
    final envRevisions = ref.watch(appEnvironmentVariableRevisionProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    final enabledDnsProviders =
        (selectedServer?.webServerConfig.enabledDnsProviders ??
                const <String>[])
            .toSet();
    final repositories = gitState.repositories;
    final selectedRepository = gitState.selectedRepositoryForProject(
      selectedProject?.id,
    );
    final isConnecting =
        gitState.connectStatus == GitHubConnectStatus.launchingBrowser ||
        gitState.connectStatus == GitHubConnectStatus.exchangingCode ||
        gitState.connectStatus == GitHubConnectStatus.loadingRepositories;
    final connectFlowActive =
        isConnecting ||
        gitState.connectStatus == GitHubConnectStatus.awaitingCallback;
    final branchValue = _branchController.text.trim().isEmpty
        ? 'main'
        : _branchController.text.trim();
    final domainValue = _primaryDomainController.text.trim();
    final parsedAppPort = int.tryParse(_appPortController.text.trim()) ?? -1;
    final projectId = selectedProject?.id;
    if (projectId != null) {
      _syncEnvRowsFromDatabase(
        projectId: projectId,
        revision: envRevisions[projectId] ?? 0,
      );
    }
    final disconnected = projectId == null
        ? false
        : (_appDisconnectedByProject[projectId] ?? false);
    _syncDeployFieldsFromProject(
      selectedProject,
      selectedRepository,
      disconnected,
    );
    _syncRepositorySelectionFromProject(gitState, selectedProject);
    final liveSnapshot = projectId == null
        ? null
        : _liveSnapshotByProject[projectId];
    final webAppReadModel = projectId == null
        ? null
        : _webAppReadModelByProject[projectId];
    final selectedDeployState = gitState.deployStateForProject(projectId);
    final activeDeployBelongsToProject =
        projectId != null &&
        (selectedDeployState.isRunning ||
            gitState.activeDeployProjectId == projectId);
    final activeDeployRunning = gitState.projectDeployStates.values.any(
      (state) => state.isRunning,
    );
    final displayDeployStatus =
        selectedDeployState.deployStatus == GitHubDeployStatus.idle
        ? (liveSnapshot?.deployStatus ?? GitHubDeployStatus.idle)
        : selectedDeployState.deployStatus;
    final failureEvidence = displayDeployStatus == GitHubDeployStatus.error
        ? selectedDeployState.failureEvidence
        : null;
    final displayStatusMessage = activeDeployBelongsToProject
        ? selectedDeployState.statusMessage
        : activeDeployRunning
        ? 'Another project is deploying. Return to that project to watch progress.'
        : displayDeployStatus == GitHubDeployStatus.error
        ? selectedDeployState.deployStatus == GitHubDeployStatus.error
              ? selectedDeployState.statusMessage
              : 'The last deployment did not complete. Review the deployment log and try again.'
        : 'Ready to deploy this web app.';
    final publicHealth =
        liveSnapshot?.publicHealth ??
        const AppPublicHealthSnapshot(
          enabled: true,
          status: AppPublicHealthStatus.unknown,
          path: '/',
        );
    final processHealth =
        liveSnapshot?.health ?? const ContainerRuntimeStatus.unknown();
    final envRows = projectId == null
        ? const <_EnvVarRowState>[]
        : _envRows(projectId);
    final isDomainValid = _isValidDomain(domainValue);
    final isBranchValid = _isValidBranch(branchValue);
    final isPortValid = parsedAppPort >= 1 && parsedAppPort <= 65535;
    final isRepoSelected = selectedRepository != null;
    // One record for the workflow-call tails below: branch, guarded port,
    // selected repository, and domain travel together to the one-off,
    // inventory-refresh, and rollback calls. Built once so the
    // invalid-port fallback (3000) cannot drift between call sites. The
    // deploy call is not a member: it passes the port unguarded.
    final workflowArgs = (
      branch: branchValue,
      appPort: isPortValid ? parsedAppPort : 3000,
      selectedRepository: selectedRepository,
      domain: domainValue,
    );
    // One opener for the env editor: both buttons guard on a resolved
    // project, then open the dialog with the same six arguments. The guards
    // stay at the call sites (they differ); the resolved project id travels
    // as a parameter because the build-top projectId is nullable.
    void openEnvEditor(String resolvedProjectId) {
      _showEnvEditorDialog(
        projectId: resolvedProjectId,
        gitNotifier: gitNotifier,
        domainValue: domainValue,
        branchValue: branchValue,
        parsedAppPort: parsedAppPort,
        canRedeployBase:
            !disconnected &&
            gitState.isConnected &&
            isRepoSelected &&
            isDomainValid &&
            isBranchValid &&
            isPortValid &&
            gitState.canDeployForProject(resolvedProjectId),
      );
    }

    final tlsValidationError = _tlsSettingsValidationError(
      projectId,
      enabledDnsProviders,
    );
    final deployDisabledReason = activeDeployBelongsToProject
        ? null
        : activeDeployRunning && !activeDeployBelongsToProject
        ? 'Another project is deploying. Return to that project to watch progress.'
        : deploymentBlockedReason(
            disconnected: disconnected,
            gitHubConnected: gitState.isConnected,
            repositorySelected: isRepoSelected,
            domainValid: isDomainValid,
            branchValid: isBranchValid,
            portValid: isPortValid,
            tlsValidationError: tlsValidationError,
            canDeploy: gitState.canDeployForProject(projectId),
          );
    final hasValidationErrors = deployDisabledReason != null;
    final runtimeActionInFlight = projectId == null
        ? false
        : (_runtimeActionInFlightByProject[projectId] ?? false);
    final liveUrl = isDomainValid
        ? 'https://${_canonicalDomainForWorkspace(primaryDomain: domainValue, domainRoutingMode: projectId == null ? _domainRoutingModeSingleHost : _domainRoutingModeFor(projectId))}'
        : 'Not deployed yet';
    final buildCommandValue = projectId == null
        ? _defaultBuildCommand
        : _buildCommandFor(projectId);
    final runCommandValue = projectId == null
        ? _defaultRunCommand
        : _runCommandFor(projectId);
    final hasRepositorySetup = gitState.isConnected && isRepoSelected;
    final hasLocalDeploymentRecord =
        (webAppReadModel?.hasDeploymentRecord ?? false) ||
        (liveSnapshot?.lastDeployAt != null ||
            liveSnapshot?.commit.trim().isNotEmpty == true &&
                liveSnapshot?.commit != 'Not synced yet');
    final statusTone =
        publicHealth.needsAttention &&
            (displayDeployStatus == GitHubDeployStatus.idle ||
                displayDeployStatus == GitHubDeployStatus.success)
        ? YaruColors.orange
        : switch (displayDeployStatus) {
            GitHubDeployStatus.success => Colors.green,
            GitHubDeployStatus.error => YaruColors.red,
            GitHubDeployStatus.generatingServerKey ||
            GitHubDeployStatus.registeringDeployKey ||
            GitHubDeployStatus.cloningRepository ||
            GitHubDeployStatus.buildingRelease => Colors.orange,
            GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation =>
              Colors.orange,
            GitHubDeployStatus.idle =>
              !hasLocalDeploymentRecord
                  ? Theme.of(context).colorScheme.outline
                  : processHealth.color(context),
          };
    final appReleaseScope = projectId == null || selectedServer == null
        ? const AppReleaseScopeState()
        : ref
              .watch(appReleaseProvider)
              .scopeFor(projectId: projectId, serverId: selectedServer.id);
    final resourceUsageInFlight = projectId == null
        ? false
        : _resourceUsageBusyRegistry.isBusy(
            scopeKey: projectId,
            kind: _resourceUsageRunKind,
            id: _resourceUsageBusyId,
          );
    final providerReleaseInventory = appReleaseScope.releases
        .map(_releaseRecordToInventoryMap)
        .toList(growable: false);
    final releaseInventory = projectId == null
        ? const <Map<String, dynamic>>[]
        : (providerReleaseInventory.isNotEmpty
              ? providerReleaseInventory
              : (_releaseInventoryByProject[projectId] ??
                    const <Map<String, dynamic>>[]));
    final releaseInventoryLoading = projectId == null
        ? false
        : (_releaseInventoryLoadingByProject[projectId] ?? false);
    final releaseInventoryError = projectId == null
        ? null
        : _releaseInventoryErrorByProject[projectId];
    final liveRelease = releaseInventory
        .cast<Map<String, dynamic>?>()
        .firstWhere(
          (entry) => entry?['status']?.toString() == 'live',
          orElse: () => null,
        );
    final hasSuccessfulDeployment =
        liveRelease != null ||
        selectedProject?.lastDeployedAt != null ||
        ((selectedProject?.lastDeployCommit?.trim().isNotEmpty) ?? false);
    final previousReleases = releaseInventory
        .where((entry) => entry['status']?.toString() != 'live')
        .toList(growable: false);
    final oneOffCommandInFlight = projectId == null
        ? false
        : (_oneOffCommandInFlightByProject[projectId] ?? false);
    final oneOffCommandStatus = projectId == null
        ? null
        : _oneOffCommandStatusByProject[projectId];
    final oneOffCommandOutput = projectId == null
        ? const <String>[]
        : (_oneOffCommandOutputByProject[projectId] ?? const <String>[]);
    final oneOffCommandExitCode = projectId == null
        ? null
        : _oneOffCommandExitCodeByProject[projectId];
    final oneOffCommandHistory = projectId == null
        ? const <_OneOffCommandHistoryEntry>[]
        : (_oneOffCommandHistoryByProject[projectId] ??
              const <_OneOffCommandHistoryEntry>[]);
    final oneOffRuntimeProvider = projectId == null
        ? null
        : _railpackProviderFor(projectId);
    final deployActionInFlight =
        activeDeployBelongsToProject || runtimeActionInFlight;
    String formatReleaseTimestamp(String? rawValue) {
      final raw = rawValue?.trim();
      if (raw == null || raw.isEmpty) {
        return 'Never';
      }
      return _formatTimestamp(DateTime.tryParse(raw)?.toLocal());
    }

    String formatReleaseCommit(Map<String, dynamic> release) {
      final raw = release['commit_sha']?.toString().trim() ?? '';
      return _truncateCommit(raw);
    }

    final oneOffCommandDisabledReason = selectedProject == null
        ? 'Select a web app project first.'
        : disconnected
        ? 'Reconnect web app before running commands.'
        : oneOffRuntimeProvider == 'staticfile'
        ? 'One-off commands are not available for staticfile web apps.'
        : (runtimeActionInFlight && !oneOffCommandInFlight)
        ? 'Another runtime action is already running.'
        : resourceUsageInFlight
        ? 'Checking app container state...'
        : !hasSuccessfulDeployment
        ? 'Deploy this web app before running commands.'
        : null;

    return ListView(
      key: const Key('app-tab-scroll'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final statusLabel = _statusBadgeLabel(
              deployStatus: displayDeployStatus,
              health: processHealth,
              publicHealth: publicHealth,
              disconnected: disconnected,
              hasDeploymentRecord: hasLocalDeploymentRecord,
            );
            final primaryAction = !gitState.isConnected
                ? ElevatedButton.icon(
                    key: const Key('connect-github-button'),
                    onPressed: connectFlowActive
                        ? null
                        : gitNotifier.connectGitHub,
                    icon: const Icon(Icons.code),
                    label: const Text('Connect GitHub'),
                  )
                : !isRepoSelected
                ? SizedBox(
                    width:
                        constraints.maxWidth <
                            AppWorkspaceBreakpoints.stackedActions
                        ? constraints.maxWidth
                        : 300,
                    child: DropdownButtonFormField<String>(
                      key: const Key('github-repo-dropdown'),
                      isExpanded: true,
                      initialValue:
                          repositories.any(
                            (repo) => repo.fullName == selectedRepository,
                          )
                          ? selectedRepository
                          : null,
                      hint: const Text('Select a repository'),
                      decoration: const InputDecoration(
                        labelText: 'Repository',
                      ),
                      items: repositories
                          .map(
                            (repo) => DropdownMenuItem<String>(
                              value: repo.fullName,
                              child: Text(
                                '${repo.fullName}${repo.isPrivate ? ' (private)' : ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: repositories.isEmpty
                          ? null
                          : (value) {
                              gitNotifier.selectRepository(
                                value,
                                projectId: selectedProject?.id,
                              );
                              setState(() {});
                            },
                    ),
                  )
                : FilledButton.icon(
                    key: const Key('github-deploy-button'),
                    style: FilledButton.styleFrom(
                      backgroundColor: YaruColors.orange,
                      foregroundColor: Colors.black,
                    ),
                    onPressed:
                        hasValidationErrors ||
                            _isRunningPreflight ||
                            deployActionInFlight
                        ? null
                        : () {
                            gitNotifier.deploySelectedRepository(
                              primaryDomain: domainValue,
                              branch: branchValue,
                              appPort: parsedAppPort,
                              railpackBuildCommand: buildCommandValue,
                              railpackRunCommand: runCommandValue,
                              railpackProvider: projectId == null
                                  ? null
                                  : _railpackProviderFor(projectId),
                              appSubdirectory: _normalizedAppSubdirectory(
                                _appSubdirectoryFor(projectId),
                              ),
                            );
                          },
                    icon: const Icon(Icons.rocket_launch),
                    label: Text(
                      isDeployStatusRunning(displayDeployStatus)
                          ? 'Deploying...'
                          : (hasSuccessfulDeployment ? 'Redeploy' : 'Deploy'),
                    ),
                  );
            final secondaryActions = isRepoSelected
                ? <Widget>[
                    IconButton(
                      key: const Key('github-preflight-button'),
                      tooltip: _isRunningPreflight
                          ? 'Checking settings...'
                          : 'Check settings',
                      onPressed: _isRunningPreflight || deployActionInFlight
                          ? null
                          : () => _runPreflight(
                              githubConnected: gitState.isConnected,
                              repositorySelected: isRepoSelected,
                              domainValid: isDomainValid,
                              branchValid: isBranchValid,
                              portValid: isPortValid,
                              appConnected: !disconnected,
                            ),
                      icon: _isRunningPreflight
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.rule),
                    ),
                    IconButton(
                      key: const Key('deployment-edit-settings-button'),
                      tooltip: 'Change settings',
                      onPressed: selectedProject == null || deployActionInFlight
                          ? null
                          : () => _showDeploymentSettingsDialog(
                              projectId: selectedProject.id,
                              project: selectedProject,
                              gitNotifier: gitNotifier,
                              repositories: repositories,
                              selectedRepository: selectedRepository,
                              enabledDnsProviders: enabledDnsProviders,
                            ),
                      icon: const Icon(
                        Icons.settings_outlined,
                        semanticLabel: 'Change settings',
                      ),
                    ),
                  ]
                : const <Widget>[];
            return AppWorkspaceSection(
              key: const Key('app-live-state-card'),
              icon: Icons.monitor_heart_outlined,
              title: deploymentCurrentStateTitle(),
              subtitle: deploymentCurrentStateSubtitle(),
              headerAction: Chip(
                label: Text(statusLabel, key: const Key('github-status-text')),
                side: BorderSide(color: statusTone),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  KeyedSubtree(
                    key: const Key('app-new-deploy-card'),
                    child: AppPrimaryActionPanel(
                      icon: Icons.rocket_launch_outlined,
                      currentState: deploymentStepHeading(
                        gitHubConnected: gitState.isConnected,
                        repositorySelected: isRepoSelected,
                        hasSuccessfulDeployment: hasSuccessfulDeployment,
                      ),
                      description: deploymentPrimarySubtitle(
                        hasRepositorySetup: hasRepositorySetup,
                        hasSuccessfulDeployment: hasSuccessfulDeployment,
                      ),
                      primaryAction: primaryAction,
                      secondaryActions: secondaryActions,
                      blockingReason: isRepoSelected
                          ? deployDisabledReason
                          : null,
                      blockingReasonKey: const Key('deploy-disabled-reason'),
                    ),
                  ),
                  if (!gitState.isConnected)
                    _GitHubConnectionFeedback(
                      gitState: gitState,
                      onCopyAuthorizationUrl: _copyGitHubAuthorizationUrl,
                    ),
                  if (isRepoSelected) ...[
                    const SizedBox(height: 10),
                    Text(
                      displayStatusMessage,
                      key: const Key('deploy-status-message'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    // coverage-gate: deploy_failure_actions
                    if (failureEvidence != null) ...[
                      const SizedBox(height: 10),
                      AppDeployFailureCard(
                        evidence: failureEvidence,
                        statusMessage: displayStatusMessage,
                        suggestedNextStep:
                            selectedDeployState.suggestedNextStep,
                        onCopyDetails: (details) {
                          ref
                              .read(appAnalyticsServiceProvider)
                              .trackControlUsed(
                                control: AppControl.deployFailureDetailsCopied,
                              );
                          return Clipboard.setData(
                            ClipboardData(text: details),
                          );
                        },
                        onOpenLogs: widget.onOpenRuntimeLogs == null
                            ? null
                            : () {
                                ref
                                    .read(appAnalyticsServiceProvider)
                                    .trackControlUsed(
                                      control:
                                          AppControl.deployFailureLogsOpened,
                                    );
                                widget.onOpenRuntimeLogs!();
                              },
                      ),
                    ],
                    // end coverage-gate
                  ],
                  if (_showManualGitHubCallbackTools &&
                      !gitState.isConnected) ...[
                    const SizedBox(height: 10),
                    TextField(
                      key: const Key('github-callback-field'),
                      controller: _callbackController,
                      decoration: const InputDecoration(
                        hintText: 'deploydash://callback?code=xyz123',
                        labelText: 'Deep Link Callback URL',
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('github-process-callback-button'),
                      onPressed: () => gitNotifier.processCallbackUrl(
                        _callbackController.text,
                      ),
                      icon: const Icon(Icons.call_received),
                      label: const Text('Process Callback URL'),
                    ),
                  ],
                  if (lastPreflightReport != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Preflight: ${_formatTimestamp(lastPreflightReport.executedAt)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    for (final check in lastPreflightReport.checks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              check.passed
                                  ? Icons.check_circle
                                  : Icons.error_outline,
                              size: 14,
                              color: check.passed
                                  ? Colors.green
                                  : YaruColors.orange,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${check.label}: ${check.detail}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    'Current deployment',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  _LabeledValueRow(
                    width: 96,
                    label: 'Repository',
                    value:
                        liveSnapshot?.repo ??
                        selectedRepository ??
                        'Not selected',
                  ),
                  const SizedBox(height: 12),
                  _LabeledValueRow(
                    width: 96,
                    label: 'Branch',
                    value: liveSnapshot?.branch ?? branchValue,
                  ),
                  if (liveRelease != null) ...[
                    const SizedBox(height: 12),
                    _LabeledValueRow(
                      width: 96,
                      label: 'Release',
                      value: liveRelease['release_id']?.toString() ?? 'Unknown',
                    ),
                  ],
                  const SizedBox(height: 12),
                  _LabeledValueRow(
                    width: 96,
                    label: 'Commit',
                    value: liveSnapshot?.commit ?? 'Not synced yet',
                  ),
                  const SizedBox(height: 12),
                  _LabeledValueRow(
                    label: 'URL',
                    value: liveSnapshot?.url ?? liveUrl,
                    width: 96,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    valueMaxLines: 1,
                    valueOverflow: TextOverflow.ellipsis,
                    trailing: IconButton(
                      tooltip: 'Open URL',
                      onPressed: isDomainValid
                          ? () => openExternalUrl(liveSnapshot?.url ?? liveUrl)
                          : null,
                      icon: const Icon(
                        Icons.open_in_new,
                        size: 18,
                        semanticLabel: 'Open URL',
                      ),
                    ),
                  ),
                  if (hasLocalDeploymentRecord) ...[
                    const SizedBox(height: 12),
                    _LabeledValueRow(
                      width: 96,
                      label: 'App process',
                      value: processHealth.label,
                    ),
                    const SizedBox(height: 12),
                    _LabeledValueRow(
                      width: 96,
                      label: 'Public check',
                      value: '${publicHealth.detail} at ${publicHealth.path}',
                    ),
                  ],
                  if (hasLocalDeploymentRecord &&
                      publicHealth.needsAttention) ...[
                    const SizedBox(height: 12),
                    Container(
                      key: const Key('app-public-health-warning'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.errorContainer.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Public URL needs attention',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${publicHealth.detail} at ${publicHealth.path}. '
                            'The app process is ready, but visitors may see an error.',
                            key: const Key('app-public-health-warning-detail'),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const Key(
                                  'app-public-health-runtime-logs-button',
                                ),
                                onPressed: widget.onOpenRuntimeLogs,
                                icon: const Icon(Icons.receipt_long, size: 16),
                                label: const Text('Runtime logs'),
                              ),
                              OutlinedButton.icon(
                                key: const Key(
                                  'app-public-health-environment-button',
                                ),
                                onPressed: projectId == null
                                    ? null
                                    : () => openEnvEditor(projectId),
                                icon: const Icon(Icons.key_outlined, size: 16),
                                label: const Text('Environment settings'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _LabeledValueRow(
                    width: 96,
                    label: 'Last deploy',
                    value: _formatTimestamp(liveSnapshot?.lastDeployAt),
                  ),
                ],
              ),
            );
          },
        ),
        Builder(
          builder: (context) {
            final envCard = AppWorkspaceSection(
              key: const Key('app-env-card'),
              icon: Icons.key_outlined,
              title: 'Environment variables',
              subtitle: 'Current runtime variables for this web app.',
              headerAction: IconButton(
                key: const Key('env-edit-button'),
                tooltip: 'Edit environment variables',
                onPressed: projectId == null || runtimeActionInFlight
                    ? null
                    : () => openEnvEditor(projectId),
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 18,
                  semanticLabel: 'Edit environment variables',
                ),
                visualDensity: VisualDensity.compact,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (envRows.isEmpty)
                    const KeyedSubtree(
                      key: Key('app-env-empty-state'),
                      child: AppEmptyStateView(
                        icon: Icons.key_off_outlined,
                        title: 'No environment variables yet',
                        message:
                            'Add keys like API tokens and secrets when your web app needs them.',
                      ),
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (envRows.length > _scrollableEnvVarThreshold)
                          DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outlineVariant
                                    .withValues(alpha: 0.7),
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Scrollbar(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: _scrollableEnvVarListMaxHeight,
                                  ),
                                  child: SingleChildScrollView(
                                    key: const Key('app-env-list-scroll'),
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      12,
                                      12,
                                      4,
                                    ),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        for (
                                          int index = 0;
                                          index < envRows.length;
                                          index += 1
                                        )
                                          _EnvVarReadOnlyKeyToken(
                                            row: envRows[index],
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (
                                int index = 0;
                                index < envRows.length;
                                index += 1
                              )
                                _EnvVarReadOnlyKeyToken(row: envRows[index]),
                            ],
                          ),
                      ],
                    ),
                ],
              ),
            );

            final oneOffCommandCard = AppDisclosureSection(
              key: const Key('app-oneoff-command-card'),
              icon: Icons.terminal,
              title: deploymentOneOffToolsTitle(),
              subtitle: deploymentOneOffToolsSubtitle(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppTextFormField(
                    key: const Key('app-oneoff-command-field'),
                    controller: _oneOffCommandController,
                    enabled: !oneOffCommandInFlight,
                    labelText: 'Command to run',
                    hintText: 'npm run db:migrate',
                    onChanged: projectId == null
                        ? null
                        : (value) {
                            _oneOffCommandDraftByProject[projectId] = value;
                          },
                  ),
                  const SizedBox(height: 12),
                  AppNumberFormField(
                    key: const Key('app-oneoff-timeout-field'),
                    controller: _oneOffCommandTimeoutController,
                    enabled: !oneOffCommandInFlight,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    labelText: 'Time limit (seconds)',
                    onChanged: projectId == null
                        ? null
                        : (value) {
                            _oneOffCommandTimeoutByProject[projectId] = value;
                          },
                  ),
                  const SizedBox(height: 12),
                  if (oneOffCommandDisabledReason != null)
                    Text(
                      oneOffCommandDisabledReason,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: YaruColors.orange),
                    ),
                  if (oneOffCommandDisabledReason != null)
                    const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('app-oneoff-run-button'),
                        onPressed: selectedProject == null
                            ? null
                            : oneOffCommandInFlight
                            ? () => _cancelOneOffCommand(selectedProject)
                            : oneOffCommandDisabledReason != null
                            ? null
                            : () => _runOneOffCommand(
                                project: selectedProject,
                                branch: workflowArgs.branch,
                                appPort: workflowArgs.appPort,
                                selectedRepository:
                                    workflowArgs.selectedRepository,
                                domain: workflowArgs.domain,
                              ),
                        icon: Icon(
                          oneOffCommandInFlight
                              ? Icons.stop_circle_outlined
                              : Icons.play_arrow,
                        ),
                        label: Text(
                          oneOffCommandInFlight
                              ? 'Cancel running command'
                              : 'Run command',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (oneOffCommandStatus != null)
                    Text(
                      oneOffCommandStatus,
                      key: const Key('app-oneoff-status-text'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (oneOffCommandExitCode != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Exit code: $oneOffCommandExitCode',
                      key: const Key('app-oneoff-exit-code-text'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (oneOffCommandOutput.isEmpty)
                    KeyedSubtree(
                      key: const Key('app-oneoff-output-empty-state'),
                      child: AppEmptyStateView(
                        icon: Icons.terminal_outlined,
                        title: 'No command output yet',
                        message: deploymentOneOffOutputEmpty(),
                      ),
                    )
                  else
                    AppCard(
                      margin: EdgeInsets.zero,
                      fillColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      child: SelectableText(
                        oneOffCommandOutput.join('\n'),
                        key: const Key('app-oneoff-output-text'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    deploymentOneOffHistoryTitle(),
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (oneOffCommandHistory.isEmpty)
                    Text(
                      deploymentOneOffHistoryEmpty(),
                      key: const Key('app-oneoff-history-empty-text'),
                      style: Theme.of(context).textTheme.bodySmall,
                    )
                  else
                    Column(
                      children: [
                        for (
                          var index = 0;
                          index < oneOffCommandHistory.length;
                          index++
                        )
                          AppCard(
                            key: Key('app-oneoff-history-entry-$index'),
                            borderColor: Theme.of(context).dividerColor,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  oneOffCommandHistory[index].command,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _formatOneOffCommandTimestamp(
                                    context,
                                    oneOffCommandHistory[index].startedAt,
                                  ),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  oneOffCommandHistory[index].status +
                                      (oneOffCommandHistory[index].exitCode !=
                                              null
                                          ? ' (exit code: ${oneOffCommandHistory[index].exitCode})'
                                          : ''),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            );

            return Column(
              children: [
                envCard,
                if (hasSuccessfulDeployment) oneOffCommandCard,
              ],
            );
          },
        ),
        if (hasSuccessfulDeployment)
          AppDisclosureSection(
            key: const Key('app-release-history-card'),
            icon: Icons.history_outlined,
            title: 'Releases and rollback',
            subtitle: 'Review retained releases when you need to roll back.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    key: const Key('app-release-history-refresh-button'),
                    tooltip: 'Refresh release history',
                    onPressed: selectedProject == null || runtimeActionInFlight
                        ? null
                        : () => _refreshReleaseInventory(
                            project: selectedProject,
                            branch: workflowArgs.branch,
                            appPort: workflowArgs.appPort,
                            selectedRepository: workflowArgs.selectedRepository,
                            domain: workflowArgs.domain,
                          ),
                    icon: releaseInventoryLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                if (previousReleases.any(
                  (entry) => entry['status']?.toString() == 'retained',
                )) ...[
                  OutlinedButton.icon(
                    key: const Key('app-release-rollback-previous-button'),
                    onPressed:
                        selectedProject == null ||
                            disconnected ||
                            runtimeActionInFlight
                        ? null
                        : () => _rollbackToRelease(
                            project: selectedProject,
                            branch: workflowArgs.branch,
                            appPort: workflowArgs.appPort,
                            selectedRepository: workflowArgs.selectedRepository,
                            domain: workflowArgs.domain,
                            releaseId: null,
                          ),
                    icon: const Icon(Icons.undo),
                    label: const Text('Rollback to previous release'),
                  ),
                  const SizedBox(height: 12),
                ],
                if (releaseInventoryError != null) ...[
                  Text(
                    releaseInventoryError,
                    key: const Key('app-release-history-error-text'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: YaruColors.orange),
                  ),
                  const SizedBox(height: 12),
                ],
                if (releaseInventoryLoading && previousReleases.isEmpty)
                  Text(
                    'Reading release history...',
                    key: const Key('app-release-history-loading-text'),
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else if (previousReleases.isEmpty)
                  KeyedSubtree(
                    key: const Key('app-release-history-empty-text'),
                    child: AppEmptyStateView(
                      icon: Icons.history_toggle_off_outlined,
                      title: 'No previous releases',
                      message: disconnected
                          ? 'Reconnect and deploy again to create a release that can be retained.'
                          : 'Deploy another successful release to make rollback available.',
                    ),
                  )
                else ...[
                  Text(
                    'Previous releases',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  for (var index = 0; index < previousReleases.length; index++)
                    AppCard(
                      key: Key('app-release-row-$index'),
                      borderColor: Theme.of(context).dividerColor,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  previousReleases[index]['release_id']
                                          ?.toString() ??
                                      'Unknown release',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              Chip(
                                label: Text(
                                  previousReleases[index]['status']
                                          ?.toString() ??
                                      'unknown',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Commit ${formatReleaseCommit(previousReleases[index])}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Created ${formatReleaseTimestamp(previousReleases[index]['created_at']?.toString())}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if ((previousReleases[index]['rollback_from_release_id']
                                  ?.toString()
                                  .trim()
                                  .isNotEmpty ??
                              false)) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Replaced ${previousReleases[index]['rollback_from_release_id']}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          if (previousReleases[index]['status']?.toString() ==
                              'retained') ...[
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              key: Key('app-release-row-rollback-$index'),
                              onPressed:
                                  selectedProject == null ||
                                      disconnected ||
                                      runtimeActionInFlight
                                  ? null
                                  : () => _rollbackToRelease(
                                      project: selectedProject,
                                      branch: workflowArgs.branch,
                                      appPort: workflowArgs.appPort,
                                      selectedRepository:
                                          workflowArgs.selectedRepository,
                                      domain: workflowArgs.domain,
                                      releaseId:
                                          previousReleases[index]['release_id']
                                              ?.toString(),
                                    ),
                              icon: const Icon(Icons.history_toggle_off),
                              label: const Text('Rollback to this release'),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        if (hasSuccessfulDeployment)
          AppDisclosureSection(
            key: const Key('app-disconnect-card'),
            icon: disconnected
                ? Icons.link_outlined
                : Icons.warning_amber_outlined,
            title: disconnected ? 'Web app connection' : 'Danger zone',
            subtitle: disconnected
                ? 'Reconnect this web app before deploying or running maintenance.'
                : 'Remove the deployed web app without deleting other project resources.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  disconnected
                      ? 'Web app is disconnected from runtime.'
                      : 'Use this when you need a safe pivot without deleting project resources.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('app-disconnect-button'),
                      onPressed:
                          selectedProject == null ||
                              disconnected ||
                              runtimeActionInFlight
                          ? null
                          : () => _showDisconnectDialog(selectedProject),
                      icon: const Icon(Icons.link_off),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: YaruColors.red,
                      ),
                      label: const Text('Remove web app'),
                    ),
                    if (disconnected)
                      ElevatedButton.icon(
                        key: const Key('app-reconnect-button'),
                        onPressed: runtimeActionInFlight
                            ? null
                            : () {
                                setState(() {
                                  _appDisconnectedByProject[projectId] = false;
                                  final snapshot =
                                      _liveSnapshotByProject[projectId];
                                  if (snapshot != null) {
                                    _liveSnapshotByProject[projectId] = snapshot
                                        .copyWith(
                                          health:
                                              ContainerRuntimeStatus.fromStoredHealthStatus(
                                                'unhealthy',
                                              ),
                                        );
                                  }
                                });
                                ref
                                    .read(projectListProvider.notifier)
                                    .updateRuntimeState(
                                      projectId: projectId,
                                      appDisconnected: false,
                                    );
                              },
                        icon: const Icon(Icons.link),
                        label: const Text('Reconnect web app'),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
// end coverage-gate
