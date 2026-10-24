part of '../../project_workspace.dart';

class _SchedulerTaskDraft {
  const _SchedulerTaskDraft({
    required this.id,
    required this.name,
    required this.targetType,
    required this.command,
    required this.scheduleType,
    this.targetRef,
    this.intervalValue,
    this.dailyTime,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String targetType;
  final String? targetRef;
  final String command;
  final String scheduleType;
  final int? intervalValue;
  final String? dailyTime;
  final bool enabled;

  _SchedulerTaskDraft copyWith({
    String? id,
    String? name,
    String? targetType,
    Object? targetRef = ProjectScheduledTask.noChange,
    String? command,
    String? scheduleType,
    Object? intervalValue = ProjectScheduledTask.noChange,
    Object? dailyTime = ProjectScheduledTask.noChange,
    bool? enabled,
  }) {
    return _SchedulerTaskDraft(
      id: id ?? this.id,
      name: name ?? this.name,
      targetType: targetType ?? this.targetType,
      targetRef: identical(targetRef, ProjectScheduledTask.noChange)
          ? this.targetRef
          : targetRef as String?,
      command: command ?? this.command,
      scheduleType: scheduleType ?? this.scheduleType,
      intervalValue: identical(intervalValue, ProjectScheduledTask.noChange)
          ? this.intervalValue
          : intervalValue as int?,
      dailyTime: identical(dailyTime, ProjectScheduledTask.noChange)
          ? this.dailyTime
          : dailyTime as String?,
      enabled: enabled ?? this.enabled,
    );
  }

  static _SchedulerTaskDraft fromTask(ProjectScheduledTask task) {
    return _SchedulerTaskDraft(
      id: task.id,
      name: task.name,
      targetType: task.targetType,
      targetRef: task.targetRef,
      command: task.command,
      scheduleType: task.scheduleType,
      intervalValue: task.intervalValue,
      dailyTime: task.dailyTime,
      enabled: task.enabled,
    );
  }
}

class _SchedulerTabView extends StatelessWidget {
  const _SchedulerTabView({this.onTerminalLine, this.onOpenWebAppTab});

  final ProjectTerminalLineWriter? onTerminalLine;
  final VoidCallback? onOpenWebAppTab;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        AppWorkspaceSection(
          icon: Icons.schedule,
          title: 'Scheduler',
          subtitle:
              'Manage custom recurring commands for this project and inspect managed schedules.',
          child: _SchedulerSummary(
            onTerminalLine: onTerminalLine,
            onOpenWebAppTab: onOpenWebAppTab,
          ),
        ),
      ],
    );
  }
}

class _SchedulerSummary extends ConsumerStatefulWidget {
  const _SchedulerSummary({this.onTerminalLine, this.onOpenWebAppTab});

  final ProjectTerminalLineWriter? onTerminalLine;
  final VoidCallback? onOpenWebAppTab;

  @override
  ConsumerState<_SchedulerSummary> createState() => _SchedulerSummaryState();
}

