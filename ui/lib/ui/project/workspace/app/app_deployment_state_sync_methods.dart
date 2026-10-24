// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _AppDeploymentStateSyncMethods on _AppDeploymentSummaryState {
  Future<void> _copyGitHubAuthorizationUrl(String authorizationUrl) async {
    await Clipboard.setData(ClipboardData(text: authorizationUrl));
    _showCopiedSnack('GitHub authorization URL copied.');
  }

  // coverage-gate: ensure_project_state
  /// Seeds every per-project map for [project], and returns its live snapshot.
  ///
  /// Returning the snapshot is what lets callers read it without asserting:
  /// this method is the only thing that creates the entry, so the fact that it
  /// exists afterwards is carried by the return type rather than by a `!` at
  /// every call site.
  _LiveAppSnapshot _ensureProjectState(Project project) {
    final projectId = project.id;
    _envVarsByProject.putIfAbsent(projectId, () => const []);
    _lastDeployedEnvByProject.putIfAbsent(projectId, () => const {});
    _appDisconnectedByProject[projectId] = project.appDisconnected;
    final existingSnapshot = _liveSnapshotByProject[projectId] ??= _LiveAppSnapshot(
      repo: project.repositoryFullName ?? 'Not selected',
      branch: project.deployBranch,
      commit: project.lastDeployCommit ?? 'Not synced yet',
      url: _isValidDomain(project.primaryDomain)
          ? 'https://${_canonicalDomainForWorkspace(primaryDomain: project.primaryDomain, domainRoutingMode: project.domainRoutingMode)}'
          : 'Not deployed yet',
      health: const ContainerRuntimeStatus.unknown(),
      publicHealth: AppPublicHealthSnapshot(
        enabled: project.publicHealthCheckEnabled,
        status: project.publicHealthCheckEnabled
            ? AppPublicHealthStatus.unknown
            : AppPublicHealthStatus.skipped,
        path: project.publicHealthCheckPath,
      ),
      deployStatus: GitHubDeployStatus.idle,
      lastDeployAt: project.lastDeployedAt,
    );
    // Hoisted so the emptiness checks promote it; a public final field is
    // never promoted, which is what would otherwise force a `!` on each read.
    final repositoryFullName = project.repositoryFullName;
    final hasRepository =
        repositoryFullName != null && repositoryFullName.isNotEmpty;
    var snapshot = existingSnapshot;
    if (project.lastDeployCommit != null ||
        project.lastDeployedAt != null ||
        hasRepository) {
      snapshot = existingSnapshot.copyWith(
        repo: hasRepository ? repositoryFullName : existingSnapshot.repo,
        branch: project.deployBranch,
        commit: project.lastDeployCommit ?? existingSnapshot.commit,
        lastDeployAt: project.lastDeployedAt ?? existingSnapshot.lastDeployAt,
      );
      _liveSnapshotByProject[projectId] = snapshot;
    }
    _runtimeActionInFlightByProject.putIfAbsent(projectId, () => false);
    _resourceUsageRequestedByProject.putIfAbsent(projectId, () => false);
    _resourceUsageByProject.putIfAbsent(projectId, () => null);
    _resourceUsageErrorByProject.putIfAbsent(projectId, () => null);
    _releaseInventoryByProject.putIfAbsent(
      projectId,
      () => const <Map<String, dynamic>>[],
    );
    _releaseInventoryLoadingByProject.putIfAbsent(projectId, () => false);
    _releaseInventoryErrorByProject.putIfAbsent(projectId, () => null);
    _railpackProviderByProject[projectId] = normalizeRailpackProvider(
      project.railpackProvider,
    );
    _buildCommandByProject[projectId] = project.railpackBuildCommand;
    _runCommandByProject[projectId] = project.railpackRunCommand;
    _appSubdirectoryByProject[projectId] = project.appSubdirectory ?? '';
    _sqliteStorageEnabledByProject[projectId] = project.sqliteStorageEnabled;
    _sqliteVolumeNameByProject[projectId] =
        project.sqliteVolumeName ?? _defaultSqliteVolumeName(project.name);
    _sqliteMountPathByProject[projectId] =
        project.sqliteMountPath ?? _defaultSqliteMountPath;
    _sqliteFileNameByProject[projectId] =
        project.sqliteFileName ?? _defaultSqliteFileName;
    _sqliteStorageByProject[projectId] ??= _SqliteStorageSnapshot.fromProject(
      project,
    );
    _domainRoutingModeByProject[projectId] =
        _normalizedDomainRoutingModeForWorkspace(project.domainRoutingMode);
    _tlsChallengeModeByProject[projectId] = project.tlsChallengeMode;
    _tlsDnsProviderByProject[projectId] = project.tlsDnsProvider;
    _tlsDnsCredentialsByProject[projectId] = Map<String, String>.from(
      project.tlsDnsCredentials,
    );
    _oneOffCommandDraftByProject.putIfAbsent(projectId, () => '');
    _oneOffCommandTimeoutByProject.putIfAbsent(projectId, () => '600');
    _oneOffCommandOutputByProject.putIfAbsent(projectId, () => <String>[]);
    _oneOffCommandStatusByProject.putIfAbsent(projectId, () => null);
    _oneOffCommandTaskIdByProject.putIfAbsent(projectId, () => null);
    _oneOffCommandInFlightByProject.putIfAbsent(projectId, () => false);
    _oneOffCommandCancelRequestedByProject.putIfAbsent(projectId, () => false);
    _oneOffCommandExitCodeByProject.putIfAbsent(projectId, () => null);
    _oneOffCommandHistoryByProject.putIfAbsent(
      projectId,
      () => <_OneOffCommandHistoryEntry>[],
    );
    _recomputeEnvChangeState(projectId);
    _loadWorkersFromDatabase(projectId);
    _loadSqliteDatabasesFromDatabase(projectId);
    return snapshot;
  }

  // end coverage-gate
  void _syncEnvRowsFromDatabase({
    required String projectId,
    required int revision,
  }) {
    if (_loadedEnvRevisionByProject[projectId] == revision) {
      return;
    }
    _loadedEnvRevisionByProject[projectId] = revision;
    unawaited(_readEnvRowsFromDatabase(projectId));
  }

  Future<void> _readEnvRowsFromDatabase(String projectId) async {
    final repository = ref.read(appEnvironmentVariableRepositoryProvider);
    final records = await repository.listForProject(projectId);
    if (!mounted) {
      return;
    }
    setState(() {
      _envVarsByProject[projectId] = records
          .map(
            (record) => _EnvVarRowState(
              key: record.key,
              value: record.value,
              secret: record.secret,
            ),
          )
          .toList(growable: false);
      _recomputeEnvChangeState(projectId);
    });
  }

  void _loadWorkersFromDatabase(String projectId) {
    if (!_loadedWorkerProjects.add(projectId)) {
      return;
    }
    unawaited(
      ref.read(projectWorkerInstancesProvider.notifier).loadProject(projectId),
    );
  }

  void _loadSqliteDatabasesFromDatabase(String projectId) {
    if (!_loadedSqliteProjects.add(projectId)) {
      return;
    }
    unawaited(
      ref.read(projectSqliteDatabasesProvider.notifier).loadProject(projectId),
    );
  }

  void _syncDeployFieldsFromProject(
    Project? project,
    String? selectedRepository,
    bool disconnected,
  ) {
    if (project == null) {
      return;
    }
    _ensureProjectState(project);
    final repositoryForSnapshot = projectWebAppRepositoryLabel(
      project: project,
      fallbackRepo: selectedRepository,
    );
    final existingSnapshot = _liveSnapshotByProject[project.id];
    if (existingSnapshot != null &&
        existingSnapshot.repo != repositoryForSnapshot) {
      _liveSnapshotByProject[project.id] = existingSnapshot.copyWith(
        repo: repositoryForSnapshot,
      );
    }
    if (_boundProjectId == project.id) {
      return;
    }
    _boundProjectId = project.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _boundProjectId != project.id) {
        return;
      }
      ref
          .read(gitHubIntegrationProvider.notifier)
          .mirrorProjectFailureEvidence(project.id);
    });
    final primaryDomain = project.primaryDomain.trim();
    _primaryDomainController.text = primaryDomain == 'Not configured'
        ? ''
        : primaryDomain;
    _branchController.text = project.deployBranch;
    _appPortController.text = project.appPort.toString();
    _syncOneOffCommandDraftFromProject(project);
    final snapshot = _liveSnapshotByProject[project.id];
    if (snapshot != null) {
      _liveSnapshotByProject[project.id] = snapshot.copyWith(
        repo: repositoryForSnapshot,
        branch: _branchController.text.trim().isEmpty
            ? 'main'
            : _branchController.text.trim(),
        commit: project.lastDeployCommit ?? snapshot.commit,
        lastDeployAt: project.lastDeployedAt ?? snapshot.lastDeployAt,
      );
    }
    unawaited(_loadLocalReleaseInventory(project));
  }

  // coverage-gate: load_local_release_inventory
  Future<void> _loadLocalReleaseInventory(Project project) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _releaseInventoryByProject[project.id] = const <Map<String, dynamic>>[];
        _webAppReadModelByProject.remove(project.id);
        _releaseInventoryLoadingByProject[project.id] = false;
        _releaseInventoryErrorByProject[project.id] = null;
      });
      return;
    }

    try {
      await ref
          .read(appReleaseProvider.notifier)
          .loadScope(projectId: project.id, serverId: selectedServer.id);
      if (!mounted) {
        return;
      }
      final scope = ref
          .read(appReleaseProvider)
          .scopeFor(projectId: project.id, serverId: selectedServer.id);
      final releases = scope.releases
          .map(_releaseRecordToInventoryMap)
          .toList(growable: false);
      final runtimeSnapshot = _resourceUsageSnapshotFromRecord(
        scope.runtimeSnapshot,
      );
      final latestDeployments = await ref
          .read(appDeploymentHistoryRepositoryProvider)
          .listForProject(project.id, limit: 1);
      final latestDeployment = latestDeployments.isEmpty
          ? null
          : latestDeployments.first;
      final existingSnapshot = _liveSnapshotByProject[project.id];
      final readModel = buildProjectWebAppReadModel(
        project: project,
        scope: scope,
        latestDeployment: latestDeployment,
        fallbackRepo: existingSnapshot?.repo,
        fallbackCommit: existingSnapshot?.commit,
        fallbackLastDuration: existingSnapshot?.lastDuration,
      );
      final hydratedSnapshot = _liveSnapshotFromReadModel(readModel);
      setState(() {
        _releaseInventoryByProject[project.id] = releases;
        _webAppReadModelByProject[project.id] = readModel;
        _liveSnapshotByProject[project.id] = hydratedSnapshot;
        _releaseInventoryLoadingByProject[project.id] = false;
        _releaseInventoryErrorByProject[project.id] = null;
        _resourceUsageByProject[project.id] = runtimeSnapshot;
        _resourceUsageRequestedByProject[project.id] =
            scope.runtimeSnapshot?.resourceCheckedAt != null;
      });
      await ref
          .read(gitHubIntegrationProvider.notifier)
          .restoreLatestDeployFailure(
            projectId: project.id,
            server: selectedServer,
          );
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _releaseInventoryByProject[project.id] = const <Map<String, dynamic>>[];
        _releaseInventoryLoadingByProject[project.id] = false;
        _releaseInventoryErrorByProject[project.id] =
            'Could not read saved release history: $error';
      });
    }
  }

  _LiveAppSnapshot _liveSnapshotFromReadModel(
    ProjectWebAppReadModel readModel,
  ) {
    return _LiveAppSnapshot(
      repo: readModel.repo,
      branch: readModel.branch,
      commit: readModel.commit,
      url: readModel.url,
      health: readModel.health,
      publicHealth: readModel.publicHealth,
      deployStatus: _deployStatusFromReadModel(readModel.deployState),
      lastDeployAt: readModel.lastDeployAt,
      lastDuration: readModel.lastDuration,
    );
  }

  GitHubDeployStatus _deployStatusFromReadModel(
    ProjectWebAppReadDeployState state,
  ) {
    return switch (state) {
      ProjectWebAppReadDeployState.latestDeploymentFailed =>
        GitHubDeployStatus.error,
      ProjectWebAppReadDeployState.idle => GitHubDeployStatus.idle,
    };
  }

  // end coverage-gate
  Map<String, dynamic> _releaseRecordToInventoryMap(AppReleaseRecord release) {
    // Propagates FormatException to the inventory banner — policy differs
    // from swallow-decoders; stringify step unified via mapFrom (T-021).
    // The typed fast-path stays: as-is in, as-is out (no identity change).
    Map<String, dynamic>? decodeJsonObject(String? value) {
      if (value == null || value.trim().isEmpty) {
        return null;
      }
      final decoded = jsonDecode(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return mapFrom(decoded);
      }
      return null;
    }

    // List passthrough — nothing to stringify (D-45 pair 2, T-021).
    List<dynamic>? decodeJsonList(String? value) {
      if (value == null || value.trim().isEmpty) {
        return null;
      }
      final decoded = jsonDecode(value);
      return decoded is List ? decoded : null;
    }

    // Hoisted so the collection-ifs promote them; a public final field is
    // never promoted.
    final createdAtRemote = release.createdAtRemote;
    final liveAt = release.liveAt;
    return <String, dynamic>{
      'release_id': release.releaseId,
      'status': release.status,
      'deployment_kind': release.deploymentKind,
      'branch': release.branch,
      if (release.commitSha != null) 'commit_sha': release.commitSha,
      if (release.imageName != null) 'image_name': release.imageName,
      if (release.webContainerName != null)
        'web_container_name': release.webContainerName,
      if (release.appPort != null) 'app_port': release.appPort,
      if (createdAtRemote != null)
        'created_at': createdAtRemote.toIso8601String(),
      if (liveAt != null) 'live_at': liveAt.toIso8601String(),
      if (release.rollbackFromReleaseId != null)
        'rollback_from_release_id': release.rollbackFromReleaseId,
      if (release.rollbackReason != null)
        'rollback_reason': release.rollbackReason,
      if (release.runtimeEnvJson != null)
        'runtime_env': decodeJsonObject(release.runtimeEnvJson),
      if (release.workersJson != null)
        'workers': decodeJsonList(release.workersJson),
    };
  }

  // Snapshot wrap + swallow kept; inner stringify via mapFrom (T-021).
  _ResourceUsageSnapshot? _resourceUsageSnapshotFromRecord(
    AppRuntimeSnapshotRecord? record,
  ) {
    final payload = record?.resourceUsageJson;
    if (payload == null || payload.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        return _ResourceUsageSnapshot.fromPayload(decoded);
      }
      if (decoded is Map) {
        return _ResourceUsageSnapshot.fromPayload(mapFrom(decoded));
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  void _syncRepositorySelectionFromProject(
    GitHubIntegrationState gitState,
    Project? project,
  ) {
    if (project == null || !gitState.isConnected) {
      return;
    }
    final preferred = project.repositoryFullName?.trim();
    if (preferred == null || preferred.isEmpty) {
      // Only clear repository selection when the user switches to a different
      // project project with no saved repository. Do not clear during rebuilds
      // for the same project (for example, resource usage polling updates).
      if (_repositorySelectionSyncedProjectId == project.id) {
        return;
      }
      _repositorySelectionSyncedProjectId = project.id;
      if (gitState.selectedRepositoryForProject(project.id) == null) {
        return;
      }
      if (_pendingRepositorySelection == _clearRepositorySelectionToken) {
        return;
      }
      _pendingRepositorySelection = _clearRepositorySelectionToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingRepositorySelection = null;
        if (!mounted) {
          return;
        }
        ref
            .read(gitHubIntegrationProvider.notifier)
            .selectRepository(null, projectId: project.id);
      });
      return;
    }
    _repositorySelectionSyncedProjectId = project.id;
    if (gitState.selectedRepositoryForProject(project.id) == preferred) {
      return;
    }
    if (!gitState.repositories.any((repo) => repo.fullName == preferred)) {
      return;
    }
    if (_pendingRepositorySelection == preferred) {
      return;
    }
    _pendingRepositorySelection = preferred;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingRepositorySelection = null;
      if (!mounted) {
        return;
      }
      ref
          .read(gitHubIntegrationProvider.notifier)
          .selectRepository(preferred, projectId: project.id);
    });
  }

  String _friendlyDeployLabel(GitHubDeployStatus status) {
    return switch (status) {
      GitHubDeployStatus.idle => 'Ready',
      GitHubDeployStatus.generatingServerKey ||
      GitHubDeployStatus.registeringDeployKey => 'Preparing access',
      GitHubDeployStatus.cloningRepository => 'Fetching code',
      GitHubDeployStatus.buildingRelease => 'Building web app',
      GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation =>
        'Confirmation needed',
      GitHubDeployStatus.success => 'Ready',
      GitHubDeployStatus.error => 'Attention needed',
    };
  }

  String _statusBadgeLabel({
    required GitHubDeployStatus deployStatus,
    required ContainerRuntimeStatus health,
    required AppPublicHealthSnapshot publicHealth,
    required bool disconnected,
    required bool hasDeploymentRecord,
  }) {
    if (disconnected) {
      return 'Disconnected';
    }
    if (deployStatus == GitHubDeployStatus.idle) {
      if (!hasDeploymentRecord) {
        return 'Not deployed';
      }
      if (health.effectiveStatus == ContainerRuntimeEffectiveStatus.ready &&
          publicHealth.needsAttention) {
        return 'Needs attention';
      }
      if (health.effectiveStatus == ContainerRuntimeEffectiveStatus.ready &&
          publicHealth.enabled &&
          publicHealth.status == AppPublicHealthStatus.unknown) {
        return 'Public URL not checked';
      }
      return health.label;
    }
    if (deployStatus == GitHubDeployStatus.success &&
        publicHealth.needsAttention) {
      return 'Needs attention';
    }
    if (deployStatus == GitHubDeployStatus.success &&
        publicHealth.enabled &&
        publicHealth.status == AppPublicHealthStatus.unknown) {
      return 'Public URL not checked';
    }
    return _friendlyDeployLabel(deployStatus);
  }

  // coverage-gate: handle_github_transition
  void _handleGitHubTransition(
    GitHubIntegrationState? previous,
    GitHubIntegrationState next,
  ) {
    final selectedProject = ref.read(selectedProjectProvider);
    final activeProjectId = next.activeDeployProjectId;
    final previousDeployState = previous?.deployStateForProject(
      activeProjectId,
    );
    final nextDeployState = next.deployStateForProject(activeProjectId);
    final wasRunning = previousDeployState?.isRunning == true;
    final isRunning = nextDeployState.isRunning;
    final awaitingRepositoryHostKeyConfirmation =
        nextDeployState.deployStatus ==
        GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation;
    final deployTransition =
        wasRunning ||
        isRunning ||
        awaitingRepositoryHostKeyConfirmation ||
        (next.activeDeployProjectId != null &&
            (nextDeployState.deployStatus == GitHubDeployStatus.success ||
                nextDeployState.deployStatus == GitHubDeployStatus.error) &&
            previousDeployState?.deployStatus != nextDeployState.deployStatus);
    final project = deployTransition
        ? _projectForDeployState(next.activeDeployProjectId) ?? selectedProject
        : selectedProject;
    if (project == null) {
      return;
    }
    final liveSnapshot = _ensureProjectState(project);

    final projectId = project.id;
    final projectDeployState = next.deployStateForProject(projectId);
    final previousProjectDeployState = previous?.deployStateForProject(
      projectId,
    );
    _maybeShowRepositoryHostKeyConfirmationDialog(
      projectId: projectId,
      project: project,
      deployState: projectDeployState,
    );
    final deployRepository =
        projectDeployState.activeRepositoryFullName ??
        projectDeployState.selectedRepositoryFullName ??
        next.activeDeployRepositoryFullName ??
        next.selectedRepositoryFullName;
    final now = DateTime.now();
    final transitionedToSuccess =
        previousProjectDeployState?.deployStatus !=
            GitHubDeployStatus.success &&
        projectDeployState.deployStatus == GitHubDeployStatus.success;

    if (transitionedToSuccess) {
      _lastDeployedEnvByProject[projectId] = _currentEnvMap(projectId);
      _recomputeEnvChangeState(projectId);
    }

    if (!wasRunning && isRunning) {
      _activeDeployStartedAt = now;
      _liveSnapshotByProject[projectId] = liveSnapshot.copyWith(
        deployStatus: projectDeployState.deployStatus,
        health: const ContainerRuntimeStatus.provisioning(),
        repo: deployRepository ?? liveSnapshot.repo,
        branch: _branchController.text.trim().isEmpty
            ? 'main'
            : _branchController.text.trim(),
      );
      if (mounted) {
        setState(() {});
      }
      return;
    }

    if (wasRunning && !isRunning) {
      final completedAt = now;
      final startedAt = _activeDeployStartedAt;
      _activeDeployStartedAt = null;
      final duration = startedAt == null
          ? const Duration(seconds: 0)
          : completedAt.difference(startedAt);

      final commit =
          extractCommitHashFromTimeline(projectDeployState.deployTimeline) ??
          liveSnapshot.commit;
      final branch = liveSnapshot.branch.trim().isEmpty
          ? 'main'
          : liveSnapshot.branch;
      final url = liveSnapshot.url;
      final successful =
          projectDeployState.deployStatus == GitHubDeployStatus.success;
      final failed =
          projectDeployState.deployStatus == GitHubDeployStatus.error;
      if (successful || failed) {
        _liveSnapshotByProject[projectId] = liveSnapshot.copyWith(
          deployStatus: projectDeployState.deployStatus,
          health: successful
              ? ContainerRuntimeStatus.fromStoredHealthStatus(
                  projectDeployState.processReadinessStatus,
                )
              : ContainerRuntimeStatus.fromStoredHealthStatus('unhealthy'),
          publicHealth: successful
              ? (projectDeployState.publicHealth ??
                    const AppPublicHealthSnapshot.unknown())
              : liveSnapshot.publicHealth,
          repo: deployRepository ?? liveSnapshot.repo,
          branch: branch,
          commit: commit,
          url: url,
          lastDeployAt: completedAt,
          lastDuration: duration,
        );
        if (successful) {
          _lastDeployedEnvByProject[projectId] = _currentEnvMap(projectId);
          _recomputeEnvChangeState(projectId);
          _resourceUsageRequestedByProject[projectId] = false;
          final selectedProject = ref.read(selectedProjectProvider);
          if (selectedProject != null && selectedProject.id == projectId) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) {
                return;
              }
              _refreshResourceUsage(
                project: selectedProject,
                branch: branch,
                appPort: int.tryParse(_appPortController.text.trim()) ?? 3000,
                selectedRepository: deployRepository,
                domain: _primaryDomainController.text.trim(),
                markRequested: true,
              );
            });
          }
        }
      } else {
        _liveSnapshotByProject[projectId] = liveSnapshot.copyWith(
          deployStatus: projectDeployState.deployStatus,
        );
      }

      if (mounted) {
        setState(() {});
      }
      return;
    }

    _liveSnapshotByProject[projectId] = liveSnapshot.copyWith(
      deployStatus: projectDeployState.deployStatus,
      repo: deployRepository ?? liveSnapshot.repo,
      branch: _branchController.text.trim().isEmpty
          ? 'main'
          : _branchController.text.trim(),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Project? _projectForDeployState(String? projectId) {
    final normalizedProjectId = projectId?.trim();
    if (normalizedProjectId == null || normalizedProjectId.isEmpty) {
      return null;
    }
    final selectedProject = ref.read(selectedProjectProvider);
    if (selectedProject?.id == normalizedProjectId) {
      return selectedProject;
    }
    for (final project in ref.read(projectListProvider)) {
      if (project.id == normalizedProjectId) {
        return project;
      }
    }
    return null;
  }

  // end coverage-gate
  void _maybeShowRepositoryHostKeyConfirmationDialog({
    required String projectId,
    required Project project,
    required GitHubProjectDeployState deployState,
  }) {
    final confirmation = deployState.repositoryHostKeyConfirmation;
    if (confirmation == null) {
      _repositoryHostKeyPromptIdByProject.remove(projectId);
      return;
    }
    final promptId = confirmation.promptId;
    if (_repositoryHostKeyPromptIdByProject[projectId] == promptId) {
      return;
    }
    _repositoryHostKeyPromptIdByProject[projectId] = promptId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _showRepositoryHostKeyConfirmationDialog(
        projectId: projectId,
        project: project,
        confirmation: confirmation,
      );
    });
  }

  Future<void> _showRepositoryHostKeyConfirmationDialog({
    required String projectId,
    required Project project,
    required GitHubRepositoryHostKeyConfirmation confirmation,
  }) async {
    final changed = confirmation.reason == 'changed';
    final description = changed
        ? 'The SSH identity for ${confirmation.host} has changed on this server. Continue only if this fingerprint matches GitHub\'s published SSH host key.'
        : 'Deploy Dash has not seen the SSH identity for ${confirmation.host} on this server before. Continue only if this fingerprint matches GitHub\'s published SSH host key.';
    final trusted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppConfirmDialog(
        key: const Key('repository-host-key-dialog'),
        title: 'Confirm GitHub SSH identity',
        description: description,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (confirmation.previousFingerprint != null) ...[
              SelectableText(
                'Previous fingerprint: ${confirmation.previousFingerprint}',
              ),
              const SizedBox(height: 8),
            ],
            SelectableText(
              'Scanned fingerprint: ${confirmation.scannedFingerprint}',
            ),
          ],
        ),
        confirmLabel: 'Trust and retry',
        cancelLabel: 'Cancel',
        onConfirm: () {},
      ),
    );
    if (!mounted) {
      return;
    }
    final gitNotifier = ref.read(gitHubIntegrationProvider.notifier);
    if (trusted != true) {
      _repositoryHostKeyPromptIdByProject.remove(projectId);
      gitNotifier.cancelRepositoryHostKeyConfirmation(projectId);
      return;
    }
    await gitNotifier.trustRepositoryHostKeyAndRetry(projectId);
  }
}
