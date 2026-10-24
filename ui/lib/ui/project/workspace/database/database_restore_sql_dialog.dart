part of '../../project_workspace.dart';

extension _DatabaseRestoreSqlDialog on _DatabaseTabViewState {
  // coverage-gate: restore_local_postgres_sql
  Future<void> _restoreLocalPostgresSql({
    required Server server,
    required Project project,
    required String databaseName,
  }) async {
    final picker =
        widget.pickPostgresRestoreSqlFile ??
        _debugPostgresRestoreSqlFilePicker ??
        _pickPostgresRestoreSqlFile;
    final selectedPath = await picker();
    if (!mounted || selectedPath == null || selectedPath.trim().isEmpty) {
      return;
    }

    final filePath = selectedPath.trim();
    final fileName = File(filePath).uri.pathSegments.isEmpty
        ? filePath
        : File(filePath).uri.pathSegments.last;
    var ignoreOwnership = false;
    // D-43 (T-013): genuine bool confirm, not a notice — excluded like
    // _rollbackToRelease's.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AppConfirmDialog(
              title: 'Restore local SQL file',
              description:
                  'Restore this database dump into "$databaseName"? Deploy Dash '
                  'uploads the selected .sql or custom-format .dump file from '
                  'this workstation and imports it into the selected PostgreSQL '
                  'database. The import runs as one transaction: if anything '
                  'fails, the database is left unchanged and you can safely retry.',
              confirmLabel: 'Restore',
              onConfirm: () {},
              body: SizedBox(
                width: 460,
                child: AppFormSection(
                  children: [
                    _LabeledValueRow(label: 'Database', value: databaseName),
                    _LabeledValueRow(label: 'File', value: fileName),
                    _LabeledValueRow(label: 'Path', value: filePath),
                    AppCheckboxField(
                      key: const Key('database-restore-ignore-ownership-field'),
                      value: ignoreOwnership,
                      title: 'Ignore ownership and permission statements',
                      subtitle:
                          'For plain .sql dumps: drop OWNER, GRANT and REVOKE '
                          'lines instead of failing on unknown roles. '
                          'Custom-format dumps always ignore them.',
                      onChanged: (value) =>
                          setDialogState(() => ignoreOwnership = value == true),
                    ),
                    Text(
                      'Create the target database first if needed. This import '
                      'does not create a database for you.',
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    final feedback = ref.read(projectDatabaseActionFeedbackProvider.notifier);
    final journalRepository = ref.read(appReleaseRepositoryProvider);
    ProjectManagedOperationJournalRecord? journal;
    _applyState(() {
      _busyAction = 'restore_local_sql';
      _busyUsername = null;
      _error = null;
      _errorDetails = null;
      _errorTitle = null;
    });
    feedback.clear(projectId: project.id, serverId: server.id);
    final restoreStartedAt = DateTime.now();
    try {
      // Never retain the workstation file path in the local operation journal.
      final logicalDatabaseName = logicalManagedPostgresName(
        projectName: project.name,
        remoteName: databaseName,
      );
      journal = await journalRepository.createJournalEntry(
        projectId: project.id,
        serverId: server.id,
        surface: 'database',
        operationType: 'import_local_sql',
        request: <String, dynamic>{'database_name': logicalDatabaseName},
      );
      final response = await _runDatabaseWorkflow(
        engine: _ProjectDatabaseEngine.postgres,
        server: server,
        project: project,
        operationId: 'import_local_sql',
        settingsOverrides: <String, dynamic>{
          'database_name': logicalDatabaseName,
          'import_local_file_path': filePath,
          'import_ignore_ownership': ignoreOwnership,
        },
      );
      if (response['status'] != 'success') {
        final message =
            response['msg']?.toString().trim() ?? 'Could not restore SQL file.';
        await journalRepository.updateJournalStatus(
          id: journal.id,
          status: 'failed',
          result: <String, dynamic>{
            if (response['status'] != null) 'status': response['status'],
            if (response['code'] != null) 'code': response['code'],
            if (response['msg'] != null) 'msg': response['msg'],
          },
          errorMessage: message,
        );
        feedback.showFailure(
          projectId: project.id,
          serverId: server.id,
          message: message,
          details: response['details']?.toString(),
          title: 'SQL restore failed',
        );
        if (!mounted) {
          return;
        }
        _applyState(() {
          _busyAction = null;
          _busyUsername = null;
          _setDatabaseErrorState(
            message: message,
            details: response['details']?.toString(),
            title: 'SQL restore failed',
          );
        });
        _showDatabaseErrorAtTop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackRestoreEvent(
              outcome: DataOperationOutcome.failure,
              durationSeconds: DateTime.now()
                  .difference(restoreStartedAt)
                  .inSeconds,
            );
        return;
      }

      await journalRepository.updateJournalStatus(
        id: journal.id,
        status: 'committed_local',
        result: <String, dynamic>{
          if (response['status'] != null) 'status': response['status'],
          if (response['code'] != null) 'code': response['code'],
          if (response['msg'] != null) 'msg': response['msg'],
          if (response['target_database_name'] != null)
            'target_database_name': response['target_database_name'],
          if (response['imported_size_bytes'] != null)
            'imported_size_bytes': response['imported_size_bytes'],
        },
      );
      if (!mounted) {
        return;
      }

      final targetDatabaseName = response['target_database_name']
          ?.toString()
          .trim();
      if (targetDatabaseName != null && targetDatabaseName.isNotEmpty) {
        _applyState(() {
          _selectedDatabase = targetDatabaseName;
        });
      }
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
      });
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'SQL file restored into "${targetDatabaseName ?? databaseName}".',
          ),
        ),
      );
      ref
          .read(appAnalyticsServiceProvider)
          .trackRestoreEvent(
            outcome: DataOperationOutcome.success,
            durationSeconds: DateTime.now()
                .difference(restoreStartedAt)
                .inSeconds,
          );
    } catch (error) {
      if (journal != null) {
        await journalRepository.updateJournalStatus(
          id: journal.id,
          status: 'failed',
          errorMessage: error.toString(),
        );
      }
      feedback.showFailure(
        projectId: project.id,
        serverId: server.id,
        message: 'Could not restore SQL file: $error',
        title: 'SQL restore failed',
      );
      if (!mounted) {
        return;
      }
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
        _setDatabaseErrorState(
          message: 'Could not restore SQL file: $error',
          title: 'SQL restore failed',
        );
      });
      _showDatabaseErrorAtTop();
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

  // end coverage-gate
}
