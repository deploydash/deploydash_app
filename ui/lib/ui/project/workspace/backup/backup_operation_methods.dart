// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _BackupOperationMethods on _BackupSummaryState {
  Future<void> _saveDestination({
    required Project project,
    required Server server,
    required _BackupDestinationDraft draft,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final destinationId =
          draft.id ??
          '${draft.name.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "-").replaceAll(RegExp(r"^-+|-+$"), "")}-${DateTime.now().millisecondsSinceEpoch}';
      await ref
          .read(projectBackupProvider.notifier)
          .upsertDestination(
            BackupDestinationRecord(
              id: destinationId,
              projectId: project.id,
              serverId: server.id,
              name: draft.name,
              type: draft.type,
              config: draft.config,
            ),
          );
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            draft.id == null
                ? 'Backup destination created.'
                : 'Backup destination updated.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = 'Could not save destination: $error';
      });
    }
  }

  Future<void> _deleteDestination({
    required Project project,
    required Server server,
    required BackupDestinationRecord destination,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await ref
          .read(projectBackupProvider.notifier)
          .deleteDestination(
            id: destination.id,
            projectId: project.id,
            serverId: server.id,
          );
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup destination deleted.')),
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Delete backup destination failed',
        message: 'Could not delete destination: $error',
      );
    }
  }

  Future<void> _savePolicy({
    required Project project,
    required Server server,
    required _BackupPolicyDraft draft,
    required BackupDestinationRecord destination,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!_validateDestinationForActiveEngine(
      destination: destination,
      actionLabel: 'Save policy',
      engine: engine,
    )) {
      return;
    }
    try {
      final policyId =
          draft.id ??
          '${draft.name.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), "-").replaceAll(RegExp(r"^-+|-+$"), "")}-${DateTime.now().millisecondsSinceEpoch}';
      final managedTaskId =
          draft.managedTaskId ?? _taskIdForPolicy(policyId, engine: engine);
      final logicalDatabaseName = logicalManagedPostgresName(
        projectName: project.name,
        remoteName: draft.databaseName,
      );
      final journaled = await _runJournaledBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'backup_policy_apply',
        extraSettings: <String, dynamic>{
          ..._destinationSettings(destination, engine),
          'backup_policy_id': policyId,
          'backup_policy_name': draft.name,
          'backup_task_id': managedTaskId,
          'backup_database_name': logicalDatabaseName,
          'backup_schedule_mode': draft.scheduleMode,
          'backup_time1': draft.time1Hhmm,
          'backup_time2': draft.time2Hhmm,
          'backup_retention_keep_last': draft.retentionKeepLast,
          'enabled': draft.enabled,
        },
        journalRequest: <String, dynamic>{
          'workflow_id': _activeWorkflowId(engine),
          'operation_id': 'backup_policy_apply',
          'engine': _activeEngineRecord(engine).name,
          'policy_id': policyId,
          'policy_name': draft.name,
          'destination_id': draft.destinationId,
          'database_name': logicalDatabaseName,
          'schedule_mode': draft.scheduleMode,
          'time1': draft.time1Hhmm,
          'time2': draft.time2Hhmm,
          'retention_keep_last': draft.retentionKeepLast,
          'enabled': draft.enabled,
          'managed_task_id': managedTaskId,
        },
        onEvent: _appendBackupLogEvent,
      );
      final response = journaled.response;
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        _appendBackupResultLog(
          prefix: 'Save backup policy',
          response: response,
        );
        setState(() {
          _isSaving = false;
          _error = _responseMessageWithDetails(
            response,
            fallback: 'Could not save policy.',
          );
        });
        return;
      }
      _appendBackupResultLog(prefix: 'Save backup policy', response: response);

      final policy = BackupPolicyRecord(
        engine: _activeEngineRecord(engine),
        id: policyId,
        projectId: project.id,
        serverId: server.id,
        name: draft.name,
        destinationId: draft.destinationId,
        databaseName: draft.databaseName,
        scheduleMode: draft.scheduleMode,
        time1Hhmm: draft.time1Hhmm,
        time2Hhmm: draft.time2Hhmm,
        retentionKeepLast: draft.retentionKeepLast,
        enabled: draft.enabled,
        managedTaskId: managedTaskId,
      );

      await ref.read(projectBackupProvider.notifier).upsertPolicy(policy);

      final schedulerTask = ProjectScheduledTask(
        id: managedTaskId,
        projectId: project.id,
        sourceType: 'service',
        managedByService: true,
        name: 'Backup: ${draft.name}',
        targetType: 'host',
        command: 'Managed PostgreSQL backup policy',
        scheduleType: 'daily_at',
        dailyTime: draft.scheduleMode == 'daily_twice'
            ? '${draft.time1Hhmm},${draft.time2Hhmm ?? ''}'
            : draft.time1Hhmm,
        enabled: draft.enabled,
      );
      await ref
          .read(projectSchedulerProvider.notifier)
          .upsertTask(schedulerTask);
      await journaled.markCommitted(ref);

      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            draft.id == null
                ? 'Backup policy created.'
                : 'Backup policy updated.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = 'Could not save backup policy: $error';
      });
    }
  }

  Future<void> _deletePolicy({
    required Project project,
    required Server server,
    required BackupPolicyRecord policy,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final journaled = await _runJournaledBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'backup_policy_delete',
        extraSettings: <String, dynamic>{
          'backup_policy_id': policy.id,
          'backup_task_id': policy.managedTaskId,
        },
        journalRequest: <String, dynamic>{
          'workflow_id': _activeWorkflowId(engine),
          'operation_id': 'backup_policy_delete',
          'engine': policy.engine.name,
          'policy_id': policy.id,
          'managed_task_id': policy.managedTaskId,
        },
        onEvent: _appendBackupLogEvent,
      );
      final response = journaled.response;
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (response['status'] != 'success') {
        _appendBackupResultLog(
          prefix: 'Delete backup policy',
          response: response,
        );
        final message = _responseMessageWithDetails(
          response,
          fallback: 'Could not delete policy.',
        );
        setState(() {
          _isSaving = false;
          _error = null;
        });
        await _showWorkspaceActionErrorDialog(
          title: 'Delete backup policy failed',
          message: message,
        );
        return;
      }
      _appendBackupResultLog(
        prefix: 'Delete backup policy',
        response: response,
      );
      await ref
          .read(projectBackupProvider.notifier)
          .deletePolicy(
            engine: policy.engine,
            id: policy.id,
            projectId: project.id,
            serverId: server.id,
          );
      await ref
          .read(projectSchedulerProvider.notifier)
          .deleteTask(projectId: project.id, taskId: policy.managedTaskId);
      await journaled.markCommitted(ref);
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Backup policy deleted.')));
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Delete backup policy failed',
        message: 'Could not delete backup policy: $error',
      );
    }
  }

  Future<void> _runBackupNow({
    required Project project,
    required Server server,
    required BackupPolicyRecord policy,
    required BackupDestinationRecord destination,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!_validateDestinationForActiveEngine(
      destination: destination,
      actionLabel: 'Run backup',
      engine: engine,
    )) {
      return;
    }
    try {
      final logicalDatabaseName = logicalManagedPostgresName(
        projectName: project.name,
        remoteName: policy.databaseName,
      );
      final journaled = await _runJournaledBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'backup_run_now',
        extraSettings: <String, dynamic>{
          ..._destinationSettings(destination, engine),
          'backup_policy_id': policy.id,
          'backup_policy_name': policy.name,
          'backup_task_id': policy.managedTaskId,
          'backup_database_name': logicalDatabaseName,
          'backup_schedule_mode': policy.scheduleMode,
          'backup_time1': policy.time1Hhmm,
          'backup_time2': policy.time2Hhmm,
          'backup_retention_keep_last': policy.retentionKeepLast,
          'enabled': policy.enabled,
        },
        journalRequest: <String, dynamic>{
          'workflow_id': _activeWorkflowId(engine),
          'operation_id': 'backup_run_now',
          'engine': policy.engine.name,
          'policy_id': policy.id,
          'managed_task_id': policy.managedTaskId,
          'database_name': logicalDatabaseName,
        },
        onEvent: _appendBackupLogEvent,
      );
      final response = journaled.response;
      final status = response['status']?.toString() ?? 'error';
      final message = status == 'success'
          ? response['msg']?.toString()
          : _responseMessageWithDetails(
              response,
              fallback: 'Backup run failed.',
            );
      final startedAt = DateTime.now().toUtc();
      _appendBackupResultLog(prefix: 'Run backup now', response: response);
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      // One report per invocation: the outcome is known and the scope is
      // current; the dialogs below only present it.
      ref
          .read(appAnalyticsServiceProvider)
          .trackBackupEvent(
            kind: _analyticsBackupKindFor(policy.engine),
            outcome: status == 'success'
                ? DataOperationOutcome.success
                : DataOperationOutcome.failure,
          );

      await ref
          .read(projectBackupProvider.notifier)
          .appendRun(
            BackupRunRecord(
              engine: policy.engine,
              projectId: project.id,
              serverId: server.id,
              policyId: policy.id,
              operationType: BackupOperationType.backup,
              status: status,
              message: message,
              triggeredManually: true,
              taskId: policy.managedTaskId,
              startedAt: startedAt,
              finishedAt: DateTime.now().toUtc(),
            ),
          );
      await ref
          .read(projectSchedulerProvider.notifier)
          .appendRun(
            ProjectScheduledTaskRun(
              taskId: policy.managedTaskId,
              projectId: project.id,
              status: status,
              message: message,
              triggeredManually: true,
              triggeredAt: startedAt.toLocal(),
            ),
          );

      await ref
          .read(backupRepositoryProvider)
          .updatePolicyRuntime(
            engine: policy.engine,
            policyId: policy.id,
            projectId: project.id,
            serverId: server.id,
            lastRunAt: DateTime.now().toUtc(),
            lastStatus: status,
            lastMessage: message,
          );
      await ref
          .read(projectBackupProvider.notifier)
          .loadScope(projectId: project.id, serverId: server.id);
      await journaled.markCommitted(ref);

      if (status == 'success') {
        await _refreshArtifactsForPolicy(
          project: project,
          server: server,
          engine: engine,
          policy: policy,
          destination: destination,
          expectedEpoch: operationEpoch,
        );
      }

      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      if (status == 'success') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Backup run completed.')));
        return;
      }
      await _showWorkspaceActionErrorDialog(
        title: 'Run backup failed',
        message: message ?? 'Backup run failed.',
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Run backup failed',
        message: 'Could not run backup: $error',
      );
      ref
          .read(appAnalyticsServiceProvider)
          .trackBackupEvent(
            kind: _analyticsBackupKindFor(policy.engine),
            outcome: DataOperationOutcome.failure,
          );
    }
  }

  Future<void> _refreshArtifacts({
    required Project project,
    required Server server,
    required BackupPolicyRecord policy,
    required BackupDestinationRecord destination,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!_validateDestinationForActiveEngine(
      destination: destination,
      actionLabel: 'Refresh artifacts',
      engine: engine,
    )) {
      return;
    }
    try {
      final error = await _refreshArtifactsForPolicy(
        project: project,
        server: server,
        engine: engine,
        policy: policy,
        destination: destination,
        expectedEpoch: operationEpoch,
        showSuccessSnackbar: false,
      );
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (error != null) {
        setState(() {
          _isSaving = false;
          _error = null;
        });
        await _showWorkspaceActionErrorDialog(
          title: 'Refresh backups failed',
          message: error,
        );
        return;
      }

      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup artifacts refreshed.')),
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Refresh backups failed',
        message: 'Could not refresh backup artifacts: $error',
      );
    }
  }

  Future<String?> _refreshArtifactsForPolicy({
    required Project project,
    required Server server,
    required _BackupEngineChoice engine,
    required BackupPolicyRecord policy,
    required BackupDestinationRecord destination,
    int? expectedEpoch,
    bool showSuccessSnackbar = false,
  }) async {
    final logicalDatabaseName = logicalManagedPostgresName(
      projectName: project.name,
      remoteName: policy.databaseName,
    );
    final response = await _runBackupWorkflow(
      project: project,
      server: server,
      engine: engine,
      operationId: 'backup_artifact_list',
      extraSettings: <String, dynamic>{
        ..._destinationSettings(destination, engine),
        'backup_policy_id': policy.id,
        'backup_policy_name': policy.name,
        'backup_task_id': policy.managedTaskId,
        'backup_database_name': logicalDatabaseName,
      },
      onEvent: _appendBackupLogEvent,
    );
    if (!isCurrentWorkspaceSelection(project, server, expectedEpoch)) {
      return null;
    }
    if (isBackupArtifactRefreshDuplicate(response)) {
      // The identical listing is still queued or running under another
      // operation id; there is no artifact list in this answer. Returning a
      // message (rather than storing an empty list) keeps the stored
      // artifacts on screen until the running original reports.
      _appendBackupResultLog(
        prefix: 'Refresh backup artifacts',
        response: response,
      );
      return backupArtifactRefreshDuplicateMessage();
    }
    if (response['status'] != 'success') {
      _appendBackupResultLog(
        prefix: 'Refresh backup artifacts',
        response: response,
      );
      return _responseMessageWithDetails(
        response,
        fallback: 'Could not refresh artifacts.',
      );
    }
    _appendBackupResultLog(
      prefix: 'Refresh backup artifacts',
      response: response,
    );
    final artifactsPayload = response['artifacts'];
    if (artifactsPayload is! List) {
      // A success with no artifact list is not the same as "there are none".
      // Replacing on this would delete every stored artifact for the policy,
      // mirroring the provider-side guard (G-42).
      return 'The server did not return a backup list.';
    }
    final artifacts = backupArtifactsFromBackendPayload(
      artifactsPayload: artifactsPayload,
      policy: policy,
      destination: destination,
    );

    await ref
        .read(projectBackupProvider.notifier)
        .replaceArtifactsForPolicy(
          engine: policy.engine,
          policyId: policy.id,
          projectId: project.id,
          serverId: server.id,
          artifacts: artifacts,
        );
    if (showSuccessSnackbar && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Backup artifacts refreshed.')),
      );
    }
    return null;
  }

  Future<void> _cleanupBacklog({
    required Project project,
    required Server server,
    required BackupPolicyRecord policy,
    required BackupDestinationRecord destination,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!_validateDestinationForActiveEngine(
      destination: destination,
      actionLabel: 'Clean up old backups',
      engine: engine,
    )) {
      return;
    }
    try {
      final logicalDatabaseName = logicalManagedPostgresName(
        projectName: project.name,
        remoteName: policy.databaseName,
      );
      final extraSettings = <String, dynamic>{
        ..._destinationSettings(destination, engine),
        'backup_policy_id': policy.id,
        'backup_policy_name': policy.name,
        'backup_task_id': policy.managedTaskId,
        'backup_database_name': logicalDatabaseName,
      };
      final report = await _runBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'backup_backlog_report',
        extraSettings: extraSettings,
        onEvent: _appendBackupLogEvent,
      );
      _appendBackupResultLog(prefix: 'Report backup backlog', response: report);
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (report['status'] != 'success') {
        setState(() {
          _isSaving = false;
          _error = null;
        });
        await _showWorkspaceActionErrorDialog(
          title: 'Clean up old backups failed',
          message: _responseMessageWithDetails(
            report,
            fallback: 'Could not report the backup backlog.',
          ),
        );
        return;
      }
      final backlogCount =
          (report['beyond_retention_count'] as num?)?.toInt() ?? 0;
      if (backlogCount <= 0) {
        setState(() {
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(backupBacklogCleanupEmptyMessage())),
        );
        return;
      }
      final confirmed = await _showBacklogCleanupDialog(
        report: report,
        policy: policy,
      );
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      if (!confirmed) {
        setState(() {
          _isSaving = false;
        });
        return;
      }
      final journaled = await _runJournaledBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'backup_backlog_cleanup',
        extraSettings: extraSettings,
        journalRequest: <String, dynamic>{
          'workflow_id': _activeWorkflowId(engine),
          'operation_id': 'backup_backlog_cleanup',
          'engine': policy.engine.name,
          'policy_id': policy.id,
          'managed_task_id': policy.managedTaskId,
        },
        onEvent: _appendBackupLogEvent,
      );
      final response = journaled.response;
      final status = response['status']?.toString() ?? 'error';
      final message = status == 'success'
          ? response['msg']?.toString()
          : _responseMessageWithDetails(
              response,
              fallback: 'Clean up old backups failed.',
            );
      _appendBackupResultLog(
        prefix: 'Clean up backup backlog',
        response: response,
      );
      await ref
          .read(projectBackupProvider.notifier)
          .appendRun(
            BackupRunRecord(
              engine: policy.engine,
              projectId: project.id,
              serverId: server.id,
              policyId: policy.id,
              operationType: BackupOperationType.cleanup,
              status: status,
              message: message,
              triggeredManually: true,
              startedAt: DateTime.now().toUtc(),
              finishedAt: DateTime.now().toUtc(),
            ),
          );
      await journaled.markCommitted(ref);

      if (status == 'success') {
        await _refreshArtifactsForPolicy(
          project: project,
          server: server,
          engine: engine,
          policy: policy,
          destination: destination,
          expectedEpoch: operationEpoch,
        );
      }

      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      if (status == 'success') {
        final deletedCount = (response['deleted_count'] as num?)?.toInt() ?? 0;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              backupBacklogCleanupSuccessMessage(deletedCount: deletedCount),
            ),
          ),
        );
        return;
      }
      await _showWorkspaceActionErrorDialog(
        title: 'Clean up old backups failed',
        message: message ?? 'Clean up old backups failed.',
      );
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Clean up old backups failed',
        message: 'Could not clean up old backups: $error',
      );
    }
  }

  Future<void> _restoreArtifact({
    required Project project,
    required Server server,
    required BackupPolicyRecord policy,
    required BackupDestinationRecord destination,
    required BackupArtifactRecord artifact,
  }) async {
    final operationEpoch = workspaceBindEpoch;
    final engine = _selectedEngine;
    final draft = await _showRestoreDialog(artifact: artifact);
    if (draft == null) {
      return;
    }
    if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });
    if (!_validateDestinationForActiveEngine(
      destination: destination,
      actionLabel: 'Restore backup',
      engine: engine,
    )) {
      return;
    }
    final restoreStartedAt = DateTime.now();
    try {
      final logicalDatabaseName = logicalManagedPostgresName(
        projectName: project.name,
        remoteName: policy.databaseName,
      );
      final journaled = await _runJournaledBackupWorkflow(
        project: project,
        server: server,
        engine: engine,
        operationId: 'restore_run_now',
        extraSettings: <String, dynamic>{
          ..._destinationSettings(destination, engine),
          'backup_policy_id': policy.id,
          'backup_policy_name': policy.name,
          'backup_database_name': logicalDatabaseName,
          'backup_artifact_path': artifact.remotePath,
          'backup_target_database_name': draft.targetDatabaseName,
        },
        journalRequest: <String, dynamic>{
          'workflow_id': _activeWorkflowId(engine),
          'operation_id': 'restore_run_now',
          'engine': policy.engine.name,
          'policy_id': policy.id,
          'artifact_id': artifact.id,
          'target_database_name': draft.targetDatabaseName,
        },
        onEvent: _appendBackupLogEvent,
      );
      final response = journaled.response;
      final status = response['status']?.toString() ?? 'error';
      final message = status == 'success'
          ? response['msg']?.toString()
          : _responseMessageWithDetails(response, fallback: 'Restore failed.');
      _appendBackupResultLog(prefix: 'Restore backup', response: response);
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }

      // One report per invocation: the outcome is known and the scope is
      // current; the dialogs below only present it.
      ref
          .read(appAnalyticsServiceProvider)
          .trackRestoreEvent(
            outcome: status == 'success'
                ? DataOperationOutcome.success
                : DataOperationOutcome.failure,
            durationSeconds: DateTime.now()
                .difference(restoreStartedAt)
                .inSeconds,
          );

      await ref
          .read(projectBackupProvider.notifier)
          .appendRun(
            BackupRunRecord(
              engine: policy.engine,
              projectId: project.id,
              serverId: server.id,
              policyId: policy.id,
              operationType: BackupOperationType.restore,
              status: status,
              message: message,
              triggeredManually: true,
              artifactId: artifact.id,
              startedAt: DateTime.now().toUtc(),
              finishedAt: DateTime.now().toUtc(),
            ),
          );

      if (status == 'success') {
        await ref
            .read(projectManagedDatabaseRepositoryProvider)
            .applyOperationResult(
              projectId: project.id,
              serverId: server.id,
              engine: engine.name,
              operationType: 'restore_run_now',
              result: response,
            );
        await _loadProjectDatabases(
          project: project,
          server: server,
          engine: engine,
          expectedEpoch: operationEpoch,
        );
      }
      await journaled.markCommitted(ref);

      if (!mounted ||
          !isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      if (status == 'success') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Restore completed.')));
        return;
      }
      await _showWorkspaceActionErrorDialog(
        title: 'Restore backup failed',
        message: message ?? 'Restore failed.',
      );
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isSaving = false;
        _error = null;
      });
      await _showWorkspaceActionErrorDialog(
        title: 'Restore backup failed',
        message: 'Could not restore backup: $error',
      );
      ref
          .read(appAnalyticsServiceProvider)
          .trackRestoreEvent(
            outcome: DataOperationOutcome.failure,
            durationSeconds: DateTime.now()
                .difference(restoreStartedAt)
                .inSeconds,
          );
    }
  }

  BackupDestinationRecord? _currentDestinationForScope({
    required Project project,
    required Server server,
    required String destinationId,
  }) {
    final scope = ref
        .read(projectBackupProvider)
        .scopeFor(projectId: project.id, serverId: server.id);
    for (final destination in scope.destinations) {
      if (destination.id == destinationId) {
        return destination;
      }
    }
    return null;
  }
}

/// Maps the backup policy engine to its analytics vocabulary.
///
/// Exhaustive with no default: adding a backup engine value fails
/// compilation here until its backup-event hook is decided.
BackupKind _analyticsBackupKindFor(BackupEngine engine) {
  switch (engine) {
    case BackupEngine.postgres:
      return BackupKind.postgres;
  }
}
