part of '../../project_workspace.dart';

typedef ProjectTerminalLineWriter =
    void Function(String line, {String source, String? taskType, bool detail});

class ProjectWorkspace extends StatelessWidget {
  const ProjectWorkspace({
    super.key,
    this.onOpenServerServices,
    this.onProjectDeleted,
    this.initialTabIndex = 0,
    this.onDestinationSelected,
    this.pickPostgresRestoreSqlFile,
    this.onTerminalLine,
  });

  final VoidCallback? onOpenServerServices;
  final ValueChanged<ProjectDeletionOutcome>? onProjectDeleted;
  final int initialTabIndex;
  final ValueChanged<String>? onDestinationSelected;
  final Future<String?> Function()? pickPostgresRestoreSqlFile;
  final ProjectTerminalLineWriter? onTerminalLine;

  static const List<ProjectDestination> _tabs = projectWorkspaceDestinations;

  @override
  // coverage-gate: workspace_shell_entry
  Widget build(BuildContext context) {
    return DefaultTabController(
      key: ValueKey(initialTabIndex),
      length: _tabs.length,
      initialIndex: initialTabIndex.clamp(0, _tabs.length - 1),
      child: Builder(
        builder: (tabContext) {
          final controller = DefaultTabController.of(tabContext);
          return AnimatedBuilder(
            animation: controller,
            builder: (context, child) => Consumer(
              builder: (consumerContext, ref, _) {
                void selectDestination(int index) {
                  controller.animateTo(index);
                  final destinationId = _tabs[index].id;
                  final onDestinationSelected = this.onDestinationSelected;
                  if (onDestinationSelected != null) {
                    onDestinationSelected(destinationId);
                  } else {
                    _recordDestinationVisit(ref, index);
                  }
                }

                return AppWorkspaceScaffold(
                  destinations: _tabs
                      .map(
                        (tab) => AppContextNavigationItem(
                          id: tab.id,
                          label: tab.label,
                          icon: tab.icon,
                        ),
                      )
                      .toList(growable: false),
                  selectedIndex: controller.index,
                  onSelected: selectDestination,
                  navigationKeyNamespace: 'project-workspace',
                  banner: const _ProjectWorkspaceImportCoordinator(),
                  child: TabBarView(
                    children: [
                      _AppTabView(
                        onOpenRuntimeLogs: () => selectDestination(7),
                      ),
                      _WorkersTabView(
                        onOpenWebAppTab: () => selectDestination(0),
                      ),
                      _DatabaseTabView(
                        onOpenServerServices: onOpenServerServices,
                        onOpenBackupTab: () => selectDestination(5),
                        pickPostgresRestoreSqlFile: pickPostgresRestoreSqlFile,
                      ),
                      const _EmailTabView(),
                      const _DomainTabView(),
                      _BackupTabView(
                        onTerminalLine: onTerminalLine,
                        onOpenServerServices: onOpenServerServices,
                      ),
                      _SchedulerTabView(
                        onTerminalLine: onTerminalLine,
                        onOpenWebAppTab: () => selectDestination(0),
                      ),
                      const _LogTabView(),
                      _SettingsTabView(onProjectDeleted: onProjectDeleted),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  // end coverage-gate
  void _recordDestinationVisit(WidgetRef ref, int index) {
    final projectId = ref.read(selectedProjectIdProvider).trim();
    if (projectId.isEmpty) {
      return;
    }
    unawaited(
      ref
          .read(recentProjectVisitsProvider.notifier)
          .recordVisit(projectId: projectId, destinationId: _tabs[index].id),
    );
  }
}

class _ProjectWorkspaceImportCoordinator extends ConsumerStatefulWidget {
  const _ProjectWorkspaceImportCoordinator();

  @override
  ConsumerState<_ProjectWorkspaceImportCoordinator> createState() =>
      _ProjectWorkspaceImportCoordinatorState();
}

class _ProjectWorkspaceImportCoordinatorState
    extends ConsumerState<_ProjectWorkspaceImportCoordinator> {
  String? _activeScopeKey;
  bool _importRunning = false;
  String? _localStatus;
  String? _localError;
  String? _repairError;

  @override
  // coverage-gate: workspace_shell_status_views
  Widget build(BuildContext context) {
    final project = ref.watch(selectedProjectProvider);
    final server = ref.watch(selectedServerProvider);
    final scope = WorkspaceScope.fromSelection(project, server);
    final scopeKey = scope?.cacheKey;
    if (!_importRunning &&
        scopeKey != null &&
        _activeScopeKey != null &&
        scopeKey != _activeScopeKey) {
      _localStatus = null;
      _localError = null;
    }
    if (project != null &&
        server != null &&
        scopeKey != null &&
        _repairError == null &&
        _localStatus != 'imported' &&
        _localStatus != 'failed') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_maybeRunImport(project: project, server: server));
      });
    }

    final importState = project == null || server == null
        ? null
        : ref
              .watch(appReleaseProvider)
              .scopeFor(projectId: project.id, serverId: server.id)
              .importState;
    final status = _localStatus ?? importState?.status;
    final error = _localError ?? importState?.errorMessage;
    if (_repairError != null) {
      return _WorkspaceImportBanner(
        isFailed: true,
        message:
            'Could not finish repairing saved project state. Saved local state is still available.',
        error: _repairError,
        retryLabel: 'Retry repair',
        onRetry: project == null || server == null || _importRunning
            ? null
            : () => _retryRepair(project: project, server: server),
      );
    }

    if (status != 'importing' && status != 'failed') {
      return const SizedBox.shrink();
    }
    return _WorkspaceImportBanner(
      isFailed: status == 'failed',
      message: status == 'failed'
          ? 'Could not import the latest project state. Saved local state is still available.'
          : 'Importing this project’s current managed state once.',
      error: error,
      retryLabel: 'Retry import',
      onRetry: status == 'failed' && project != null && server != null
          ? (_importRunning
                ? null
                : () => _runImport(project: project, server: server))
          : null,
    );
  }

  // end coverage-gate
  Future<void> _maybeRunImport({
    required Project project,
    required Server server,
  }) async {
    final scope = WorkspaceScope.fromSelection(project, server);
    final scopeKey = scope?.cacheKey;
    if (scopeKey == null || _importRunning) {
      return;
    }
    if (_activeScopeKey != scopeKey) {
      _activeScopeKey = scopeKey;
      _repairError = null;
      await ref
          .read(appReleaseProvider.notifier)
          .loadScope(projectId: project.id, serverId: server.id);
    }
    await _replayRemoteSuccessJournal(project: project, server: server);
    if (!mounted || _repairError != null) {
      return;
    }
    if (!mounted) {
      return;
    }
    final state = ref
        .read(appReleaseProvider)
        .scopeFor(projectId: project.id, serverId: server.id)
        .importState;
    if (state == null) {
      _localStatus = 'skipped';
      return;
    }
    if (state.status != 'pending') {
      _localStatus = state.status;
      return;
    }
    await _runImport(project: project, server: server);
  }

  Future<void> _retryRepair({
    required Project project,
    required Server server,
  }) async {
    await _replayRemoteSuccessJournal(project: project, server: server);
    if (mounted && _repairError == null) {
      setState(() {});
    }
  }

  Future<void> _replayRemoteSuccessJournal({
    required Project project,
    required Server server,
  }) async {
    try {
      final entries = await ref
          .read(appReleaseRepositoryProvider)
          .listRemoteSuccessJournal();
      for (final entry in entries) {
        if (entry.projectId != project.id || entry.serverId != server.id) {
          continue;
        }
        final result = _decodeJsonMap(entry.resultJson) ?? <String, dynamic>{};
        final request =
            _decodeJsonMap(entry.requestJson) ?? <String, dynamic>{};
        switch (entry.surface) {
          case 'database':
            await ref
                .read(projectManagedDatabaseRepositoryProvider)
                .applyJournaledOperation(
                  projectId: entry.projectId,
                  serverId: entry.serverId,
                  operationType: entry.operationType,
                  requestJson: entry.requestJson,
                  resultJson: entry.resultJson,
                );
          case 'app':
            await _replayAppJournalEntry(
              project: project,
              server: server,
              result: result,
            );
          case 'workers':
            await _replayWorkerJournalEntry(
              project: project,
              server: server,
              result: result,
            );
          case 'scheduler':
            await _replaySchedulerJournalEntry(
              project: project,
              request: request,
              result: result,
              operationType: entry.operationType,
              journalStatus: entry.status,
              errorMessage: entry.errorMessage,
            );
          case 'backup':
            await _replayBackupJournalEntry(
              project: project,
              server: server,
              request: request,
              result: result,
              operationType: entry.operationType,
            );
          default:
            continue;
        }
        await ref
            .read(appReleaseRepositoryProvider)
            .updateJournalStatus(
              id: entry.id,
              status: 'committed_local',
              result: result,
            );
      }
      await _replayFailedSchedulerRunJournals(project: project, server: server);
      if (mounted && _repairError != null) {
        setState(() {
          _repairError = null;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _repairError = error.toString();
      });
    }
  }

  Future<void> _replayFailedSchedulerRunJournals({
    required Project project,
    required Server server,
  }) async {
    final entries = await ref
        .read(appReleaseRepositoryProvider)
        .listFailedJournal();
    for (final entry in entries) {
      if (entry.projectId != project.id ||
          entry.serverId != server.id ||
          entry.surface != 'scheduler' ||
          entry.operationType != 'task_run_now') {
        continue;
      }
      final result = _decodeJsonMap(entry.resultJson) ?? <String, dynamic>{};
      final request = _decodeJsonMap(entry.requestJson) ?? <String, dynamic>{};
      await _replaySchedulerJournalEntry(
        project: project,
        request: request,
        result: result,
        operationType: entry.operationType,
        journalStatus: entry.status,
        errorMessage: entry.errorMessage,
      );
      await ref
          .read(appReleaseRepositoryProvider)
          .updateJournalStatus(
            id: entry.id,
            status: 'committed_local',
            result: result,
            errorMessage: entry.errorMessage,
          );
    }
  }

  // D-58 (T-014): left — lets FormatException propagate (no try) like the
  // managed-db twin; backup/prefs catch it instead.
  Map<String, dynamic>? _decodeJsonMap(String? value) {
    final raw = value?.trim();
    if (raw == null || raw.isEmpty) {
      return null;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return null;
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _replayAppJournalEntry({
    required Project project,
    required Server server,
    required Map<String, dynamic> result,
  }) async {
    final releases = AppReleaseRepository.recordsFromBackendResponse(
      projectId: project.id,
      serverId: server.id,
      payload: result,
      observedAt: DateTime.now().toUtc(),
    );
    if (releases.isEmpty) {
      return;
    }
    final notifier = ref.read(appReleaseProvider.notifier);
    if (result['release_inventory'] is Map || result['releases'] is List) {
      await notifier.replaceReleases(
        projectId: project.id,
        serverId: server.id,
        releases: releases,
      );
      return;
    }
    for (final release in releases) {
      await notifier.upsertRelease(release);
    }
  }

  Future<void> _replayWorkerJournalEntry({
    required Project project,
    required Server server,
    required Map<String, dynamic> result,
  }) async {
    if (result.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc();
    await ref
        .read(appReleaseProvider.notifier)
        .upsertWorkerRuntimeSnapshot(
          WorkerRuntimeSnapshotRecord(
            projectId: project.id,
            serverId: server.id,
            snapshotJson: jsonEncode(result),
            lastCheckedAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> _replaySchedulerJournalEntry({
    required Project project,
    required Map<String, dynamic> request,
    required Map<String, dynamic> result,
    required String operationType,
    required String journalStatus,
    String? errorMessage,
  }) async {
    final scheduler = ref.read(projectSchedulerProvider.notifier);
    // toString-first: trimOrNull takes String? (D-87).
    final taskId = trimOrNull(request['task_id']?.toString());
    if (taskId == null) {
      return;
    }
    switch (operationType) {
      case 'task_upsert':
        await scheduler.upsertTask(
          ProjectScheduledTask(
            id: taskId,
            projectId: project.id,
            name: trimOrNull(request['name']?.toString()) ?? taskId,
            targetType:
                trimOrNull(request['target_type']?.toString()) ?? 'web_app',
            targetRef: trimOrNull(request['target_ref']?.toString()),
            command: trimOrNull(request['command']?.toString()) ?? '',
            scheduleType:
                trimOrNull(request['schedule_type']?.toString()) ??
                'every_minutes',
            intervalValue: _journalInt(request['interval_value']),
            dailyTime: trimOrNull(request['daily_time']?.toString()),
            enabled: _journalBool(request['enabled']) ?? true,
            lastKnownState: trimOrNull(
              result['timer_active_state']?.toString(),
            ),
            lastKnownMessage: trimOrNull(result['service_result']?.toString()),
            lastRunAt: schedulerParseIsoDate(result['last_run_at']),
            nextRunAt: schedulerParseIsoDate(result['next_run_at']),
            sortOrder: _journalInt(request['sort_order']) ?? 0,
          ),
        );
      case 'task_delete':
        await scheduler.deleteTask(projectId: project.id, taskId: taskId);
      case 'task_set_enabled':
        await scheduler.updateTaskRuntimeStatus(
          projectId: project.id,
          taskId: taskId,
          enabled: _journalBool(request['enabled']),
          lastKnownState: trimOrNull(result['timer_active_state']?.toString()),
          lastKnownMessage: trimOrNull(result['service_result']?.toString()),
          lastRunAt: schedulerParseIsoDate(result['last_run_at']),
          nextRunAt: schedulerParseIsoDate(result['next_run_at']),
        );
      case 'task_run_now':
        final runFailed =
            journalStatus == 'failed' ||
            (trimOrNull(result['status']?.toString()) ?? '').toLowerCase() ==
                'error';
        await scheduler.appendRun(
          ProjectScheduledTaskRun(
            taskId: taskId,
            projectId: project.id,
            status: runFailed ? 'failed' : 'triggered',
            message:
                trimOrNull(result['msg']?.toString()) ??
                trimOrNull(errorMessage?.toString()),
            triggeredManually: true,
            triggeredAt: DateTime.now(),
          ),
        );
    }
  }

  Future<void> _replayBackupJournalEntry({
    required Project project,
    required Server server,
    required Map<String, dynamic> request,
    required Map<String, dynamic> result,
    required String operationType,
  }) async {
    final policyId = trimOrNull(request['policy_id']?.toString());
    final engine = _journalBackupEngine(request['engine']);
    final backupNotifier = ref.read(projectBackupProvider.notifier);
    final schedulerNotifier = ref.read(projectSchedulerProvider.notifier);
    switch (operationType) {
      case 'backup_policy_apply':
        final managedTaskId = trimOrNull(
          request['managed_task_id']?.toString(),
        );
        if (policyId == null || managedTaskId == null) {
          return;
        }
        final policy = BackupPolicyRecord(
          engine: engine,
          id: policyId,
          projectId: project.id,
          serverId: server.id,
          name: trimOrNull(request['policy_name']?.toString()) ?? policyId,
          destinationId:
              trimOrNull(request['destination_id']?.toString()) ?? '',
          databaseName: trimOrNull(request['database_name']?.toString()) ?? '',
          scheduleMode:
              trimOrNull(request['schedule_mode']?.toString()) ?? 'daily_once',
          time1Hhmm: trimOrNull(request['time1']?.toString()) ?? '02:00',
          time2Hhmm: trimOrNull(request['time2']?.toString()),
          retentionKeepLast: _journalInt(request['retention_keep_last']) ?? 7,
          enabled: _journalBool(request['enabled']) ?? true,
          managedTaskId: managedTaskId,
        );
        await backupNotifier.upsertPolicy(policy);
        await schedulerNotifier.upsertTask(
          ProjectScheduledTask(
            id: managedTaskId,
            projectId: project.id,
            sourceType: 'service',
            managedByService: true,
            name: 'Backup: ${policy.name}',
            targetType: 'host',
            command: 'Managed PostgreSQL backup policy',
            scheduleType: 'daily_at',
            dailyTime: policy.scheduleMode == 'daily_twice'
                ? '${policy.time1Hhmm},${policy.time2Hhmm ?? ''}'
                : policy.time1Hhmm,
            enabled: policy.enabled,
          ),
        );
      case 'backup_policy_delete':
        final managedTaskId = trimOrNull(
          request['managed_task_id']?.toString(),
        );
        if (policyId == null || managedTaskId == null) {
          return;
        }
        await backupNotifier.deletePolicy(
          engine: engine,
          id: policyId,
          projectId: project.id,
          serverId: server.id,
        );
        await schedulerNotifier.deleteTask(
          projectId: project.id,
          taskId: managedTaskId,
        );
      case 'backup_run_now':
        if (policyId == null) {
          return;
        }
        final now = DateTime.now().toUtc();
        final status = trimOrNull(result['status']?.toString()) ?? 'success';
        final message = trimOrNull(result['msg']?.toString());
        await backupNotifier.appendRun(
          BackupRunRecord(
            engine: engine,
            projectId: project.id,
            serverId: server.id,
            policyId: policyId,
            operationType: BackupOperationType.backup,
            status: status,
            message: message,
            triggeredManually: true,
            taskId: trimOrNull(request['managed_task_id']?.toString()),
            startedAt: now,
            finishedAt: now,
          ),
        );
        await ref
            .read(backupRepositoryProvider)
            .updatePolicyRuntime(
              engine: engine,
              policyId: policyId,
              projectId: project.id,
              serverId: server.id,
              lastRunAt: now,
              lastStatus: status,
              lastMessage: message,
            );
      case 'restore_run_now':
        if (policyId == null) {
          return;
        }
        final now = DateTime.now().toUtc();
        await backupNotifier.appendRun(
          BackupRunRecord(
            engine: engine,
            projectId: project.id,
            serverId: server.id,
            policyId: policyId,
            operationType: BackupOperationType.restore,
            status: trimOrNull(result['status']?.toString()) ?? 'success',
            message: trimOrNull(result['msg']?.toString()),
            triggeredManually: true,
            artifactId: trimOrNull(request['artifact_id']?.toString()),
            startedAt: now,
            finishedAt: now,
          ),
        );
        if (trimOrNull(result['status']?.toString()) == 'success') {
          await ref
              .read(projectManagedDatabaseRepositoryProvider)
              .applyOperationResult(
                projectId: project.id,
                serverId: server.id,
                engine: engine.name,
                operationType: operationType,
                request: request,
                result: result,
              );
        }
      case 'backup_backlog_cleanup':
        if (policyId == null) {
          return;
        }
        final cleanupNow = DateTime.now().toUtc();
        await backupNotifier.appendRun(
          BackupRunRecord(
            engine: engine,
            projectId: project.id,
            serverId: server.id,
            policyId: policyId,
            operationType: BackupOperationType.cleanup,
            status: trimOrNull(result['status']?.toString()) ?? 'success',
            message: trimOrNull(result['msg']?.toString()),
            triggeredManually: true,
            startedAt: cleanupNow,
            finishedAt: cleanupNow,
          ),
        );
    }
  }

  int? _journalInt(dynamic value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString() ?? '');
  }

  bool? _journalBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    final normalized = value?.toString().trim().toLowerCase();
    return switch (normalized) {
      'true' || '1' || 'yes' => true,
      'false' || '0' || 'no' => false,
      _ => null,
    };
  }

  BackupEngine _journalBackupEngine(dynamic value) {
    return switch (trimOrNull(value?.toString())) {
      'postgres' => BackupEngine.postgres,
      _ => BackupEngine.postgres,
    };
  }

  Future<void> _runImport({
    required Project project,
    required Server server,
  }) async {
    if (_importRunning) {
      return;
    }
    setState(() {
      _importRunning = true;
      _localStatus = 'importing';
      _localError = null;
    });
    final startedAt = DateTime.now().toUtc();
    await ref
        .read(appReleaseProvider.notifier)
        .updateImportState(
          projectId: project.id,
          serverId: server.id,
          status: 'importing',
          startedAt: startedAt,
        );
    try {
      await _importManagedDatabases(project: project, server: server);
      await _importReleaseInventory(project: project, server: server);
      await _importBackupArtifacts(project: project, server: server);
      await _importWorkerRuntime(project: project, server: server);
      await _importSchedulerStatus(project: project, server: server);
      await ref
          .read(appReleaseProvider.notifier)
          .updateImportState(
            projectId: project.id,
            serverId: server.id,
            status: 'imported',
            startedAt: startedAt,
            finishedAt: DateTime.now().toUtc(),
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _importRunning = false;
        _localStatus = 'imported';
        _localError = null;
      });
    } catch (error) {
      final message = error.toString();
      await ref
          .read(appReleaseProvider.notifier)
          .updateImportState(
            projectId: project.id,
            serverId: server.id,
            status: 'failed',
            startedAt: startedAt,
            finishedAt: DateTime.now().toUtc(),
            errorMessage: message,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _importRunning = false;
        _localStatus = 'failed';
        _localError = message;
      });
    }
  }

  Future<void> _importManagedDatabases({
    required Project project,
    required Server server,
  }) async {
    if (!server.serviceDatabaseEnabled) {
      return;
    }
    final connection = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null) {
      return;
    }
    final response =
        (await ref
                .read(sshServiceProvider)
                .runWorkflow(
                  workflowId: 'postgres',
                  operationId: 'project_list',
                  connection: connection,
                  params: <String, dynamic>{
                    'dry_run': false,
                    'settings': buildManagedPostgresProjectSettings(
                      projectName: project.name,
                      config: server.postgresConfig,
                    ),
                  },
                ))
            .diagnosticPayload;
    if (response['status'] != 'success') {
      throw StateError(
        response['msg']?.toString() ?? 'Could not import project databases.',
      );
    }
    final now = DateTime.now().toUtc();
    final databases = <ProjectManagedDatabaseRecord>[];
    final users = <ProjectManagedDatabaseUserRecord>[];
    final responseHost =
        response['host']?.toString() ?? response['database_host']?.toString();
    final responsePort = _nullableInt(
      response['port'] ?? response['database_port'],
    );
    final databasesPayload = response['databases'];
    if (databasesPayload is List) {
      for (final item in databasesPayload) {
        final databaseName = item is Map
            ? item['name']?.toString().trim()
            : item.toString().trim();
        if (databaseName == null || databaseName.isEmpty) {
          continue;
        }
        final record = ProjectManagedDatabaseRepository.fromBackendDatabase(
          projectId: project.id,
          serverId: server.id,
          databaseName: databaseName,
          observedAt: now,
        );
        if (record != null) {
          databases.add(record);
        }
      }
    }
    final usersPayload = response['users'];
    if (usersPayload is List) {
      for (final item in usersPayload.whereType<Map<dynamic, dynamic>>()) {
        final username = item['username']?.toString().trim();
        final databaseName = item['database']?.toString().trim();
        if (username == null ||
            username.isEmpty ||
            databaseName == null ||
            databaseName.isEmpty) {
          continue;
        }
        final record = ProjectManagedDatabaseRepository.fromBackendUser(
          projectId: project.id,
          serverId: server.id,
          databaseName: databaseName,
          username: username,
          accessMode: item['access_mode']?.toString().trim() ?? 'read_write',
          password:
              item['password']?.toString() ??
              item['database_password']?.toString(),
          host:
              item['host']?.toString() ??
              item['database_host']?.toString() ??
              responseHost,
          port:
              _nullableInt(item['port'] ?? item['database_port']) ??
              responsePort,
          connectionUri:
              item['connection_uri']?.toString() ??
              item['connectionUri']?.toString() ??
              item['database_url']?.toString(),
          observedAt: now,
        );
        if (record != null) {
          users.add(record);
        }
      }
    }
    await ref
        .read(projectManagedDatabaseProvider.notifier)
        .replaceScope(
          projectId: project.id,
          serverId: server.id,
          databases: databases,
          users: users,
        );
  }

  int? _nullableInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString().trim() ?? '');
  }

  Future<void> _importReleaseInventory({
    required Project project,
    required Server server,
  }) async {
    final connection = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null) {
      return;
    }
    final response =
        (await ref
                .read(sshServiceProvider)
                .runWorkflow(
                  workflowId: 'app',
                  operationId: 'list_releases',
                  connection: connection,
                  params: <String, dynamic>{
                    'dry_run': false,
                    'settings': _importAppSettings(project),
                  },
                ))
            .diagnosticPayload;
    if (response['status'] != 'success') {
      throw StateError(
        response['msg']?.toString() ?? 'Could not import web app releases.',
      );
    }
    final observedAt = DateTime.now().toUtc();
    final releasesPayload = response['releases'];
    final releases = <AppReleaseRecord>[];
    if (releasesPayload is List) {
      for (final item in releasesPayload.whereType<Map<dynamic, dynamic>>()) {
        final release = AppReleaseRepository.fromBackendRelease(
          projectId: project.id,
          serverId: server.id,
          payload: item,
          observedAt: observedAt,
        );
        if (release != null) {
          releases.add(release);
        }
      }
    }
    await ref
        .read(appReleaseProvider.notifier)
        .replaceReleases(
          projectId: project.id,
          serverId: server.id,
          releases: releases,
        );
  }

  Future<void> _importBackupArtifacts({
    required Project project,
    required Server server,
  }) async {
    // The loop this used to inline now lives on the notifier, so the backup
    // screen can refresh on open without a third copy of it. It returns a
    // message rather than throwing, because that screen must stay usable on
    // failure; this flow is a transaction, so it throws. G-42.
    final error = await ref
        .read(projectBackupProvider.notifier)
        .refreshArtifactsForScope(project: project, server: server);
    if (error != null) {
      throw StateError(error);
    }
  }

  Future<void> _importWorkerRuntime({
    required Project project,
    required Server server,
  }) async {
    await ref
        .read(projectWorkerInstancesProvider.notifier)
        .loadProject(project.id);
    final workers =
        ref.read(projectWorkerInstancesProvider)[project.id] ?? const [];
    if (workers.isEmpty) {
      return;
    }
    final connection = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null) {
      return;
    }
    final response =
        (await ref
                .read(sshServiceProvider)
                .runWorkflow(
                  workflowId: 'app',
                  operationId: 'workers_status',
                  connection: connection,
                  params: <String, dynamic>{
                    'dry_run': false,
                    'settings': {
                      ..._importAppSettings(project),
                      'workers': buildWorkersWorkflowPayload(workers: workers),
                    },
                  },
                ))
            .diagnosticPayload;
    if (response['status'] != 'success') {
      throw StateError(
        response['msg']?.toString() ?? 'Could not import worker status.',
      );
    }
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

  Future<void> _importSchedulerStatus({
    required Project project,
    required Server server,
  }) async {
    await ref.read(projectSchedulerProvider.notifier).loadProject(project.id);
    final tasks = ref
        .read(projectSchedulerProvider)
        .tasksForProject(project.id)
        .toList(growable: false);
    if (tasks.isEmpty) {
      return;
    }
    final connection = await ref.read(serverConnectionPayloadResolverProvider)(
      server,
    );
    if (connection == null) {
      return;
    }
    final tasksById = {for (final task in tasks) task.id: task};
    final response =
        (await ref
                .read(sshServiceProvider)
                .runWorkflow(
                  workflowId: 'scheduler',
                  operationId: 'task_status',
                  connection: connection,
                  params: <String, dynamic>{
                    'dry_run': false,
                    'settings': <String, dynamic>{
                      'project_slug': slugifyProjectName(
                        project.name,
                        fallback: 'project-scheduler',
                      ),
                      'task_ids': tasksById.keys.toList(growable: false),
                    },
                  },
                ))
            .diagnosticPayload;
    if (response['status'] != 'success') {
      throw StateError(
        response['msg']?.toString() ?? 'Could not import scheduled job status.',
      );
    }
    final statusesPayload = response['task_statuses'];
    if (statusesPayload is! List) {
      return;
    }
    for (final item in statusesPayload.whereType<Map<dynamic, dynamic>>()) {
      final statusMap = mapFrom(item);
      final taskId = statusMap['task_id']?.toString().trim();
      if (taskId == null || taskId.isEmpty) {
        continue;
      }
      final previousTask = tasksById[taskId];
      final lastRunAt = schedulerParseIsoDate(statusMap['last_run_at']);
      final nextRunAt = schedulerParseIsoDate(statusMap['next_run_at']);
      final enabledRaw = statusMap['enabled'];
      await ref
          .read(projectSchedulerProvider.notifier)
          .updateTaskRuntimeStatus(
            projectId: project.id,
            taskId: taskId,
            lastKnownState: statusMap['timer_active_state']?.toString(),
            lastKnownMessage: statusMap['service_result']?.toString(),
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            enabled: enabledRaw == true || enabledRaw == 'true',
          );
      if (lastRunAt != null &&
          previousTask != null &&
          previousTask.lastRunAt != lastRunAt) {
        await ref
            .read(projectSchedulerProvider.notifier)
            .appendRun(
              ProjectScheduledTaskRun(
                taskId: taskId,
                projectId: project.id,
                status: statusMap['service_result']?.toString() ?? 'completed',
                message: 'Observed scheduled execution from system timer.',
                triggeredManually: false,
                triggeredAt: lastRunAt,
              ),
            );
      }
    }
  }

  Map<String, dynamic> _importAppSettings(Project project) {
    final repository = project.repositoryFullName?.trim();
    final branch = project.deployBranch.trim();
    final primaryDomain = _validWorkspaceDomainOrNull(project.primaryDomain);
    return <String, dynamic>{
      'project_slug': slugifyProjectName(project.name, fallback: 'project-app'),
      'repository_full_name': repository == null || repository.isEmpty
          ? 'deploydash/local-app'
          : repository,
      'branch': branch.isEmpty ? 'main' : branch,
      'primary_domain': primaryDomain,
      'domain_routing_mode': _normalizedDomainRoutingModeForWorkspace(
        project.domainRoutingMode,
      ),
      'app_port': project.appPort,
      'railpack_provider': normalizeRailpackProvider(project.railpackProvider),
      'app_subdirectory': project.appSubdirectory ?? '',
    };
  }

  String? _validWorkspaceDomainOrNull(String value) {
    final candidate = value.trim().toLowerCase();
    if (candidate.isEmpty || candidate == 'not configured') {
      return null;
    }
    final fqdn = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
    );
    return fqdn.hasMatch(candidate) ? candidate : null;
  }
}

class _WorkspaceImportBanner extends StatelessWidget {
  const _WorkspaceImportBanner({
    required this.isFailed,
    required this.message,
    this.error,
    this.retryLabel,
    this.onRetry,
  });

  final bool isFailed;
  final String message;
  final String? error;
  final String? retryLabel;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` checks promote them; a widget field is never
    // promoted.
    final error = this.error;
    final retryLabel = this.retryLabel;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isFailed
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.42)
            : theme.colorScheme.primaryContainer.withValues(alpha: 0.42),
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          if (isFailed)
            Icon(Icons.info_outline, color: theme.colorScheme.error)
          else
            Icon(Icons.sync, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          if (isFailed && error != null && error.trim().isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                error,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
          if (retryLabel != null) ...[
            const SizedBox(width: 10),
            TextButton(onPressed: onRetry, child: Text(retryLabel)),
          ],
        ],
      ),
    );
  }
}

class _ProjectAppRuntimeRequiredCallout extends StatelessWidget {
  const _ProjectAppRuntimeRequiredCallout({super.key, this.onOpenWebAppTab});

  final VoidCallback? onOpenWebAppTab;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Deploy this web app first.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            OutlinedButton(
              key: const Key('project-open-web-app-tab-button'),
              onPressed: onOpenWebAppTab,
              child: const Text('Open Web app'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppTabView extends StatelessWidget {
  const _AppTabView({this.onOpenRuntimeLogs});

  final VoidCallback? onOpenRuntimeLogs;

  @override
  Widget build(BuildContext context) {
    return _AppDeploymentSummary(onOpenRuntimeLogs: onOpenRuntimeLogs);
  }
}

class _WorkersTabView extends StatelessWidget {
  const _WorkersTabView({this.onOpenWebAppTab});

  final VoidCallback? onOpenWebAppTab;

  @override
  Widget build(BuildContext context) {
    return _WorkersTabContent(onOpenWebAppTab: onOpenWebAppTab);
  }
}
