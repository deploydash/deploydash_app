// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _AppDeploymentDialogMethods on _AppDeploymentSummaryState {
  // coverage-gate: deployment_settings_dialog
  Future<void> _showDeploymentSettingsDialog({
    required String projectId,
    required Project project,
    required GitHubIntegrationNotifier gitNotifier,
    required List<GitHubRepository> repositories,
    required String? selectedRepository,
    required Set<String> enabledDnsProviders,
  }) async {
    final availableDnsProviderSpecs = _enabledDnsProviderSpecs(
      enabledDnsProviders,
    );
    final supportsDnsTls = availableDnsProviderSpecs.isNotEmpty;
    final initialTlsMode = _tlsChallengeModeFor(projectId);
    var initialDnsProvider = _tlsDnsProviderFor(projectId);
    if (!supportsDnsTls ||
        (initialDnsProvider != null &&
            !enabledDnsProviders.contains(initialDnsProvider))) {
      initialDnsProvider = null;
    }

    final result = await showDialog<AppDeploymentSettingsDialogResult>(
      context: context,
      builder: (dialogContext) => AppDeploymentSettingsDialog(
        repositories: repositories,
        initialRepository: selectedRepository,
        initialPrimaryDomain: _primaryDomainController.text.trim(),
        initialDomainRoutingMode: _domainRoutingModeFor(projectId),
        initialBranch: _branchController.text,
        initialPortText: _appPortController.text,
        initialRuntimeSelectionId: _runtimeSelectionFor(projectId),
        initialBuildCommand: _buildCommandFor(projectId),
        initialRunCommand: _runCommandFor(projectId),
        initialAppSubdirectory: _appSubdirectoryFor(projectId),
        availableDnsProviderSpecs: availableDnsProviderSpecs,
        initialTlsChallengeMode: supportsDnsTls && initialTlsMode == 'dns'
            ? AppDeploymentTlsChallengeMode.dns
            : AppDeploymentTlsChallengeMode.http,
        initialDnsProvider: initialDnsProvider,
        initialDnsCredentials: _tlsDnsCredentialsFor(projectId),
        initialPublicHealthCheckEnabled: project.publicHealthCheckEnabled,
        initialPublicHealthCheckPath: project.publicHealthCheckPath,
      ),
    );
    if (!mounted || result == null) {
      return;
    }

    setState(() {
      _primaryDomainController.text = result.primaryDomain;
      _branchController.text = result.deployBranch;
      _appPortController.text = result.appPort.toString();
      _railpackProviderByProject[projectId] = result.railpackProvider;
      _domainRoutingModeByProject[projectId] = result.domainRoutingMode;
      _buildCommandByProject[projectId] = result.railpackBuildCommand;
      _runCommandByProject[projectId] = result.railpackRunCommand;
      _appSubdirectoryByProject[projectId] = result.appSubdirectory ?? '';
      _tlsChallengeModeByProject[projectId] = result.tlsChallengeMode;
      _tlsDnsProviderByProject[projectId] = result.tlsDnsProvider;
      _tlsDnsCredentialsByProject[projectId] = result.tlsDnsCredentials;
      final snapshot = _liveSnapshotByProject[projectId];
      if (snapshot != null) {
        _liveSnapshotByProject[projectId] = snapshot.copyWith(
          repo: result.repositoryFullName,
          branch: result.deployBranch,
          url: 'https://${result.canonicalDomain}',
          publicHealth: AppPublicHealthSnapshot(
            enabled: result.publicHealthCheckEnabled,
            status: result.publicHealthCheckEnabled
                ? AppPublicHealthStatus.unknown
                : AppPublicHealthStatus.skipped,
            path: result.publicHealthCheckPath,
          ),
        );
      }
    });

    ref
        .read(projectListProvider.notifier)
        .updateDeploymentConfig(
          projectId: projectId,
          primaryDomain: result.primaryDomain,
          domainRoutingMode: result.domainRoutingMode,
          repositoryFullName: result.repositoryFullName,
          appSubdirectory: result.appSubdirectory,
          deployBranch: result.deployBranch,
          appPort: result.appPort,
          publicHealthCheckEnabled: result.publicHealthCheckEnabled,
          publicHealthCheckPath: result.publicHealthCheckPath,
          railpackNodeMode: 'auto',
          railpackProvider: result.railpackProvider,
          tlsChallengeMode: result.tlsChallengeMode,
          tlsDnsProvider: result.tlsDnsProvider,
          tlsDnsCredentials: result.tlsDnsCredentials,
          sqliteStorageEnabled: project.sqliteStorageEnabled,
          sqliteVolumeName: project.sqliteVolumeName,
          sqliteMountPath: project.sqliteMountPath,
          sqliteFileName: project.sqliteFileName,
          railpackBuildCommand: result.railpackBuildCommand,
          railpackRunCommand: result.railpackRunCommand,
        );
    appDeploymentMaybeSelectUpdatedRepository(
      currentRepository: selectedRepository,
      nextRepository: result.repositoryFullName,
      onRepositorySelected: gitNotifier.selectRepository,
    );
    _showCopiedSnack('Deployment settings saved.');
  }

  // end coverage-gate
  Future<void> _showEnvEditorDialog({
    required String projectId,
    required GitHubIntegrationNotifier gitNotifier,
    required String domainValue,
    required String branchValue,
    required int parsedAppPort,
    required bool canRedeployBase,
  }) async {
    final result = await showDialog<AppDeploymentEnvEditorDialogResult>(
      context: context,
      builder: (_) => AppDeploymentEnvEditorDialog(
        initialRows: _envRows(projectId)
            .map(
              (row) => AppDeploymentEnvEditorDialogRow(
                key: row.key,
                value: row.value,
                secret: row.secret,
                changedSinceLastDeploy: row.changedSinceLastDeploy,
              ),
            )
            .toList(growable: false),
        lastDeployedSnapshot:
            _lastDeployedEnvByProject[projectId] ?? const <String, String>{},
        canSaveAndRedeploy: canRedeployBase,
      ),
    );
    if (result == null) {
      return;
    }

    final normalized = result.rows
        .map(
          (row) => _EnvVarRowState(
            key: row.key,
            value: row.value,
            secret: row.secret,
            changedSinceLastDeploy: row.changedSinceLastDeploy,
          ),
        )
        .toList(growable: false);
    setState(() {
      _envVarsByProject[projectId] = normalized;
      _recomputeEnvChangeState(projectId);
    });
    try {
      await _persistEnvRows(projectId, normalized);
    } on StateError {
      if (!mounted) {
        return;
      }
      _showCopiedSnack(
        'Could not save environment variables to local database.',
      );
    }
    _showCopiedSnack('Environment variables saved.');
    if (!result.redeployRequested) {
      return;
    }
    unawaited(
      gitNotifier.deploySelectedRepository(
        primaryDomain: domainValue,
        branch: branchValue,
        appPort: parsedAppPort,
        railpackBuildCommand: _buildCommandFor(projectId),
        railpackRunCommand: _runCommandFor(projectId),
        railpackProvider: _railpackProviderFor(projectId),
        appSubdirectory: _normalizedAppSubdirectory(
          _appSubdirectoryFor(projectId),
        ),
      ),
    );
  }

  Future<void> _showDisconnectDialog(Project project) async {
    _disconnectConfirmController.clear();
    _disconnectAcknowledge = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final isNameMatch =
                _disconnectConfirmController.text.trim() == project.name.trim();
            final canConfirm = isNameMatch && _disconnectAcknowledge;
            return AppDestructiveConfirmDialog(
              title: 'Remove web app runtime',
              description:
                  'This removes web app code and runtime containers only. '
                  'Database, email, DNS, and project metadata are kept.',
              confirmLabel: 'Remove web app',
              confirmEnabled: canConfirm,
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Type "${project.name}" to confirm.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _disconnectConfirmController,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      hintText: project.name,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _disconnectAcknowledge,
                    onChanged: (value) {
                      setDialogState(() {
                        _disconnectAcknowledge = value ?? false;
                      });
                    },
                    title: const Text(
                      'I understand this action can cause downtime.',
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final selectedRepository = ref
        .read(gitHubIntegrationProvider)
        .selectedRepositoryFullName;
    final branchValue = _branchController.text.trim().isEmpty
        ? 'main'
        : _branchController.text.trim();
    final parsedPort = int.tryParse(_appPortController.text.trim()) ?? 3000;
    final domainValue = _primaryDomainController.text.trim();

    setState(() {
      _runtimeActionInFlightByProject[project.id] = true;
    });

    final result = await _runAppRuntimeOperation(
      operationId: 'disconnect',
      project: project,
      branch: branchValue,
      appPort: parsedPort,
      selectedRepository: selectedRepository,
      domain: domainValue,
    );
    if (!mounted) {
      return;
    }

    setState(() {
      _runtimeActionInFlightByProject[project.id] = false;
      if (result.ok) {
        _appDisconnectedByProject[project.id] = true;
        final snapshot = _liveSnapshotByProject[project.id];
        if (snapshot != null) {
          _liveSnapshotByProject[project.id] = snapshot.copyWith(
            health: const ContainerRuntimeStatus.stopped(),
            deployStatus: GitHubDeployStatus.idle,
            lastDeployAt: DateTime.now(),
          );
        }
      }
    });

    if (result.ok) {
      ref
          .read(projectListProvider.notifier)
          .updateRuntimeState(projectId: project.id, appDisconnected: true);
    }
    _showCopiedSnack(result.message);
  }

  bool _isValidDomain(String value) {
    final candidate = value.trim().toLowerCase();
    if (candidate.isEmpty || candidate == 'not configured') {
      return false;
    }
    final fqdn = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
    );
    return fqdn.hasMatch(candidate);
  }

  bool _isValidBranch(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty) {
      return false;
    }
    return RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(candidate);
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) {
      return 'Never';
    }
    return '${timestamp.year.toString().padLeft(4, '0')}-'
        '${timestamp.month.toString().padLeft(2, '0')}-'
        '${timestamp.day.toString().padLeft(2, '0')} '
        '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}';
  }
}