class _SchedulerSummaryState extends ConsumerState<_SchedulerSummary>
    with WorkspaceScopedConsumerState<_SchedulerSummary> {
  bool _isLoading = true;
  bool _isRefreshingStatus = false;
  bool _isSaving = false;
  String? _error;
  final WorkspaceBusyRegistry _busyTasks = WorkspaceBusyRegistry();

  void _appendSchedulerTerminalLine(String line, {bool detail = false}) {
    widget.onTerminalLine?.call(
      line,
      source: 'scheduler',
      taskType: 'scheduler',
      detail: detail,
    );
  }

  void _scheduleSelectionBind(Project? project, Server? server) {
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
      _isRefreshingStatus = false;
      _isSaving = false;
      _busyTasks.clear();
      _error = null;
    });

    try {
      await ref
          .read(projectWorkerInstancesProvider.notifier)
          .loadProject(projectId);
      await ref.read(projectSchedulerProvider.notifier).loadProject(projectId);
      await ref
          .read(appReleaseProvider.notifier)
          .loadScope(projectId: projectId, serverId: server.id);
      if (!isCurrentWorkspaceSelection(project, server, bindEpoch)) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, bindEpoch)) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = couldntMessage('load scheduled jobs', error);
      });
    }
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  bool _isTaskBusy(ProjectScheduledTask task) {
    return _busyTasks.isBusy(
      scope: currentWorkspaceScope,
      kind: 'scheduler-task',
      id: task.id,
    );
  }

  String _targetSummary(ProjectScheduledTask task) {
    if (task.targetType == 'host') {
      return 'Host command';
    }
    if (task.targetType == 'worker') {
      final worker = task.targetRef?.trim();
      if (worker == null || worker.isEmpty) {
        return 'Worker (not selected)';
      }
      return 'Worker: $worker';
    }
    return 'Web app container';
  }

  String _schedulerActionFailureMessage(
    Map<String, dynamic> response, {
    required String fallback,
  }) {
    final rawMessage = response['msg']?.toString().trim();
    final rawDetails = response['details']?.toString().trim();
    final summary =
        rawMessage == null ||
            rawMessage.isEmpty ||
            rawMessage == 'Start scheduler task service failed.'
        ? fallback
        : rawMessage;
    if (rawDetails == null || rawDetails.isEmpty) {
      return summary;
    }
    if (summary.contains(rawDetails)) {
      return summary;
    }
    return '$summary\n\n$rawDetails';
  }

  List<String> _schedulerRunOutputLines(Map<String, dynamic> response) {
    final rawLines = response['run_output_lines'];
    if (rawLines is List) {
      return rawLines
          .map((line) => line?.toString() ?? '')
          .where((line) => line.trim().isNotEmpty)
          .toList(growable: false);
    }
    final rawOutput = response['run_output']?.toString().trim();
    if (rawOutput == null || rawOutput.isEmpty) {
      return const <String>[];
    }
    return rawOutput
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  String _schedulerRunSuccessMessage(Map<String, dynamic> response) {
    final output = _schedulerRunOutputLines(response).join('\n').trim();
    if (output.isNotEmpty) {
      return output;
    }
    final msg = response['msg']?.toString().trim();
    if (msg != null && msg.isNotEmpty) {
      return msg;
    }
    return schedulerTaskCompletedMessage();
  }

  Future<void> _showSchedulerActionErrorDialog({
    required String title,
    required String message,
  }) {
    return showAppNotice(
      context,
      title: title,
      message: message,
      okButtonKey: const Key('scheduler-action-error-ok-button'),
    );
  }

  Future<void> _refreshTaskStatus({
    required Project project,
    required Server server,
    bool quiet = false,
    int? expectedEpoch,
  }) async {
    final operationEpoch = expectedEpoch ?? workspaceBindEpoch;
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      if (!quiet &&
          isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _error = serverCredentialsReconnectMessage();
        });
      }
      return;
    }

    final tasks = ref
        .read(projectSchedulerProvider)
        .tasksForProject(project.id)
        .toList(growable: false);
    if (tasks.isEmpty) {
      if (!quiet &&
          isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _isRefreshingStatus = false;
        });
      }
      return;
    }

    if (!quiet &&
        isCurrentWorkspaceSelection(project, server, operationEpoch)) {
      setState(() {
        _isRefreshingStatus = true;
        _error = null;
      });
    }

    final tasksById = {for (final task in tasks) task.id: task};

    try {
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
                        'tasks': tasks
                            .where(
                              (task) =>
                                  (task.targetType == 'web_app' ||
                                      task.targetType == 'worker') &&
                                  task.command.trim().isNotEmpty,
                            )
                            .map(
                              (task) => <String, dynamic>{
                                'task_id': task.id,
                                'target_type': task.targetType,
                                'target_ref': task.targetRef,
                                'command': task.command,
                              },
                            )
                            .toList(growable: false),
                      },
                    },
                  ))
              .diagnosticPayload;

      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        if (!quiet &&
            isCurrentWorkspaceSelection(project, server, operationEpoch)) {
          setState(() {
            _error =
                response['msg']?.toString() ??
                'Couldn’t refresh scheduled job status.';
          });
        }
        return;
      }

      final statusesPayload = response['task_statuses'];
      if (statusesPayload is List) {
        for (final item in statusesPayload) {
          if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
            return;
          }
          if (item is! Map) {
            continue;
          }
          final statusMap = mapFrom(item);
          final taskId = statusMap['task_id']?.toString().trim();
          if (taskId == null || taskId.isEmpty) {
            continue;
          }

          final previousTask = tasksById[taskId];
          final lastRunAt = schedulerParseIsoDate(statusMap['last_run_at']);
          final nextRunAt = schedulerParseIsoDate(statusMap['next_run_at']);
          final knownState = statusMap['timer_active_state']?.toString();
          final lastMessage = statusMap['service_result']?.toString();
          final enabledRaw = statusMap['enabled'];
          final enabled = enabledRaw == true || enabledRaw == 'true';

          await ref
              .read(projectSchedulerProvider.notifier)
              .updateTaskRuntimeStatus(
                projectId: project.id,
                taskId: taskId,
                lastKnownState: knownState,
                lastKnownMessage: lastMessage,
                lastRunAt: lastRunAt,
                nextRunAt: nextRunAt,
                enabled: enabled,
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
                    status: lastMessage ?? 'completed',
                    message: 'Observed scheduled execution from system timer.',
                    triggeredManually: false,
                    triggeredAt: lastRunAt,
                  ),
                );
          }
        }
      }
    } catch (error) {
      if (!quiet &&
          isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _error = 'Couldn’t refresh scheduled job status.\n$error';
        });
      }
    } finally {
      if (!quiet &&
          isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _isRefreshingStatus = false;
        });
      }
    }
  }

  Future<void> _saveCustomTask({
    required Project project,
    required Server server,
    required _SchedulerTaskDraft draft,
    required bool isEdit,
    required int sortOrder,
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
      _isSaving = true;
      _error = null;
    });

    try {
      final settings = <String, dynamic>{
        'project_slug': slugifyProjectName(
          project.name,
          fallback: 'project-scheduler',
        ),
        'task_id': draft.id,
        'name': draft.name,
        'target_type': draft.targetType,
        'target_ref': draft.targetRef,
        'command': draft.command,
        'schedule_type': draft.scheduleType,
        'interval_value': draft.intervalValue,
        'daily_time': draft.dailyTime,
        'enabled': draft.enabled,
      };
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'scheduler',
        operationType: 'task_upsert',
        workflowId: 'scheduler',
        operationId: 'task_upsert',
        connection: connection,
        params: <String, dynamic>{'dry_run': false, 'settings': settings},
        journalRequest: <String, dynamic>{
          'workflow_id': 'scheduler',
          'operation_id': 'task_upsert',
          'task_id': draft.id,
          'name': draft.name,
          'target_type': draft.targetType,
          'target_ref': draft.targetRef,
          'command': draft.command,
          'schedule_type': draft.scheduleType,
          'interval_value': draft.intervalValue,
          'daily_time': draft.dailyTime,
          'enabled': draft.enabled,
          'is_edit': isEdit,
          'sort_order': sortOrder,
        },
      );
      final response = journaled.response;

      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        setState(() {
          _error =
              response['msg']?.toString() ??
              'Couldn’t save this scheduled job.';
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackSchedulerEvent(
              action: isEdit ? SchedulerAction.update : SchedulerAction.create,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      final now = DateTime.now();
      final createdTask = ProjectScheduledTask(
        id: draft.id,
        projectId: project.id,
        sourceType: 'custom',
        managedByService: false,
        name: draft.name,
        targetType: draft.targetType,
        targetRef: draft.targetRef,
        command: draft.command,
        scheduleType: draft.scheduleType,
        intervalValue: draft.scheduleType == 'daily_at'
            ? null
            : draft.intervalValue,
        dailyTime: draft.scheduleType == 'daily_at' ? draft.dailyTime : null,
        enabled: draft.enabled,
        lastKnownState: response['timer_active_state']?.toString(),
        lastKnownMessage: response['service_result']?.toString(),
        lastRunAt: schedulerParseIsoDate(response['last_run_at']),
        nextRunAt: schedulerParseIsoDate(response['next_run_at']),
        sortOrder: sortOrder,
      );

      await ref.read(projectSchedulerProvider.notifier).upsertTask(createdTask);
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            isEdit ? 'Scheduled job updated.' : 'Scheduled job created.',
          ),
        ),
      );

      await _refreshTaskStatus(
        project: project,
        server: server,
        quiet: false,
        expectedEpoch: operationEpoch,
      );
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      final statusText = response['msg']?.toString().trim();
      if (statusText != null && statusText.isNotEmpty) {
        await ref
            .read(projectSchedulerProvider.notifier)
            .appendRun(
              ProjectScheduledTaskRun(
                taskId: draft.id,
                projectId: project.id,
                status: 'saved',
                message: statusText,
                triggeredManually: false,
                triggeredAt: now,
              ),
            );
      }
      await journaled.markCommitted(ref);
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: isEdit ? SchedulerAction.update : SchedulerAction.create,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = 'Couldn’t save this scheduled job.\n$error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: isEdit ? SchedulerAction.update : SchedulerAction.create,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _deleteCustomTask({
    required Project project,
    required Server server,
    required ProjectScheduledTask task,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final messenger = ScaffoldMessenger.of(context);
    final taskScope = WorkspaceScope(
      projectId: project.id,
      serverId: server.id,
    );
    final busyKey = _busyTasks.key(
      scope: taskScope,
      kind: 'scheduler-task',
      id: task.id,
    );
    final connection = await _buildConnectionPayload(server);
    if (!mounted) {
      return;
    }
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AppDestructiveConfirmDialog(
          title: 'Delete scheduled job',
          description: schedulerDeleteDescription(task.name),
        );
      },
    );
    if (confirmed != true ||
        !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
      return;
    }

    setState(() {
      _busyTasks.markBusy(
        scope: taskScope,
        kind: 'scheduler-task',
        id: task.id,
      );
      _error = null;
    });

    try {
      final settings = <String, dynamic>{
        'project_slug': slugifyProjectName(
          project.name,
          fallback: 'project-scheduler',
        ),
        'task_id': task.id,
      };
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'scheduler',
        operationType: 'task_delete',
        workflowId: 'scheduler',
        operationId: 'task_delete',
        connection: connection,
        params: <String, dynamic>{'dry_run': false, 'settings': settings},
        journalRequest: <String, dynamic>{
          'workflow_id': 'scheduler',
          'operation_id': 'task_delete',
          'task_id': task.id,
        },
      );
      final response = journaled.response;
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        setState(() {
          _error =
              response['msg']?.toString() ??
              'Couldn’t delete this scheduled job.';
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackSchedulerEvent(
              action: SchedulerAction.delete,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      await ref
          .read(projectSchedulerProvider.notifier)
          .deleteTask(projectId: project.id, taskId: task.id);
      await journaled.markCommitted(ref);
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      setState(() {
        _busyTasks.remove(busyKey);
      });
      messenger.showSnackBar(
        SnackBar(content: Text(schedulerTaskDeletedMessage())),
      );
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.delete,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _busyTasks.remove(busyKey);
        _error = 'Couldn’t delete this scheduled job.\n$error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.delete,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _busyTasks.remove(busyKey);
        });
      }
    }
  }

  Future<void> _setCustomTaskEnabled({
    required Project project,
    required Server server,
    required ProjectScheduledTask task,
    required bool enabled,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final busyKey = _busyTasks.markBusy(
      scope: WorkspaceScope(projectId: project.id, serverId: server.id),
      kind: 'scheduler-task',
      id: task.id,
    );
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    setState(() {
      _error = null;
    });
    _appendSchedulerTerminalLine('Run scheduled job "${task.name}".');
    try {
      final settings = <String, dynamic>{
        'project_slug': slugifyProjectName(
          project.name,
          fallback: 'project-scheduler',
        ),
        'task_id': task.id,
        'enabled': enabled,
      };
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'scheduler',
        operationType: 'task_set_enabled',
        workflowId: 'scheduler',
        operationId: 'task_set_enabled',
        connection: connection,
        params: <String, dynamic>{'dry_run': false, 'settings': settings},
        journalRequest: <String, dynamic>{
          'workflow_id': 'scheduler',
          'operation_id': 'task_set_enabled',
          'task_id': task.id,
          'enabled': enabled,
        },
      );
      final response = journaled.response;

      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        setState(() {
          _error =
              response['msg']?.toString() ??
              'Couldn’t update this scheduled job.';
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackSchedulerEvent(
              action: SchedulerAction.update,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      await ref
          .read(projectSchedulerProvider.notifier)
          .updateTaskRuntimeStatus(
            projectId: project.id,
            taskId: task.id,
            enabled: enabled,
            lastKnownState: response['timer_active_state']?.toString(),
            lastKnownMessage: response['service_result']?.toString(),
            nextRunAt: schedulerParseIsoDate(response['next_run_at']),
            lastRunAt: schedulerParseIsoDate(response['last_run_at']),
          );
      await journaled.markCommitted(ref);
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.update,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t update this scheduled job.\n$error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.update,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _busyTasks.remove(busyKey);
        });
      }
    }
  }

  Future<void> _runTaskNow({
    required Project project,
    required Server server,
    required ProjectScheduledTask task,
  }) async {
    // The row button is the only caller: this is the press, before the
    // connection check, so taps that cannot start still count as intent.
    // The scheduler tab drives engine workflows from widget state (the
    // provider owns local task state only), which is why the hook lives
    // here rather than in a provider.
    ref
        .read(appAnalyticsServiceProvider)
        .trackControlUsed(control: AppControl.runNowPressed);
    final operationEpoch = workspaceBindEpoch;
    final messenger = ScaffoldMessenger.of(context);
    final busyKey = _busyTasks.markBusy(
      scope: WorkspaceScope(projectId: project.id, serverId: server.id),
      kind: 'scheduler-task',
      id: task.id,
    );
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _error = serverCredentialsReconnectMessage();
      });
      return;
    }

    setState(() {
      _error = null;
    });
    try {
      final settings = <String, dynamic>{
        'project_slug': slugifyProjectName(
          project.name,
          fallback: 'project-scheduler',
        ),
        'task_id': task.id,
      };
      if ((task.targetType == 'web_app' || task.targetType == 'worker') &&
          task.command.trim().isNotEmpty) {
        settings.addAll(<String, dynamic>{
          'target_type': task.targetType,
          'target_ref': task.targetRef,
          'command': task.command,
        });
      }
      final journaled = await _runJournaledProjectWorkflow(
        ref: ref,
        project: project,
        server: server,
        surface: 'scheduler',
        operationType: 'task_run_now',
        workflowId: 'scheduler',
        operationId: 'task_run_now',
        connection: connection,
        params: <String, dynamic>{'dry_run': false, 'settings': settings},
        journalRequest: <String, dynamic>{
          'workflow_id': 'scheduler',
          'operation_id': 'task_run_now',
          'task_id': task.id,
          'target_type': task.targetType,
          'target_ref': task.targetRef,
          'command': task.command,
        },
      );
      final response = journaled.response;

      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        final message = _schedulerActionFailureMessage(
          response,
          fallback: 'The scheduled job did not start on the server.',
        );
        await ref
            .read(projectSchedulerProvider.notifier)
            .appendRun(
              ProjectScheduledTaskRun(
                taskId: task.id,
                projectId: project.id,
                status: 'failed',
                message: message,
                triggeredManually: true,
                triggeredAt: DateTime.now(),
              ),
            );
        if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
          return;
        }
        setState(() {
          _error = message;
        });
        _appendSchedulerTerminalLine(
          'Scheduled job "${task.name}" did not start: $message',
        );
        await journaled.markCommitted(ref);
        await _showSchedulerActionErrorDialog(
          title: 'Scheduled job did not start',
          message: message,
        );
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackSchedulerEvent(
              action: SchedulerAction.run,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      final now =
          schedulerParseIsoDate(response['finished_at']) ?? DateTime.now();
      final successMessage = _schedulerRunSuccessMessage(response);
      await ref
          .read(projectSchedulerProvider.notifier)
          .appendRun(
            ProjectScheduledTaskRun(
              taskId: task.id,
              projectId: project.id,
              status: 'completed',
              message: successMessage,
              triggeredManually: true,
              triggeredAt: now,
            ),
          );
      await ref
          .read(projectSchedulerProvider.notifier)
          .updateTaskRuntimeStatus(
            projectId: project.id,
            taskId: task.id,
            lastKnownState: response['service_active_state']?.toString(),
            lastKnownMessage:
                response['service_result']?.toString() ??
                (response['run_succeeded'] == true ? 'success' : null),
            lastRunAt: now,
          );
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(schedulerTaskCompletedMessage())),
      );
      _appendSchedulerTerminalLine('Scheduled job "${task.name}" completed.');
      for (final line in _schedulerRunOutputLines(response)) {
        _appendSchedulerTerminalLine(line, detail: true);
      }
      await _refreshTaskStatus(
        project: project,
        server: server,
        quiet: true,
        expectedEpoch: operationEpoch,
      );
      await journaled.markCommitted(ref);
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.run,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      _appendSchedulerTerminalLine(
        'Scheduled job "${task.name}" did not start: $error',
      );
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _error = 'Couldn’t run this scheduled job.\n$error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackSchedulerEvent(
            action: SchedulerAction.run,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _busyTasks.remove(busyKey);
        });
      }
    }
  }

  Future<_SchedulerTaskDraft?> _showTaskEditorDialog({
    required List<ProjectWorkerInstance> workers,
    _SchedulerTaskDraft? initial,
  }) async {
    final nameController = TextEditingController(text: initial?.name ?? '');
    final commandController = TextEditingController(
      text: initial?.command ?? '',
    );
    final intervalController = TextEditingController(
      text: (initial?.intervalValue ?? 5).toString(),
    );
    final dailyTimeController = TextEditingController(
      text: initial?.dailyTime ?? '02:00',
    );

    var targetType = initial?.targetType ?? 'web_app';
    var selectedWorkerId = initial?.targetRef;
    var scheduleType = initial?.scheduleType ?? 'every_minutes';
    var enabled = initial?.enabled ?? true;

    final result = await showDialog<_SchedulerTaskDraft>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final currentWorkerId = selectedWorkerId;
            final name = nameController.text.trim();
            final command = commandController.text.trim();
            final interval = int.tryParse(intervalController.text.trim());
            final dailyTime = dailyTimeController.text.trim();
            final needsWorker = targetType == 'worker';
            final needsInterval = scheduleType != 'daily_at';
            final needsDailyTime = scheduleType == 'daily_at';

            final nameError = name.isEmpty ? 'Task name is required.' : null;
            final commandError = command.isEmpty
                ? 'Command is required.'
                : null;
            final workerError =
                needsWorker &&
                    (currentWorkerId == null || currentWorkerId.trim().isEmpty)
                ? 'Select a worker target.'
                : null;
            final intervalError =
                needsInterval &&
                    (interval == null || interval < 1 || interval > 1440)
                ? 'Interval must be between 1 and 1440.'
                : null;
            final dailyTimeError =
                needsDailyTime &&
                    !RegExp(r'^(?:[01]?\d|2[0-3]):[0-5]\d$').hasMatch(dailyTime)
                ? 'Use HH:MM (24-hour).'
                : null;
            final canSave =
                nameError == null &&
                commandError == null &&
                workerError == null &&
                intervalError == null &&
                dailyTimeError == null;

            return AppFormDialog(
              title: schedulerEditorTitle(initial != null),
              description: schedulerEditorDescription(),
              // ignore: sort_child_properties_last
              child: SizedBox(
                width: 560,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppTextFormField(
                      fieldKey: const Key('scheduler-editor-name-field'),
                      controller: nameController,
                      onChanged: (_) => setDialogState(() {}),
                      labelText: 'Task name',
                      validator: (_) => nameError,
                    ),
                    const SizedBox(height: 10),
                    AppSelectFormField<String>(
                      fieldKey: const Key('scheduler-editor-target-type'),
                      value: targetType,
                      labelText: 'Target',
                      items: const [
                        DropdownMenuItem(
                          value: 'web_app',
                          child: Text('Web app container'),
                        ),
                        DropdownMenuItem(
                          value: 'worker',
                          child: Text('Worker container'),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          targetType = value ?? 'web_app';
                          if (targetType != 'worker') {
                            selectedWorkerId = null;
                          }
                        });
                      },
                    ),
                    if (targetType == 'worker') ...[
                      const SizedBox(height: 10),
                      AppSelectFormField<String>(
                        fieldKey: const Key('scheduler-editor-worker-target'),
                        value: selectedWorkerId,
                        labelText: 'Worker',
                        validator: (_) => workerError,
                        items: workers
                            .map(
                              (worker) => DropdownMenuItem<String>(
                                value: worker.id,
                                child: Text(
                                  '${worker.name} (${worker.id})',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: (value) {
                          setDialogState(() {
                            selectedWorkerId = value;
                          });
                        },
                      ),
                    ],
                    const SizedBox(height: 10),
                    AppTextFormField(
                      fieldKey: const Key('scheduler-editor-command-field'),
                      controller: commandController,
                      onChanged: (_) => setDialogState(() {}),
                      maxLines: 3,
                      labelText: 'Command',
                      hintText: 'php artisan queue:work --once',
                      validator: (_) => commandError,
                    ),
                    const SizedBox(height: 10),
                    AppSelectFormField<String>(
                      fieldKey: const Key('scheduler-editor-schedule-type'),
                      value: scheduleType,
                      labelText: 'Schedule',
                      items: const [
                        DropdownMenuItem(
                          value: 'every_minutes',
                          child: Text('Every X minutes'),
                        ),
                        DropdownMenuItem(
                          value: 'every_hours',
                          child: Text('Every X hours'),
                        ),
                        DropdownMenuItem(
                          value: 'daily_at',
                          child: Text('Daily at HH:MM'),
                        ),
                      ],
                      onChanged: (value) {
                        setDialogState(() {
                          scheduleType = value ?? 'every_minutes';
                        });
                      },
                    ),
                    if (scheduleType != 'daily_at') ...[
                      const SizedBox(height: 10),
                      AppNumberFormField(
                        fieldKey: const Key('scheduler-editor-interval-field'),
                        controller: intervalController,
                        onChanged: (_) => setDialogState(() {}),
                        labelText: scheduleType == 'every_hours'
                            ? 'Hours'
                            : 'Minutes',
                        validator: (_) => intervalError,
                      ),
                    ],
                    if (scheduleType == 'daily_at') ...[
                      const SizedBox(height: 10),
                      AppTextFormField(
                        fieldKey: const Key(
                          'scheduler-editor-daily-time-field',
                        ),
                        controller: dailyTimeController,
                        onChanged: (_) => setDialogState(() {}),
                        labelText: 'Daily time (HH:MM)',
                        validator: (_) => dailyTimeError,
                      ),
                    ],
                    const SizedBox(height: 10),
                    AppToggleField(
                      fieldKey: const Key('scheduler-editor-enabled-toggle'),
                      value: enabled,
                      onChanged: (value) {
                        setDialogState(() {
                          enabled = value;
                        });
                      },
                      title: 'Turn on this job',
                    ),
                  ],
                ),
              ),
              maxWidth: 560,
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('scheduler-editor-save-button'),
                  onPressed: !canSave
                      ? null
                      : () {
                          Navigator.of(dialogContext).pop(
                            _SchedulerTaskDraft(
                              id: initial?.id ?? '',
                              name: name,
                              targetType: targetType,
                              targetRef: targetType == 'worker'
                                  ? selectedWorkerId
                                  : null,
                              command: command,
                              scheduleType: scheduleType,
                              intervalValue: scheduleType == 'daily_at'
                                  ? null
                                  : interval,
                              dailyTime: scheduleType == 'daily_at'
                                  ? dailyTime
                                  : null,
                              enabled: enabled,
                            ),
                          );
                        },
                  child: Text(schedulerSaveLabel()),
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
      intervalController.dispose();
      dailyTimeController.dispose();
    });

    return result;
  }

  Future<void> _createTask(
    Project project,
    Server server,
    List<ProjectScheduledTask> existing,
    List<ProjectWorkerInstance> workers,
  ) async {
    final draft = await _showTaskEditorDialog(workers: workers);
    if (draft == null) {
      return;
    }

    final resolvedId = schedulerNextTaskId(draft.name, existing);
    await _saveCustomTask(
      project: project,
      server: server,
      draft: draft.copyWith(id: resolvedId),
      isEdit: false,
      sortOrder: existing.where((task) => !task.managedByService).length,
    );
  }

  Future<void> _editTask(
    Project project,
    Server server,
    ProjectScheduledTask task,
    List<ProjectWorkerInstance> workers,
  ) async {
    final updated = await _showTaskEditorDialog(
      workers: workers,
      initial: _SchedulerTaskDraft.fromTask(task),
    );
    if (updated == null) {
      return;
    }

    await _saveCustomTask(
      project: project,
      server: server,
      draft: updated.copyWith(id: task.id),
      isEdit: true,
      sortOrder: task.sortOrder,
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    _scheduleSelectionBind(selectedProject, selectedServer);

    if (selectedProject == null || selectedServer == null) {
      return const Text(
        'Choose a project and server before you manage scheduled jobs.',
        key: Key('scheduler-missing-selection-message'),
      );
    }

    final workers =
        ref
            .watch(projectWorkerInstancesProvider)[selectedProject.id]
            ?.toList(growable: false) ??
        const <ProjectWorkerInstance>[];

    final schedulerState = ref.watch(projectSchedulerProvider);
    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted.
    final error = _error;
    final releaseScope = ref
        .watch(appReleaseProvider)
        .scopeFor(projectId: selectedProject.id, serverId: selectedServer.id);
    final hasAppRuntime = _projectHasAppRuntime(
      project: selectedProject,
      releaseScope: releaseScope,
    );
    final allTasks = schedulerState.tasksForProject(selectedProject.id);
    final customTasks = allTasks
        .where((task) => !task.managedByService)
        .toList(growable: false);
    final managedTasks = allTasks
        .where((task) => task.managedByService)
        .toList(growable: false);
    final runs = schedulerState.runsForProject(selectedProject.id);

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (customTasks.isEmpty && managedTasks.isEmpty && runs.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!hasAppRuntime) ...[
            _ProjectAppRuntimeRequiredCallout(
              key: const Key('scheduler-app-runtime-required-callout'),
              onOpenWebAppTab: widget.onOpenWebAppTab,
            ),
            const SizedBox(height: 14),
          ],
          AppWorkspaceSection(
            key: const Key('scheduler-empty-state'),
            title: 'Scheduled jobs',
            child: AppEmptyStateView(
              icon: Icons.schedule_outlined,
              title: 'No scheduled jobs yet',
              message: schedulerCustomSectionEmptyMessage(),
              action: FilledButton.icon(
                key: const Key('scheduler-add-task-button'),
                onPressed: _isSaving || !hasAppRuntime
                    ? null
                    : () {
                        // Empty-state taps report here, not in a provider:
                        // the editor dialog and the save path below serve
                        // edits and the toolbar add too, so provider-hooking
                        // would mislabel those as empty-state acts.
                        ref
                            .read(appAnalyticsServiceProvider)
                            .trackControlUsed(
                              control: AppControl.emptyStateAction,
                            );
                        _createTask(
                          selectedProject,
                          selectedServer,
                          customTasks,
                          workers,
                        );
                      },
                icon: const Icon(Icons.add),
                label: const Text('Add scheduled job'),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            FilledButton.icon(
              key: const Key('scheduler-add-task-button'),
              onPressed: _isSaving || !hasAppRuntime
                  ? null
                  : () => _createTask(
                      selectedProject,
                      selectedServer,
                      customTasks,
                      workers,
                    ),
              icon: const Icon(Icons.add),
              label: const Text('Add scheduled job'),
            ),
            const SizedBox(width: 10),
            IconButton(
              key: const Key('scheduler-refresh-status-button'),
              tooltip: 'Refresh',
              onPressed: _isRefreshingStatus
                  ? null
                  : () => _refreshTaskStatus(
                      project: selectedProject,
                      server: selectedServer,
                    ),
              icon: _isRefreshingStatus
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ],
        ),
        if (!hasAppRuntime) ...[
          const SizedBox(height: 12),
          _ProjectAppRuntimeRequiredCallout(
            key: const Key('scheduler-app-runtime-required-callout'),
            onOpenWebAppTab: widget.onOpenWebAppTab,
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            error,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          schedulerCustomSectionTitle(),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        if (customTasks.isEmpty)
          // No action here: the toolbar's `scheduler-add-task-button` is
          // already on screen directly above this state, and one primary
          // action per section is the rule. The all-empty branch above does
          // carry the button, because it renders no toolbar. G-40.
          AppEmptyStateView(
            key: const Key('scheduler-custom-empty-state'),
            icon: Icons.schedule_outlined,
            title: 'No scheduled jobs yet',
            message: schedulerCustomSectionEmptyMessage(),
          )
        else
          ...customTasks.map((task) {
            final taskBusy = _isTaskBusy(task);
            final lastKnownState = task.lastKnownState;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            task.name,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        Switch.adaptive(
                          key: Key('scheduler-task-enabled-${task.id}'),
                          value: task.enabled,
                          onChanged: _isSaving || taskBusy
                              ? null
                              : (value) => _setCustomTaskEnabled(
                                  project: selectedProject,
                                  server: selectedServer,
                                  task: task,
                                  enabled: value,
                                ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${schedulerScheduleSummary(task)} · ${_targetSummary(task)}',
                    ),
                    const SizedBox(height: 4),
                    Text(
                      task.command,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (lastKnownState != null)
                          Chip(
                            label: Text(lastKnownState),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (task.nextRunAt != null)
                          Chip(
                            label: Text('Next: ${task.nextRunAt}'),
                            visualDensity: VisualDensity.compact,
                          ),
                        if (task.lastRunAt != null)
                          Chip(
                            label: Text('Last: ${task.lastRunAt}'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        IconButton(
                          key: Key('scheduler-run-now-${task.id}'),
                          tooltip: 'Run now',
                          onPressed: _isSaving || taskBusy
                              ? null
                              : () => _runTaskNow(
                                  project: selectedProject,
                                  server: selectedServer,
                                  task: task,
                                ),
                          icon: const Icon(
                            Icons.play_arrow,
                            semanticLabel: 'Run now',
                          ),
                        ),
                        IconButton(
                          key: Key('scheduler-edit-${task.id}'),
                          tooltip: 'Edit scheduled job',
                          onPressed: _isSaving || taskBusy
                              ? null
                              : () => _editTask(
                                  selectedProject,
                                  selectedServer,
                                  task,
                                  workers,
                                ),
                          icon: const Icon(
                            Icons.edit_outlined,
                            semanticLabel: 'Edit scheduled job',
                          ),
                        ),
                        IconButton(
                          key: Key('scheduler-delete-${task.id}'),
                          tooltip: 'Delete scheduled job',
                          onPressed: _isSaving || taskBusy
                              ? null
                              : () => _deleteCustomTask(
                                  project: selectedProject,
                                  server: selectedServer,
                                  task: task,
                                ),
                          icon: const Icon(
                            Icons.delete_outline,
                            semanticLabel: 'Delete scheduled job',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        if (managedTasks.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            schedulerManagedSectionTitle(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          ...managedTasks.map(
            (task) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.lock_outline),
              title: Text(task.name),
              subtitle: Text(
                '${schedulerScheduleSummary(task)} · ${_targetSummary(task)}',
              ),
              trailing: const Chip(label: Text('Read only')),
            ),
          ),
        ],
        if (runs.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            schedulerRunsSectionTitle(),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          ...runs
              .take(12)
              .map(
                (run) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    run.triggeredManually
                        ? Icons.play_circle_outline
                        : Icons.schedule,
                    size: 20,
                  ),
                  title: Text('${run.taskId} · ${run.status}'),
                  subtitle: Text(
                    '${run.triggeredAt}${run.message == null ? '' : ' · ${run.message}'}',
                  ),
                ),
              ),
        ],
      ],
    );
  }
}
