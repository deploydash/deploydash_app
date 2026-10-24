part of '../../project_workspace.dart';

class _WorkersTabContent extends ConsumerStatefulWidget {
  const _WorkersTabContent({this.onOpenWebAppTab});

  final VoidCallback? onOpenWebAppTab;

  @override
  ConsumerState<_WorkersTabContent> createState() => _WorkersTabContentState();
}

class _WorkersTabContentState extends ConsumerState<_WorkersTabContent>
    with WorkspaceScopedConsumerState<_WorkersTabContent> {
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isApplying = false;
  bool _hasUnappliedChanges = false;
  String? _error;
  List<WorkerDraft> _workers = const <WorkerDraft>[];
  List<WorkerDatabaseUser> _databaseUsers = const <WorkerDatabaseUser>[];
  final WorkspaceBusyRegistry _busyWorkers = WorkspaceBusyRegistry();
  WorkerRuntimeSnapshot _runtimeSnapshot = WorkerRuntimeSnapshot.empty;

  @override
  void initState() {
    super.initState();
    _isLoading = true;
  }

  void _scheduleSelectionBind(Project project, Server server) {
    scheduleWorkspaceSelectionBind(
      project: project,
      server: server,
      onBind: _bindSelection,
    );
  }

  Future<void> _bindSelection(Project project, Server server) async {
    final projectId = project.id;
    final currentScope = currentWorkspaceScope;
    if (currentScope != null &&
        currentScope.matches(projectId: projectId, serverId: server.id)) {
      return;
    }
    final bindEpoch = bindWorkspaceSelection(project, server);

    setState(() {
      _isLoading = true;
      _error = null;
      _workers = const <WorkerDraft>[];
      _databaseUsers = const <WorkerDatabaseUser>[];
      _runtimeSnapshot = WorkerRuntimeSnapshot.empty;
      _hasUnappliedChanges = false;
      _busyWorkers.clear();
    });

    try {
      final notifier = ref.read(projectWorkerInstancesProvider.notifier);
      await notifier.loadProject(projectId);
      if (!isCurrentWorkspaceSelection(project, server, bindEpoch)) {
        return;
      }

      final loadedWorkers =
          ref.read(projectWorkerInstancesProvider)[projectId] ?? const [];
      final databaseDiscovery = await _loadDatabaseUsers(project, server);
      await ref
          .read(appReleaseProvider.notifier)
          .loadScope(projectId: projectId, serverId: server.id);
      if (!isCurrentWorkspaceSelection(project, server, bindEpoch)) {
        return;
      }
      final cachedRuntimeSnapshot = _cachedWorkerRuntimeSnapshot(
        projectId: projectId,
        serverId: server.id,
      );

      setState(() {
        _workers = loadedWorkers
            .map(WorkerDraft.fromWorker)
            .toList(growable: false);
        _databaseUsers = databaseDiscovery.users;
        _runtimeSnapshot = cachedRuntimeSnapshot;
        _hasUnappliedChanges = !workerRuntimeSnapshotMatches(
          workers: loadedWorkers,
          snapshot: cachedRuntimeSnapshot,
        );
        _isLoading = false;
      });
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, bindEpoch)) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = couldntMessage('load worker settings', error);
      });
    }
  }

  bool _isWorkerBusy(WorkerDraft worker) {
    return _busyWorkers.isBusy(
      scope: currentWorkspaceScope,
      kind: 'worker',
      id: worker.id,
    );
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return buildAppDeploymentConnectionPayload(
      ref.read(serverConnectionPayloadResolverProvider),
      server,
    );
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

  String? _normalizedAppSubdirectory(String value) {
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

  Future<Map<String, dynamic>> _buildAppWorkflowSettings({
    required Project project,
    required Server server,
  }) async {
    final repository =
        trimOrNull(project.repositoryFullName) ?? 'deploydash/local-app';
    final primaryDomain = project.primaryDomain.trim();
    final envRows = await ref
        .read(appEnvironmentVariableRepositoryProvider)
        .listForProject(project.id);
    final runtimeEnv = <String, String>{};
    for (final row in envRows) {
      final key = row.key.trim();
      if (key.isEmpty) {
        continue;
      }
      if (!project.injectPostgresEnv && isManagedPostgresRuntimeEnvKey(key)) {
        continue;
      }
      runtimeEnv[key] = row.value;
    }

    final settings = <String, dynamic>{
      'project_slug': slugifyProjectName(
        project.name,
        fallback: 'project-workers',
      ),
      'repository_full_name': repository,
      'branch': project.deployBranch.trim().isNotEmpty
          ? project.deployBranch.trim()
          : 'main',
      'primary_domain': _isValidDomain(primaryDomain)
          ? primaryDomain.toLowerCase()
          : null,
      'domain_routing_mode': _normalizedDomainRoutingModeForWorkspace(
        project.domainRoutingMode,
      ),
      'app_port': project.appPort,
      'workers': buildWorkersWorkflowPayload(
        workers: _workers
            .asMap()
            .entries
            .map(
              (entry) => entry.value.toWorkerInstance(
                projectId: project.id,
                sortOrder: entry.key,
              ),
            )
            .toList(growable: false),
      ),
    };
    final normalizedAppSubdirectory = _normalizedAppSubdirectory(
      project.appSubdirectory ?? '',
    );
    if (normalizedAppSubdirectory != null) {
      settings['app_subdirectory'] = normalizedAppSubdirectory;
    }
    if (runtimeEnv.isNotEmpty) {
      settings['runtime_env'] = runtimeEnv;
    }
    final trustNetworkNames = await ref
        .read(projectNetworkTrustRepositoryProvider)
        .listTrustNetworkNamesForProject(project.id);
    if (trustNetworkNames.isNotEmpty) {
      settings['trust_network_names'] = trustNetworkNames;
    }
    final sqliteSnapshotMounts = await ref
        .read(projectSqliteSnapshotRepositoryProvider)
        .buildSnapshotMountPayloadsForConsumer(project.id);
    if (sqliteSnapshotMounts.isNotEmpty) {
      settings['sqlite_snapshot_mounts'] = sqliteSnapshotMounts;
    }
    return settings;
  }

  Future<WorkerDatabaseDiscoveryResult> _loadDatabaseUsers(
    Project project,
    Server server,
  ) async {
    if (!server.serviceDatabaseEnabled) {
      return const WorkerDatabaseDiscoveryResult(users: <WorkerDatabaseUser>[]);
    }
    await ref
        .read(projectManagedDatabaseProvider.notifier)
        .loadScope(projectId: project.id, serverId: server.id);
    final scope = ref
        .read(projectManagedDatabaseProvider)
        .scopeFor(projectId: project.id, serverId: server.id);
    final users = scope.users
        .where((user) => user.engine == 'postgres')
        .map(
          (user) => WorkerDatabaseUser(
            engine: user.engine,
            username: user.username,
            database: user.databaseName,
            accessMode: user.accessMode,
          ),
        )
        .toList(growable: false);

    users.sort((left, right) {
      final engineCompare = left.engine.compareTo(right.engine);
      if (engineCompare != 0) {
        return engineCompare;
      }
      final databaseCompare = left.database.compareTo(right.database);
      if (databaseCompare != 0) {
        return databaseCompare;
      }
      return left.username.compareTo(right.username);
    });
    return WorkerDatabaseDiscoveryResult(users: users);
  }

  WorkerRuntimeSnapshot _cachedWorkerRuntimeSnapshot({
    required String projectId,
    required String serverId,
  }) {
    final snapshot = ref
        .read(appReleaseProvider)
        .scopeFor(projectId: projectId, serverId: serverId)
        .workerRuntimeSnapshot;
    if (snapshot == null || snapshot.snapshotJson.trim().isEmpty) {
      return WorkerRuntimeSnapshot.empty;
    }
    try {
      final decoded = jsonDecode(snapshot.snapshotJson);
      if (decoded is Map<String, dynamic>) {
        return WorkerRuntimeSnapshot.fromResponse(decoded);
      }
      if (decoded is Map) {
        return WorkerRuntimeSnapshot.fromResponse(mapFrom(decoded));
      }
    } on FormatException {
      return WorkerRuntimeSnapshot.empty;
    }
    return WorkerRuntimeSnapshot.empty;
  }

  Future<void> _persistWorkerRuntimeSnapshot({
    required Project project,
    required Server server,
    required Map<String, dynamic> response,
  }) async {
    final now = DateTime.now().toUtc();
    await ref
        .read(appReleaseProvider.notifier)
        .upsertWorkerRuntimeSnapshot(
          WorkerRuntimeSnapshotRecord(
            projectId: project.id,
            serverId: server.id,
            snapshotJson: jsonEncode(response),
            lastCheckedAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> _persistWorkers(String projectId) async {
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final rows = _workers
          .asMap()
          .entries
          .map(
            (entry) => entry.value.toWorkerInstance(
              projectId: projectId,
              sortOrder: entry.key,
            ),
          )
          .toList(growable: false);
      await ref
          .read(projectWorkerInstancesProvider.notifier)
          .replaceProject(projectId, rows);
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Workers saved.')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = 'Couldn’t save worker settings.\n$error';
      });
    }
  }

  Future<void> _refreshDatabaseUsers({
    required Project project,
    required Server server,
  }) async {
    final expectedEpoch = workspaceBindEpoch;
    try {
      final discovery = await _loadDatabaseUsers(project, server);
      if (!isCurrentWorkspaceSelection(project, server, expectedEpoch)) {
        return;
      }
      setState(() {
        _databaseUsers = discovery.users;
      });
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, expectedEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t refresh the database user list.\n$error';
      });
    }
  }

  Future<void> _refreshWorkerStatus({
    required Project project,
    required Server server,
    int? expectedEpoch,
  }) async {
    final operationEpoch = expectedEpoch ?? workspaceBindEpoch;
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _error = serverCredentialsReconnectMessage();
        });
      }
      return;
    }

    if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
      setState(() {
        _error = null;
      });
    }

    try {
      final settings = await _buildAppWorkflowSettings(
        project: project,
        server: server,
      );
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'app',
                    operationId: 'workers_status',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'settings': settings,
                    },
                  ))
              .diagnosticPayload;
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      if (response['status'] != 'success') {
        final message = response['msg']?.toString().trim();
        final details = response['details']?.toString().trim();
        setState(() {
          _error = details != null && details.isNotEmpty
              ? '${message ?? 'Couldn’t load worker status.'}\n$details'
              : (message ?? 'Couldn’t load worker status.');
        });
        return;
      }

      setState(() {
        _runtimeSnapshot = WorkerRuntimeSnapshot.fromResponse(response);
        _hasUnappliedChanges = false;
      });
      await _persistWorkerRuntimeSnapshot(
        project: project,
        server: server,
        response: response,
      );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t load worker status.\n$error';
      });
    }
  }

  Future<void> _applyWorkersRuntime({
    required Project project,
    required Server server,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final messenger = ScaffoldMessenger.of(context);
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    setState(() {
      _isApplying = true;
      _error = null;
    });

    try {
      final settings = await _buildAppWorkflowSettings(
        project: project,
        server: server,
      );
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'workers',
        operationType: 'workers_apply',
        workflowId: 'app',
        operationId: 'workers_apply',
        connection: connection,
        params: <String, dynamic>{'dry_run': false, 'settings': settings},
      );
      final response = journaled.response;
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      if (response['status'] != 'success') {
        final message = response['msg']?.toString().trim();
        final details = response['details']?.toString().trim();
        setState(() {
          _error = details != null && details.isNotEmpty
              ? '${message ?? 'Couldn’t update the worker runtime.'}\n$details'
              : (message ?? 'Couldn’t update the worker runtime.');
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackWorkerEvent(
              action: WorkerAction.apply,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      setState(() {
        _runtimeSnapshot = WorkerRuntimeSnapshot.fromResponse(response);
        _hasUnappliedChanges = false;
      });
      await _persistWorkerRuntimeSnapshot(
        project: project,
        server: server,
        response: response,
      );
      await journaled.markCommitted(ref);
      final message = response['msg']?.toString().trim();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            message == null || message.isEmpty
                ? 'Worker runtime applied.'
                : message,
          ),
        ),
      );
      ref
          .read(appAnalyticsServiceProvider)
          .trackWorkerEvent(
            action: WorkerAction.apply,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t update the worker runtime.\n$error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackWorkerEvent(
            action: WorkerAction.apply,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _isApplying = false;
        });
      }
    }
  }

  Future<void> _runWorkerOperation({
    required Project project,
    required Server server,
    required WorkerDraft worker,
    required String operationId,
    required String successMessage,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final messenger = ScaffoldMessenger.of(context);
    final workerScope = WorkspaceScope(
      projectId: project.id,
      serverId: server.id,
    );
    final busyKey = _busyWorkers.key(
      scope: workerScope,
      kind: 'worker',
      id: worker.id,
    );
    if (_isWorkerBusy(worker)) {
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    setState(() {
      _busyWorkers.markBusy(scope: workerScope, kind: 'worker', id: worker.id);
      _error = null;
    });

    try {
      final settings = await _buildAppWorkflowSettings(
        project: project,
        server: server,
      );
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'workers',
        operationType: operationId,
        workflowId: 'app',
        operationId: operationId,
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'worker_id': worker.id,
          'settings': settings,
        },
      );
      final response = journaled.response;
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        final message = response['msg']?.toString().trim();
        final details = response['details']?.toString().trim();
        setState(() {
          _error = details != null && details.isNotEmpty
              ? '${message ?? 'Couldn’t update this worker.'}\n$details'
              : (message ?? 'Couldn’t update this worker.');
        });
        return;
      }
      setState(() {
        _runtimeSnapshot = WorkerRuntimeSnapshot.fromResponse(response);
      });
      await _persistWorkerRuntimeSnapshot(
        project: project,
        server: server,
        response: response,
      );
      await journaled.markCommitted(ref);
      final message = response['msg']?.toString().trim();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            message == null || message.isEmpty ? successMessage : message,
          ),
        ),
      );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t update this worker.\n$error';
      });
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _busyWorkers.remove(busyKey);
        });
      }
    }
  }

  Future<void> _showWorkerLogs({
    required Project project,
    required Server server,
    required WorkerDraft worker,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final workerScope = WorkspaceScope(
      projectId: project.id,
      serverId: server.id,
    );
    final busyKey = _busyWorkers.key(
      scope: workerScope,
      kind: 'worker',
      id: worker.id,
    );
    if (_isWorkerBusy(worker)) {
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    setState(() {
      _busyWorkers.markBusy(scope: workerScope, kind: 'worker', id: worker.id);
      _error = null;
    });
    try {
      final settings = await _buildAppWorkflowSettings(
        project: project,
        server: server,
      );
      Future<({List<String> lines, String? error})> fetchLogs() async {
        try {
          final response =
              (await ref
                      .read(sshServiceProvider)
                      .runWorkflow(
                        workflowId: 'app',
                        operationId: 'worker_logs',
                        connection: connection,
                        params: <String, dynamic>{
                          'dry_run': false,
                          'worker_id': worker.id,
                          'log_tail_lines': 200,
                          'settings': settings,
                        },
                      ))
                  .diagnosticPayload;
          if (response['status'] != 'success') {
            final message = response['msg']?.toString().trim();
            final details = response['details']?.toString().trim();
            return (
              lines: const <String>[],
              error: details != null && details.isNotEmpty
                  ? '${message ?? 'Couldn’t load worker activity.'}\n$details'
                  : (message ?? 'Couldn’t load worker activity.'),
            );
          }
          final logsPayload = response['logs'];
          final lines = <String>[];
          if (logsPayload is List) {
            for (final line in logsPayload) {
              lines.add(line.toString());
            }
          }
          return (lines: lines, error: null);
        } catch (error) {
          return (
            lines: const <String>[],
            error: 'Couldn’t load worker activity.\n$error',
          );
        }
      }

      final initial = await fetchLogs();
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (initial.error != null) {
        setState(() {
          _error = initial.error;
        });
        return;
      }

      var logLines = initial.lines;
      String? dialogError;
      var dialogLoading = false;

      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              // Captured and reassigned by `refreshLogs` below, so it cannot
              // be promoted where it is read; this rebuild's value can.
              final currentDialogError = dialogError;
              Future<void> refreshLogs() async {
                setDialogState(() {
                  dialogLoading = true;
                  dialogError = null;
                });
                final refreshed = await fetchLogs();
                if (!dialogContext.mounted) {
                  return;
                }
                setDialogState(() {
                  dialogLoading = false;
                  dialogError = refreshed.error;
                  if (refreshed.error == null) {
                    logLines = refreshed.lines;
                  }
                });
              }

              return AppDialogScaffold(
                title: workersLogsTitle(worker.name),
                description:
                    'Use this view when you need to inspect recent worker output.',
                actions: [
                  IconButton(
                    key: const Key('workers-logs-refresh-button'),
                    tooltip: 'Refresh',
                    onPressed: dialogLoading ? null : refreshLogs,
                    icon: const Icon(Icons.refresh, semanticLabel: 'Refresh'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
                child: SizedBox(
                  width: 780,
                  height: 420,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (dialogLoading) ...[
                        const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: 8),
                      ],
                      if (currentDialogError != null) ...[
                        Text(
                          currentDialogError,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: YaruColors.red),
                        ),
                        const SizedBox(height: 8),
                      ],
                      Expanded(
                        child: logLines.isEmpty
                            ? Text(workersLogsEmptyMessage())
                            : SingleChildScrollView(
                                child: SelectableText(logLines.join('\n')),
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = couldntMessage('load worker activity', error);
      });
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _busyWorkers.remove(busyKey);
        });
      }
    }
  }

  Future<WorkerDraft?> _showWorkerEditorDialog({WorkerDraft? initial}) async {
    final nameController = TextEditingController(text: initial?.name ?? '');
    final commandController = TextEditingController(
      text: initial?.startCommand ?? '',
    );
    final cpuController = TextEditingController(
      text: (initial?.cpuLimit ?? 0.5).toString(),
    );
    final memoryController = TextEditingController(
      text: (initial?.memoryMb ?? 256).toString(),
    );
    final diskController = TextEditingController(
      text: (initial?.diskMb ?? 1024).toString(),
    );
    final passwordController = TextEditingController(
      text: initial?.databasePassword ?? '',
    );

    String? selectedDatabaseKey;
    if (initial != null &&
        initial.databaseUser != null &&
        initial.databaseName != null) {
      final engine = initial.databaseEngine?.trim().toLowerCase() ?? 'postgres';
      selectedDatabaseKey =
          '$engine::${initial.databaseUser}::${initial.databaseName}';
      final exists = _databaseUsers.any(
        (user) => user.key == selectedDatabaseKey,
      );
      if (!exists) {
        selectedDatabaseKey = null;
      }
    }

    bool enabled = initial?.enabled ?? true;

    final result = await showDialog<WorkerDraft>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final name = nameController.text.trim();
            final command = commandController.text.trim();
            final cpu = double.tryParse(cpuController.text.trim());
            final memory = int.tryParse(memoryController.text.trim());
            final disk = int.tryParse(diskController.text.trim());
            final selectedUser = selectedDatabaseKey == null
                ? null
                : _databaseUsers
                      .where((user) => user.key == selectedDatabaseKey)
                      .firstOrNull;
            final databasePassword = passwordController.text.trim();

            final nameError = name.isEmpty ? 'Worker name is required.' : null;
            final commandError = command.isEmpty
                ? 'Start command is required.'
                : null;
            final cpuError = cpu == null || cpu < 0.1 || cpu > 64
                ? 'CPU must be between 0.1 and 64.'
                : null;
            final memoryError =
                memory == null || memory < 128 || memory > 1024 * 1024
                ? 'Memory must be 128-1048576 MB.'
                : null;
            final diskError = disk == null || disk < 256 || disk > 1024 * 1024
                ? 'Disk must be 256-1048576 MB.'
                : null;
            final databasePasswordError =
                selectedUser != null && databasePassword.isEmpty
                ? 'Database password is required for selected user.'
                : null;

            final canSave =
                nameError == null &&
                commandError == null &&
                cpuError == null &&
                memoryError == null &&
                diskError == null &&
                databasePasswordError == null;

            return AppFormDialog(
              title: workersEditorTitle(initial != null),
              description: workersEditorDescription(),
              // ignore: sort_child_properties_last
              child: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppTextFormField(
                      fieldKey: const Key('workers-editor-name-field'),
                      controller: nameController,
                      onChanged: (_) => setDialogState(() {}),
                      labelText: 'Worker name',
                      validator: (_) => nameError,
                    ),
                    const SizedBox(height: 10),
                    AppTextFormField(
                      fieldKey: const Key('workers-editor-command-field'),
                      controller: commandController,
                      onChanged: (_) => setDialogState(() {}),
                      labelText: 'Start command',
                      hintText: 'npm run worker:queue',
                      validator: (_) => commandError,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: AppTextFormField(
                            fieldKey: const Key('workers-editor-cpu-field'),
                            controller: cpuController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            onChanged: (_) => setDialogState(() {}),
                            labelText: 'CPU',
                            validator: (_) => cpuError,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: AppNumberFormField(
                            fieldKey: const Key('workers-editor-memory-field'),
                            controller: memoryController,
                            onChanged: (_) => setDialogState(() {}),
                            labelText: 'Memory (MB)',
                            validator: (_) => memoryError,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AppNumberFormField(
                      fieldKey: const Key('workers-editor-disk-field'),
                      controller: diskController,
                      onChanged: (_) => setDialogState(() {}),
                      labelText: 'Disk (MB)',
                      validator: (_) => diskError,
                    ),
                    const SizedBox(height: 10),
                    AppToggleField(
                      fieldKey: const Key('workers-editor-enabled-toggle'),
                      value: enabled,
                      onChanged: (value) {
                        setDialogState(() {
                          enabled = value;
                        });
                      },
                      title: 'Turn on this worker',
                    ),
                    const Divider(height: 22),
                    AppSelectFormField<String>(
                      fieldKey: const Key('workers-editor-db-user-dropdown'),
                      labelText: 'Database user (optional)',
                      value: selectedDatabaseKey,
                      items: [
                        const DropdownMenuItem<String>(
                          value: '',
                          child: Text('No database access'),
                        ),
                        ..._databaseUsers.map(
                          (user) => DropdownMenuItem<String>(
                            value: user.key,
                            child: Text(
                              '${user.engineLabel} · ${user.username} on ${user.database} (${user.accessLabel})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          selectedDatabaseKey = (value == null || value.isEmpty)
                              ? null
                              : value;
                          if (selectedDatabaseKey == null) {
                            passwordController.clear();
                          }
                        });
                      },
                    ),
                    if (selectedUser != null) ...[
                      const SizedBox(height: 10),
                      AppPasswordFormField(
                        fieldKey: const Key('workers-editor-db-password-field'),
                        controller: passwordController,
                        onChanged: (_) => setDialogState(() {}),
                        labelText: 'Database password',
                        hintText: 'Enter password for selected database user',
                        validator: (_) => databasePasswordError,
                      ),
                    ],
                  ],
                ),
              ),
              maxWidth: 520,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('workers-editor-save-button'),
                  onPressed:
                      (!canSave ||
                          cpu == null ||
                          memory == null ||
                          disk == null)
                      ? null
                      : () {
                          final resolvedId =
                              initial?.id ??
                              nextWorkerId(
                                nameController.text,
                                _workers.map((worker) => worker.id).toSet(),
                              );
                          Navigator.of(dialogContext).pop(
                            WorkerDraft(
                              id: resolvedId,
                              name: name,
                              startCommand: command,
                              cpuLimit: cpu,
                              memoryMb: memory,
                              diskMb: disk,
                              databaseUser: selectedUser?.username,
                              databaseName: selectedUser?.database,
                              databasePassword: selectedUser == null
                                  ? null
                                  : databasePassword,
                              databaseEngine: selectedUser?.engine,
                              enabled: enabled,
                            ),
                          );
                        },
                  child: const Text('Save worker'),
                ),
              ],
            );
          },
        );
      },
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      nameController.dispose();
      commandController.dispose();
      cpuController.dispose();
      memoryController.dispose();
      diskController.dispose();
      passwordController.dispose();
    });
    return result;
  }

  Future<void> _addWorker(Project project) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != null) {
      await _refreshDatabaseUsers(project: project, server: selectedServer);
    }
    final created = await _showWorkerEditorDialog();
    if (created == null) {
      return;
    }
    setState(() {
      _workers = [..._workers, created];
      _hasUnappliedChanges = true;
    });
    await _persistWorkers(project.id);
  }

  Future<void> _editWorker(Project project, WorkerDraft worker) async {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != null) {
      await _refreshDatabaseUsers(project: project, server: selectedServer);
    }
    final updated = await _showWorkerEditorDialog(initial: worker);
    if (updated == null) {
      return;
    }
    setState(() {
      _workers = [
        for (final entry in _workers)
          if (entry.id == worker.id) updated else entry,
      ];
      _hasUnappliedChanges = true;
    });
    await _persistWorkers(project.id);
  }

  Future<void> _deleteWorker(Project project, WorkerDraft worker) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppDestructiveConfirmDialog(
        title: 'Delete worker',
        description: workersDeleteDescription(worker.name),
      ),
    );
    if (confirmed != true) {
      return;
    }

    setState(() {
      _workers = _workers
          .where((candidate) => candidate.id != worker.id)
          .toList(growable: false);
      _hasUnappliedChanges = true;
    });
    await _persistWorkers(project.id);
  }

  @override
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final selectedServer = ref.watch(selectedServerProvider);

    if (selectedProject == null || selectedServer == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            workersMissingSelectionMessage(),
            key: const Key('workers-missing-selection-message'),
          ),
        ),
      );
    }

    _scheduleSelectionBind(selectedProject, selectedServer);
    final releaseScope = ref
        .watch(appReleaseProvider)
        .scopeFor(projectId: selectedProject.id, serverId: selectedServer.id);
    final hasAppRuntime = _projectHasAppRuntime(
      project: selectedProject,
      releaseScope: releaseScope,
    );

    if (_isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(),
        ),
      );
    }

    final runtimeById = <String, Map<String, dynamic>>{};
    for (final item in _runtimeSnapshot.configured) {
      final id = item['id']?.toString();
      final runtime = item['runtime'];
      if (id == null || runtime is! Map) {
        continue;
      }
      runtimeById[id] = mapFrom(runtime);
    }

    int runningWorkers = 0;
    for (final runtime in runtimeById.values) {
      final containerStatus = runtime['container_status'];
      final status = containerStatus is Map
          ? ContainerRuntimeStatus.fromMap(containerStatus)
          : ContainerRuntimeStatus.fromLegacy(
              running: runtime['state']?.toString() == 'running',
            );
      if (status.isReady) {
        runningWorkers += 1;
      }
    }

    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted, which is what would otherwise force a `!` on the read.
    final error = _error;
    return ListView(
      key: const Key('workers-tab-scroll'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        AppWorkspaceSection(
          key: const Key('workers-overview-card'),
          icon: Icons.work_outline,
          title: workersWorkspaceTitle(),
          subtitle: workersWorkspaceSubtitle(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  _LabeledValueRow(
                    label: 'Configured',
                    value: _workers.length.toString(),
                    width: 110,
                    labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    valueStyle: Theme.of(context).textTheme.bodySmall,
                    crossAxisAlignment: CrossAxisAlignment.center,
                  ),
                  _LabeledValueRow(
                    label: 'Running',
                    value: runningWorkers.toString(),
                    width: 110,
                    labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    valueStyle: Theme.of(context).textTheme.bodySmall,
                    crossAxisAlignment: CrossAxisAlignment.center,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (!hasAppRuntime) ...[
                _ProjectAppRuntimeRequiredCallout(
                  key: const Key('workers-app-runtime-required-callout'),
                  onOpenWebAppTab: widget.onOpenWebAppTab,
                ),
                const SizedBox(height: 12),
              ],
              if (_workers.isNotEmpty)
                AppWorkspaceToolbar(
                  children: [
                    FilledButton.icon(
                      key: const Key('workers-add-button'),
                      onPressed: _isSaving || _isApplying || !hasAppRuntime
                          ? null
                          : () => _addWorker(selectedProject),
                      icon: const Icon(Icons.add),
                      label: const Text('Add worker'),
                    ),
                    if (_hasUnappliedChanges || _isApplying)
                      OutlinedButton.icon(
                        key: const Key('workers-apply-runtime-button'),
                        onPressed: _isApplying || _isSaving || !hasAppRuntime
                            ? null
                            : () => _applyWorkersRuntime(
                                project: selectedProject,
                                server: selectedServer,
                              ),
                        icon: const Icon(Icons.rocket_launch_outlined),
                        label: Text(workersRuntimeApplyLabel(_isApplying)),
                      ),
                    IconButton(
                      key: const Key('workers-refresh-status-button'),
                      tooltip: 'Refresh worker status',
                      onPressed: _isApplying || _isSaving
                          ? null
                          : () => _refreshWorkerStatus(
                              project: selectedProject,
                              server: selectedServer,
                            ),
                      icon: const Icon(
                        Icons.refresh,
                        semanticLabel: 'Refresh worker status',
                      ),
                    ),
                  ],
                ),
              if (_workers.isEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    key: const Key('workers-refresh-status-button'),
                    tooltip: 'Refresh worker status',
                    onPressed: _isApplying || _isSaving
                        ? null
                        : () => _refreshWorkerStatus(
                            project: selectedProject,
                            server: selectedServer,
                          ),
                    icon: const Icon(
                      Icons.refresh,
                      semanticLabel: 'Refresh worker status',
                    ),
                  ),
                ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error,
                  key: const Key('workers-error-text'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: YaruColors.red),
                ),
              ],
            ],
          ),
        ),
        AppWorkspaceSection(
          key: const Key('workers-list-card'),
          icon: Icons.list_alt,
          title: workersConfiguredTitle(),
          subtitle: workersConfiguredSubtitle(),
          child: _workers.isEmpty
              ? AppEmptyStateView(
                  key: const Key('workers-empty-state-text'),
                  icon: Icons.work_outline,
                  title: 'No workers yet',
                  message: workersEmptyMessage(),
                  action: FilledButton.icon(
                    key: const Key('workers-add-button'),
                    onPressed: _isSaving || _isApplying || !hasAppRuntime
                        ? null
                        : () {
                            // Empty-state taps report here, not in a
                            // provider: the editor dialog and `_persistWorkers`
                            // serve edits and the toolbar add too, so
                            // provider-hooking would mislabel those as
                            // empty-state acts.
                            ref
                                .read(appAnalyticsServiceProvider)
                                .trackControlUsed(
                                  control: AppControl.emptyStateAction,
                                );
                            _addWorker(selectedProject);
                          },
                    icon: const Icon(Icons.add),
                    label: const Text('Add worker'),
                  ),
                )
              : Column(
                  children: [
                    for (final worker in _workers)
                      _WorkerRow(
                        key: Key('worker-row-${worker.id}'),
                        worker: worker,
                        runtime: runtimeById[worker.id],
                        isBusy: _isWorkerBusy(worker),
                        onToggleEnabled:
                            _isSaving || _isApplying || _isWorkerBusy(worker)
                            ? null
                            : (value) async {
                                setState(() {
                                  _workers = [
                                    for (final entry in _workers)
                                      if (entry.id == worker.id)
                                        entry.copyWith(enabled: value)
                                      else
                                        entry,
                                  ];
                                  _hasUnappliedChanges = true;
                                });
                                await _persistWorkers(selectedProject.id);
                              },
                        onEdit:
                            _isSaving || _isApplying || _isWorkerBusy(worker)
                            ? null
                            : () => _editWorker(selectedProject, worker),
                        onDelete:
                            _isSaving || _isApplying || _isWorkerBusy(worker)
                            ? null
                            : () => _deleteWorker(selectedProject, worker),
                        onStart:
                            _isSaving ||
                                _isApplying ||
                                _isWorkerBusy(worker) ||
                                !worker.enabled
                            ? null
                            : () => _runWorkerOperation(
                                project: selectedProject,
                                server: selectedServer,
                                worker: worker,
                                operationId: 'worker_start',
                                successMessage: 'Worker started.',
                              ),
                        onStop:
                            _isSaving || _isApplying || _isWorkerBusy(worker)
                            ? null
                            : () => _runWorkerOperation(
                                project: selectedProject,
                                server: selectedServer,
                                worker: worker,
                                operationId: 'worker_stop',
                                successMessage: 'Worker stopped.',
                              ),
                        onRestart:
                            _isSaving ||
                                _isApplying ||
                                _isWorkerBusy(worker) ||
                                !worker.enabled
                            ? null
                            : () => _runWorkerOperation(
                                project: selectedProject,
                                server: selectedServer,
                                worker: worker,
                                operationId: 'worker_restart',
                                successMessage: 'Worker restarted.',
                              ),
                        onLogs:
                            _isSaving || _isApplying || _isWorkerBusy(worker)
                            ? null
                            : () => _showWorkerLogs(
                                project: selectedProject,
                                server: selectedServer,
                                worker: worker,
                              ),
                      ),
                    if (_runtimeSnapshot.orphans.isNotEmpty) ...[
                      const Divider(height: 20),
                      Text(
                        'Orphan worker containers',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      for (final orphan in _runtimeSnapshot.orphans)
                        Text(
                          orphan['container_name']?.toString() ?? 'Unknown',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _WorkerRow extends StatelessWidget {
  const _WorkerRow({
    super.key,
    required this.worker,
    required this.runtime,
    this.isBusy = false,
    this.onToggleEnabled,
    this.onEdit,
    this.onDelete,
    this.onStart,
    this.onStop,
    this.onRestart,
    this.onLogs,
  });

  final WorkerDraft worker;
  final Map<String, dynamic>? runtime;
  final bool isBusy;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onStart;
  final VoidCallback? onStop;
  final VoidCallback? onRestart;
  final VoidCallback? onLogs;

  @override
  Widget build(BuildContext context) {
    final state = runtime?['state']?.toString() ?? 'not_created';
    final status = runtime?['status']?.toString() ?? 'Not created';
    final stats = runtime?['stats'];
    final cpu = stats is Map ? stats['cpu_perc']?.toString() : null;
    final memory = stats is Map ? stats['mem_usage']?.toString() : null;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    worker.name,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Switch(value: worker.enabled, onChanged: onToggleEnabled),
                IconButton(
                  key: Key('worker-edit-${worker.id}'),
                  tooltip: 'Edit worker',
                  onPressed: onEdit,
                  icon: const Icon(
                    Icons.edit_outlined,
                    semanticLabel: 'Edit worker',
                  ),
                ),
                IconButton(
                  key: Key('worker-delete-${worker.id}'),
                  tooltip: 'Delete worker',
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline,
                    semanticLabel: 'Delete worker',
                  ),
                ),
              ],
            ),
            Text(
              worker.startCommand,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _LabeledValueRow(
                  label: 'CPU',
                  value: worker.cpuLimit.toString(),
                  width: 110,
                  labelStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  valueStyle: Theme.of(context).textTheme.bodySmall,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
                _LabeledValueRow(
                  label: 'Memory',
                  value: '${worker.memoryMb} MB',
                  width: 110,
                  labelStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  valueStyle: Theme.of(context).textTheme.bodySmall,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
                _LabeledValueRow(
                  label: 'Disk',
                  value: '${worker.diskMb} MB',
                  width: 110,
                  labelStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  valueStyle: Theme.of(context).textTheme.bodySmall,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
                _LabeledValueRow(
                  label: 'State',
                  value: state,
                  width: 110,
                  labelStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  valueStyle: Theme.of(context).textTheme.bodySmall,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
                _LabeledValueRow(
                  label: 'Status',
                  value: status,
                  width: 110,
                  labelStyle: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  valueStyle: Theme.of(context).textTheme.bodySmall,
                  crossAxisAlignment: CrossAxisAlignment.center,
                ),
                if (cpu != null)
                  _LabeledValueRow(
                    label: 'CPU now',
                    value: cpu,
                    width: 110,
                    labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    valueStyle: Theme.of(context).textTheme.bodySmall,
                    crossAxisAlignment: CrossAxisAlignment.center,
                  ),
                if (memory != null)
                  _LabeledValueRow(
                    label: 'Memory now',
                    value: memory,
                    width: 110,
                    labelStyle: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    valueStyle: Theme.of(context).textTheme.bodySmall,
                    crossAxisAlignment: CrossAxisAlignment.center,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                IconButton(
                  onPressed: onStart,
                  tooltip: 'Start worker',
                  icon: const Icon(
                    Icons.play_arrow_outlined,
                    semanticLabel: 'Start worker',
                  ),
                ),
                IconButton(
                  onPressed: onStop,
                  tooltip: 'Stop worker',
                  icon: const Icon(
                    Icons.stop_outlined,
                    semanticLabel: 'Stop worker',
                  ),
                ),
                IconButton(
                  onPressed: onRestart,
                  tooltip: 'Restart worker',
                  icon: const Icon(
                    Icons.restart_alt,
                    semanticLabel: 'Restart worker',
                  ),
                ),
                IconButton(
                  onPressed: onLogs,
                  tooltip: 'View worker activity',
                  icon: const Icon(
                    Icons.receipt_long_outlined,
                    semanticLabel: 'View worker activity',
                  ),
                ),
              ],
            ),
            if (isBusy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
          ],
        ),
      ),
    );
  }
}
