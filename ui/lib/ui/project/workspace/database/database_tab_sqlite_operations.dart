part of '../../project_workspace.dart';

extension _DatabaseTabSqliteOperations on _DatabaseTabViewState {
  Future<Map<String, dynamic>> _runSqliteOperation({
    required Server server,
    required Project project,
    required ProjectSqliteDatabase sqliteDatabase,
    required String operationId,
  }) async {
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Selected server credentials are incomplete.',
      };
    }

    return (await ref
            .read(sshServiceProvider)
            .runWorkflow(
              workflowId: 'app',
              operationId: operationId,
              connection: connection,
              params: <String, dynamic>{
                'dry_run': false,
                'settings': _buildSqliteOperationSettings(
                  project: project,
                  sqliteDatabase: sqliteDatabase,
                ),
              },
            ))
        .diagnosticPayload;
  }

  DateTime? _parseSqliteCheckedAt(dynamic value) {
    if (value == null) {
      return null;
    }
    final text = value.toString().trim();
    if (text.isEmpty) {
      return null;
    }
    return DateTime.tryParse(text);
  }

  int? _parseSqliteSizeBytes(dynamic value) {
    if (value is int) {
      return value >= 0 ? value : null;
    }
    if (value == null) {
      return null;
    }
    final parsed = int.tryParse(value.toString().trim());
    if (parsed == null || parsed < 0) {
      return null;
    }
    return parsed;
  }

  int? _nullableInt(Object? value) {
    if (value is int) {
      return value;
    }
    return int.tryParse(value?.toString().trim() ?? '');
  }

  String _normalizeSqliteUiMessage(String message) {
    return message
        .replaceAll('Docker volume', 'storage')
        .replaceAll('Docker Volume', 'Storage')
        .replaceAll('SQLite volume', 'SQLite storage')
        .replaceAll('sqlite volume', 'sqlite storage')
        .replaceAll('volume', 'storage')
        .replaceAll('Volume', 'Storage');
  }

  Future<void> _syncSqliteMetadataFromPayload({
    required String projectId,
    required String sqliteDatabaseId,
    required Map<dynamic, dynamic> payload,
  }) async {
    await ref
        .read(projectSqliteDatabasesProvider.notifier)
        .updateRuntimeMetadata(
          projectId: projectId,
          sqliteDatabaseId: sqliteDatabaseId,
          volumeExists: payload['volume_exists'] is bool
              ? payload['volume_exists'] as bool
              : null,
          volumeMountpoint: payload['volume_mountpoint']?.toString(),
          volumeSizeBytes: _parseSqliteSizeBytes(payload['volume_size_bytes']),
          checkedAt: _parseSqliteCheckedAt(payload['checked_at']),
        );
  }

  Future<void> _ensureSqliteVolume({
    required Server server,
    required Project project,
    required ProjectSqliteDatabase sqliteDatabase,
  }) async {
    final expectedProjectId = project.id;
    final expectedServerId = server.id;
    _applyState(() {
      _sqliteBusyAction = 'ensure';
      _sqliteBusyDatabaseId = sqliteDatabase.id;
      _sqliteError = null;
    });
    try {
      final response = await _runSqliteOperation(
        server: server,
        project: project,
        sqliteDatabase: sqliteDatabase,
        operationId: 'sqlite_volume_ensure',
      );
      if (!mounted) {
        return;
      }
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
          )) {
        return;
      }
      if (response['status'] != 'success') {
        final responseMessage = response['msg']?.toString().trim();
        _applyState(() {
          _sqliteError = (responseMessage != null && responseMessage.isNotEmpty)
              ? _normalizeSqliteUiMessage(responseMessage)
              : 'Could not prepare SQLite storage.';
          _sqliteBusyAction = null;
          _sqliteBusyDatabaseId = null;
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackDatabaseEvent(
              engine: DatabaseEngine.sqlite,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      final payload = response['sqlite_storage'];
      if (payload is Map) {
        await _syncSqliteMetadataFromPayload(
          projectId: project.id,
          sqliteDatabaseId: sqliteDatabase.id,
          payload: payload,
        );
      }

      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('SQLite storage is ready.')));
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: DatabaseEngine.sqlite,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteError = 'Could not prepare SQLite storage: $error';
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: DatabaseEngine.sqlite,
            outcome: DataOperationOutcome.failure,
          );
    }
  }

  Future<void> _refreshSqliteVolumeStatus({
    required Server server,
    required Project project,
    required ProjectSqliteDatabase sqliteDatabase,
  }) async {
    _applyState(() {
      _sqliteBusyAction = 'status';
      _sqliteBusyDatabaseId = sqliteDatabase.id;
      _sqliteError = null;
    });
    try {
      final response = await _runSqliteOperation(
        server: server,
        project: project,
        sqliteDatabase: sqliteDatabase,
        operationId: 'sqlite_volume_status',
      );
      if (response['status'] != 'success') {
        final responseMessage = response['msg']?.toString().trim();
        _applyState(() {
          _sqliteError = (responseMessage != null && responseMessage.isNotEmpty)
              ? _normalizeSqliteUiMessage(responseMessage)
              : 'Could not refresh SQLite storage status.';
          _sqliteBusyAction = null;
          _sqliteBusyDatabaseId = null;
        });
        return;
      }
      final payload = response['sqlite_storage'];
      if (payload is Map) {
        await _syncSqliteMetadataFromPayload(
          projectId: project.id,
          sqliteDatabaseId: sqliteDatabase.id,
          payload: payload,
        );
      }
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteError = 'Could not refresh SQLite status: $error';
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
    }
  }

  Future<void> _setPrimarySqliteDatabase({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    _applyState(() {
      _sqliteBusyAction = 'set_primary';
      _sqliteBusyDatabaseId = sqliteDatabaseId;
      _sqliteError = null;
    });
    try {
      await ref
          .read(projectSqliteDatabasesProvider.notifier)
          .setPrimary(projectId: projectId, sqliteDatabaseId: sqliteDatabaseId);
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteError = 'Could not set primary SQLite database: $error';
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
    }
  }

  Future<void> _deleteSqliteDatabase({
    required Server server,
    required Project project,
    required ProjectSqliteDatabase sqliteDatabase,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AppDestructiveConfirmDialog(
          title: 'Delete SQLite database',
          description:
              'Delete SQLite config "${sqliteDatabase.name}" and remove its '
              'storage?',
        );
      },
    );
    if (confirmed != true) {
      return;
    }

    _applyState(() {
      _sqliteBusyAction = 'delete';
      _sqliteBusyDatabaseId = sqliteDatabase.id;
      _sqliteError = null;
    });
    try {
      final response = await _runSqliteOperation(
        server: server,
        project: project,
        sqliteDatabase: sqliteDatabase,
        operationId: 'sqlite_volume_delete',
      );
      if (!mounted) {
        return;
      }
      if (response['status'] != 'success') {
        final responseMessage = response['msg']?.toString().trim();
        _applyState(() {
          _sqliteError = (responseMessage != null && responseMessage.isNotEmpty)
              ? _normalizeSqliteUiMessage(responseMessage)
              : 'Could not delete SQLite storage.';
          _sqliteBusyAction = null;
          _sqliteBusyDatabaseId = null;
        });
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackDatabaseEvent(
              engine: DatabaseEngine.sqlite,
              outcome: DataOperationOutcome.failure,
            );
        return;
      }

      await ref
          .read(projectSqliteDatabasesProvider.notifier)
          .delete(projectId: project.id, sqliteDatabaseId: sqliteDatabase.id);
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('SQLite database deleted.')));
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: DatabaseEngine.sqlite,
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _sqliteError = 'Could not delete SQLite database: $error';
        _sqliteBusyAction = null;
        _sqliteBusyDatabaseId = null;
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: DatabaseEngine.sqlite,
            outcome: DataOperationOutcome.failure,
          );
    }
  }
}
