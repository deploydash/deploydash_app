// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _AppDeploymentRuntimeMethods on _AppDeploymentSummaryState {
  // coverage-gate: app_runtime_operation
  Future<_RuntimeActionResult> _runAppRuntimeOperation({
    required String operationId,
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
  }) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      return const _RuntimeActionResult(
        ok: false,
        message: 'No active server selected.',
      );
    }
    final connection = await buildAppDeploymentConnectionPayload(
      ref.read(serverConnectionPayloadResolverProvider),
      selectedServer,
    );
    if (connection == null) {
      return const _RuntimeActionResult(
        ok: false,
        message: 'Selected server credentials are incomplete.',
      );
    }

    final settings = await _buildWorkflowSettings(
      project: project,
      branch: branch,
      appPort: appPort,
      selectedRepository: selectedRepository,
      domain: domain,
    );

    try {
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: selectedServer,
        surface: 'app',
        operationType: operationId,
        workflowId: 'app',
        operationId: operationId,
        connection: connection,
        params: {'dry_run': false, 'settings': settings},
      );
      final response = journaled.response;
      if (response['status'] == 'success') {
        await journaled.markCommitted(ref);
        return _RuntimeActionResult(
          ok: true,
          message: messageOr(response['msg'], 'Runtime action completed.'),
        );
      }
      return _RuntimeActionResult(
        ok: false,
        message: messageOr(response['msg'], 'Runtime action failed.'),
      );
    } catch (error) {
      return _RuntimeActionResult(
        ok: false,
        message: 'Runtime action failed: $error',
      );
    }
  }

  // end coverage-gate
  /// Resolves the connection a refresh call runs on, or null when no refresh
  /// can proceed. Mechanics only (D-43 NARROW): the null DISPOSITION (silent
  /// return vs error-state) stays at each caller — the two callers deliberately
  /// differ and this helper must not pick a winner.
  Future<Map<String, dynamic>?> _resolveRefreshConnection() async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      return null;
    }
    final connection = await buildAppDeploymentConnectionPayload(
      ref.read(serverConnectionPayloadResolverProvider),
      selectedServer,
    );
    if (!mounted) {
      return null;
    }
    return connection;
  }

  Future<void> _refreshResourceUsage({
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
    bool markRequested = true,
  }) async {
    final projectId = project.id;
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      return;
    }
    final connection = await _resolveRefreshConnection();
    if (connection == null) {
      return;
    }

    if (_resourceUsageBusyRegistry.isBusy(
      scopeKey: projectId,
      kind: _resourceUsageRunKind,
      id: _resourceUsageBusyId,
    )) {
      return;
    }
    if (markRequested) {
      final lastRequestedAt = _lastResourceUsageRequestedAtByProject[projectId];
      if (lastRequestedAt != null &&
          DateTime.now().difference(lastRequestedAt) <
              const Duration(seconds: 6)) {
        return;
      }
    }

    final run = _resourceUsageRuns.capture(
      scopeKey: projectId,
      kind: _resourceUsageRunKind,
    );
    final busyKey = _resourceUsageBusyRegistry.markBusy(
      scopeKey: projectId,
      kind: _resourceUsageRunKind,
      id: _resourceUsageBusyId,
    );
    _lastResourceUsageRequestedAtByProject[projectId] = DateTime.now();

    if (mounted) {
      setState(() {
        _resourceUsageErrorByProject[projectId] = null;
        if (markRequested) {
          _resourceUsageRequestedByProject[projectId] = true;
        }
      });
    }

    try {
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'app',
                    operationId: 'resource_usage',
                    connection: connection,
                    params: {
                      'dry_run': false,
                      'settings': await _buildWorkflowSettings(
                        project: project,
                        branch: branch,
                        appPort: appPort,
                        selectedRepository: selectedRepository,
                        domain: domain,
                      ),
                    },
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (!_resourceUsageRuns.isCurrent(run)) {
        return;
      }
      if (response['status'] == 'success') {
        final payload = response['resource_usage'];
        final sqlitePayload = response['sqlite_storage'];
        final containerStatusPayload = response['container_status'];
        final publicHealthPayload = response['public_health'];
        final publicHealth = AppPublicHealthSnapshot.fromPayload(
          publicHealthPayload is Map ? publicHealthPayload : null,
        );
        final containerStatus = containerStatusPayload is Map
            ? ContainerRuntimeStatus.fromMap(containerStatusPayload)
            : null;
        _ResourceUsageSnapshot? snapshot;
        _SqliteStorageSnapshot? sqliteSnapshot;
        if (payload is Map) {
          final normalized = stringifyJsonKeys(payload);
          snapshot = _ResourceUsageSnapshot.fromPayload(normalized);
        }
        if (sqlitePayload is Map) {
          final normalized = stringifyJsonKeys(sqlitePayload);
          sqliteSnapshot = _SqliteStorageSnapshot.fromPayload(normalized);
        } else if (project.sqliteStorageEnabled) {
          sqliteSnapshot = _SqliteStorageSnapshot.fromProject(project);
        }
        final checkedAt = DateTime.now().toUtc();
        await ref
            .read(appReleaseProvider.notifier)
            .upsertRuntimeSnapshot(
              AppRuntimeSnapshotRecord(
                projectId: projectId,
                serverId: selectedServer.id,
                resourceUsageJson: payload is Map ? jsonEncode(payload) : null,
                healthStatus: containerStatus?.effectiveStatusKey,
                publicHealthJson: publicHealth.encode(),
                healthCheckedAt: containerStatus == null ? null : checkedAt,
                resourceCheckedAt: checkedAt,
                updatedAt: checkedAt,
              ),
            );
        setState(() {
          final liveSnapshot = _liveSnapshotByProject[projectId];
          if (liveSnapshot != null) {
            _liveSnapshotByProject[projectId] = liveSnapshot.copyWith(
              health: containerStatus ?? liveSnapshot.health,
              publicHealth: publicHealth,
            );
          }
          _resourceUsageByProject[projectId] = snapshot;
          _sqliteStorageByProject[projectId] = sqliteSnapshot;
          _resourceUsageErrorByProject[projectId] = snapshot == null
              ? 'Container stats are unavailable until the web app container is running.'
              : null;
          _resourceUsageBusyRegistry.remove(busyKey);
        });
        return;
      }

      if (!_resourceUsageRuns.isCurrent(run)) {
        return;
      }
      setState(() {
        _resourceUsageErrorByProject[projectId] = messageOr(
          response['msg'],
          'Could not read container stats.',
        );
        _resourceUsageBusyRegistry.remove(busyKey);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!_resourceUsageRuns.isCurrent(run)) {
        return;
      }
      setState(() {
        _resourceUsageErrorByProject[projectId] =
            'Could not read container stats: $error';
        _resourceUsageBusyRegistry.remove(busyKey);
      });
    }
  }

  List<Map<String, dynamic>> _releasePayloadsFromResponse(
    Map<String, dynamic> response,
  ) {
    final releaseInventory = response['release_inventory'];
    final inventoryReleases = releaseInventory is Map
        ? releaseInventory['releases']
        : null;
    final releasesPayload = inventoryReleases is List
        ? inventoryReleases
        : response['releases'];
    if (releasesPayload is! List) {
      return const <Map<String, dynamic>>[];
    }
    return releasesPayload
        .whereType<Map<dynamic, dynamic>>()
        .map(stringifyJsonKeys)
        .toList(growable: false);
  }

  Future<void> _persistReleaseResponse({
    required String projectId,
    required String serverId,
    required Map<String, dynamic> response,
  }) async {
    final observedAt = DateTime.now().toUtc();
    final records = AppReleaseRepository.recordsFromBackendResponse(
      projectId: projectId,
      serverId: serverId,
      payload: response,
      observedAt: observedAt,
    );
    if (records.isEmpty) {
      return;
    }
    final hasFullInventory =
        response['release_inventory'] is Map || response['releases'] is List;
    final notifier = ref.read(appReleaseProvider.notifier);
    if (hasFullInventory) {
      await notifier.replaceReleases(
        projectId: projectId,
        serverId: serverId,
        releases: records,
      );
      if (mounted) {
        setState(() {
          _releaseInventoryByProject[projectId] = _releasePayloadsFromResponse(
            response,
          );
        });
      }
      return;
    }
    for (final record in records) {
      await notifier.upsertRelease(record);
    }
  }

  Future<void> _refreshReleaseInventory({
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
  }) async {
    final projectId = project.id;
    if (mounted) {
      setState(() {
        _releaseInventoryLoadingByProject[projectId] = true;
        _releaseInventoryErrorByProject[projectId] = null;
      });
    }
    final connection = await _resolveRefreshConnection();
    if (connection == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _releaseInventoryLoadingByProject[projectId] = false;
        _releaseInventoryErrorByProject[projectId] =
            'Select a server to read release history.';
      });
      return;
    }
    try {
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'app',
                    operationId: 'list_releases',
                    connection: connection,
                    params: {
                      'dry_run': false,
                      'settings': await _buildWorkflowSettings(
                        project: project,
                        branch: branch,
                        appPort: appPort,
                        selectedRepository: selectedRepository,
                        domain: domain,
                      ),
                    },
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (response['status'] == 'success') {
        final observedAt = DateTime.now().toUtc();
        final releases = _releasePayloadsFromResponse(response);
        final selectedServer = ref.read(selectedServerProvider);
        if (selectedServer != null) {
          final releaseRecords =
              AppReleaseRepository.recordsFromBackendResponse(
                projectId: projectId,
                serverId: selectedServer.id,
                payload: response,
                observedAt: observedAt,
              );
          await ref
              .read(appReleaseProvider.notifier)
              .replaceReleases(
                projectId: projectId,
                serverId: selectedServer.id,
                releases: releaseRecords,
              );
        }
        setState(() {
          _releaseInventoryByProject[projectId] = releases;
          _releaseInventoryLoadingByProject[projectId] = false;
          _releaseInventoryErrorByProject[projectId] = null;
        });
        return;
      }
      setState(() {
        _releaseInventoryLoadingByProject[projectId] = false;
        _releaseInventoryErrorByProject[projectId] = messageOr(
          response['msg'],
          'Could not read release history.',
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _releaseInventoryLoadingByProject[projectId] = false;
        _releaseInventoryErrorByProject[projectId] =
            'Could not read release history: $error';
      });
    }
  }

  Future<void> _rollbackToRelease({
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
    required String? releaseId,
  }) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      await showAppNotice(
        context,
        title: 'Server needed',
        message: 'Select a server before rolling back this web app.',
      );
      return;
    }
    final connection = await buildAppDeploymentConnectionPayload(
      ref.read(serverConnectionPayloadResolverProvider),
      selectedServer,
    );
    if (!mounted) {
      return;
    }
    if (connection == null) {
      await showAppNotice(
        context,
        title: 'Server needed',
        message: 'Select a server before rolling back this web app.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppConfirmDialog(
        title: releaseId == null
            ? 'Rollback to previous release'
            : 'Rollback to this release',
        description: releaseId == null
            ? 'Deploy Dash will switch this web app back to the most recent retained release.'
            : 'Deploy Dash will switch this web app back to release $releaseId.',
        confirmLabel: 'Rollback',
        onConfirm: () {},
      ),
    );
    if (confirmed != true) {
      return;
    }
    setState(() {
      _runtimeActionInFlightByProject[project.id] = true;
    });
    try {
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: selectedServer,
        surface: 'app',
        operationType: 'rollback',
        workflowId: 'app',
        operationId: 'rollback',
        connection: connection,
        params: {
          'dry_run': false,
          'release_id': releaseId,
          'settings': await _buildWorkflowSettings(
            project: project,
            branch: branch,
            appPort: appPort,
            selectedRepository: selectedRepository,
            domain: domain,
          ),
        },
      );
      final response = journaled.response;
      if (!mounted) {
        return;
      }
      final success = response['status'] == 'success';
      if (success) {
        final commit = response['commit_sha']?.toString().trim();
        ref
            .read(projectListProvider.notifier)
            .updateLastDeployState(
              projectId: project.id,
              commit: (commit != null && commit.isNotEmpty)
                  ? commit
                  : 'unknown',
              deployedAt: DateTime.now(),
            );
        await ref
            .read(appDeploymentHistoryRepositoryProvider)
            .append(
              projectId: project.id,
              status: 'success',
              releaseId: response['release_id']?.toString(),
              deploymentKind: 'rollback',
              rollbackFromReleaseId: response['rollback_from_release_id']
                  ?.toString(),
              deployedAt: DateTime.now(),
              durationSeconds: 0,
              actor: localDeployActor(),
              branch: branch,
              commit: (commit != null && commit.isNotEmpty)
                  ? commit
                  : 'unknown',
            );
        await _persistReleaseResponse(
          projectId: project.id,
          serverId: selectedServer.id,
          response: response,
        );
        await journaled.markCommitted(ref);
      }
      if (!mounted) {
        return;
      }
      await showAppNotice(
        context,
        title: success ? 'Rollback finished' : 'Rollback failed',
        message: messageOr(
          response['msg'],
          success ? 'Rollback completed.' : 'Rollback failed.',
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      await showAppNotice(
        context,
        title: 'Rollback failed',
        message: 'Rollback failed: $error',
      );
    } finally {
      if (mounted) {
        setState(() {
          _runtimeActionInFlightByProject[project.id] = false;
        });
      }
    }
  }

  Future<void> _runPreflight({
    required bool githubConnected,
    required bool repositorySelected,
    required bool domainValid,
    required bool branchValid,
    required bool portValid,
    required bool appConnected,
  }) async {
    setState(() {
      _isRunningPreflight = true;
      _lastPreflightReport = null;
    });

    await Future<void>.delayed(const Duration(milliseconds: 350));
    final selectedServer = ref.read(selectedServerProvider);
    final checks = <_PreflightCheck>[
      _PreflightCheck(
        label: 'Web app connection state',
        passed: appConnected,
        detail: appConnected
            ? 'Web app is connected and deployable.'
            : 'Reconnect web app before deploying.',
      ),
      _PreflightCheck(
        label: 'GitHub authorization',
        passed: githubConnected,
        detail: githubConnected
            ? 'GitHub session is active.'
            : 'Connect GitHub to continue.',
      ),
      _PreflightCheck(
        label: 'Repository selected',
        passed: repositorySelected,
        detail: repositorySelected
            ? 'Repository selected for deploy.'
            : 'Select a repository.',
      ),
      _PreflightCheck(
        label: 'Server connectivity context',
        passed: selectedServer != null,
        detail: selectedServer == null
            ? 'No active server selected.'
            : 'Deploy target: ${selectedServer.name} (${selectedServer.host}).',
      ),
      _PreflightCheck(
        label: 'Primary domain',
        passed: domainValid,
        detail: domainValid
            ? 'Primary domain is valid.'
            : 'Primary domain must be a valid FQDN.',
      ),
      _PreflightCheck(
        label: 'Branch and web app port',
        passed: branchValid && portValid,
        detail: branchValid && portValid
            ? 'Branch and port look valid.'
            : 'Fix branch or port before deploy.',
      ),
    ];

    if (!mounted) {
      return;
    }

    setState(() {
      _isRunningPreflight = false;
      _lastPreflightReport = _PreflightReport(
        executedAt: DateTime.now(),
        checks: checks,
      );
    });
  }

  void _showCopiedSnack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
