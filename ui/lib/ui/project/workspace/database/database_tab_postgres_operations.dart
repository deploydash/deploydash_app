part of '../../project_workspace.dart';

extension _DatabaseTabPostgresOperations on _DatabaseTabViewState {
  // coverage-gate: detached_storage_expectations
  /// Returns the locally persisted database names that can reveal lost storage.
  ///
  /// The server registry travels with PostgreSQL data, so a detached cluster
  /// needs the desktop's last known project catalog to distinguish it from a
  /// genuinely fresh service. A local read failure keeps status best-effort.
  Future<List<String>> _expectedProjectDatabaseNames({
    required Project project,
    required Server server,
  }) async {
    try {
      final rows = await ref
          .read(projectManagedDatabaseRepositoryProvider)
          .listDatabasesForScope(
            projectId: project.id,
            serverId: server.id,
            engine: _ProjectDatabaseEngine.postgres.name,
          );
      final names = rows
          .map((row) => row.databaseName.trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList(growable: false);
      names.sort();
      return names;
    } on Object catch (error) {
      debugPrint('Project Postgres expectations read failed: $error');
      return const <String>[];
    }
  }
  // end coverage-gate

  Future<Map<String, dynamic>> _runDatabaseWorkflow({
    required _ProjectDatabaseEngine engine,
    required Server server,
    required Project project,
    required String operationId,
    Map<String, dynamic>? settingsOverrides,
    bool dryRun = false,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return const <String, dynamic>{
        'status': 'error',
        'msg': 'Selected server credentials are incomplete.',
      };
    }
    final settings = _buildSettingsForEngine(
      engine: engine,
      server: server,
      project: project,
      settingsOverrides: settingsOverrides,
    );
    return (await ref
            .read(sshServiceProvider)
            .runWorkflow(
              workflowId: _workflowIdForEngine(engine),
              operationId: operationId,
              connection: connection,
              params: <String, dynamic>{
                'dry_run': dryRun,
                'settings': settings,
              },
              onEvent: onEvent,
            ))
        .diagnosticPayload;
  }

  Future<void> _refreshProjectDatabases({
    required _ProjectDatabaseEngine engine,
    required Project project,
    required Server server,
    required int requestEpoch,
  }) async {
    if (!isCurrentWorkspaceIds(
      projectId: project.id,
      serverId: server.id,
      expectedEpoch: requestEpoch,
    )) {
      return;
    }
    final expectedProjectId = project.id;
    final expectedServerId = server.id;

    try {
      // coverage-gate: detached_storage_project_request
      final expectedDatabases = await _expectedProjectDatabaseNames(
        project: project,
        server: server,
      );
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
            expectedEpoch: requestEpoch,
          )) {
        return;
      }
      final response = await _runDatabaseWorkflow(
        engine: engine,
        server: server,
        project: project,
        operationId: 'project_list',
        settingsOverrides: <String, dynamic>{
          'expected_databases': expectedDatabases,
        },
      );
      // end coverage-gate
      if (!mounted) {
        return;
      }
      if (!isCurrentWorkspaceIds(
        projectId: expectedProjectId,
        serverId: expectedServerId,
        expectedEpoch: requestEpoch,
      )) {
        return;
      }
      if (response['status'] != 'success') {
        final message =
            response['msg']?.toString().trim() ?? 'Could not load databases.';
        final details = response['details']?.toString().trim();
        final serviceStatus = response['service_status'];
        var running = _serviceRunning;
        var configured = _serviceConfigured;
        var statusVerified = false;
        // coverage-gate: detached_storage_error_mapping
        var storageStatus = const PostgresStorageStatus();
        if (serviceStatus is Map) {
          final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(
            serviceStatus,
          );
          running = runtimeStatus.isReady;
          configured = serviceStatus['configured'] == true;
          statusVerified = true;
          _serviceRuntimeStatus = runtimeStatus;
          storageStatus = PostgresStorageStatus.fromServiceStatus(
            serviceStatus,
          );
        }
        // end coverage-gate
        final rawPort = response['port'];
        _applyState(() {
          _isLoading = false;
          _serviceRunning = running;
          _serviceConfigured = configured;
          _serviceStatusVerified = statusVerified;
          // coverage-gate: detached_storage_error_state
          _serviceStorageStatus = storageStatus;
          // end coverage-gate
          _engineVersion = response['engine_version']?.toString().trim();
          _serviceHost = response['host']?.toString().trim();
          _servicePort = rawPort is int
              ? rawPort
              : int.tryParse(rawPort?.toString() ?? '');
          _setDatabaseErrorState(message: message, details: details);
        });
        return;
      }

      final serviceStatus = response['service_status'];
      var running = false;
      var configured = false;
      var statusVerified = false;
      // coverage-gate: detached_storage_success_mapping
      var storageStatus = const PostgresStorageStatus();
      if (serviceStatus is Map) {
        final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(
          serviceStatus,
        );
        running = runtimeStatus.isReady;
        configured = serviceStatus['configured'] == true;
        statusVerified = true;
        _serviceRuntimeStatus = runtimeStatus;
        storageStatus = PostgresStorageStatus.fromServiceStatus(serviceStatus);
      }
      // end coverage-gate

      final databasesPayload = response['databases'];
      final usersPayload = response['users'];
      final responseHost =
          response['host']?.toString() ?? response['database_host']?.toString();
      final responsePort = _nullableInt(
        response['port'] ?? response['database_port'],
      );
      final databases = <String>[];
      final seenDatabases = <String>{};
      final users = <_ProjectDatabaseUserRecord>[];

      if (databasesPayload is List) {
        for (final entry in databasesPayload) {
          final value = entry?.toString().trim() ?? '';
          if (value.isEmpty) {
            continue;
          }
          if (!seenDatabases.add(value)) {
            continue;
          }
          databases.add(value);
        }
      }
      if (usersPayload is List) {
        for (final entry in usersPayload) {
          if (entry is! Map) {
            continue;
          }
          final username = entry['username']?.toString().trim() ?? '';
          if (username.isEmpty) {
            continue;
          }
          final accessMode =
              entry['access_mode']?.toString().trim().toLowerCase() ??
              'read_write';
          final database = entry['database']?.toString().trim();
          users.add(
            _ProjectDatabaseUserRecord(
              username: username,
              accessMode: accessMode == 'read_only'
                  ? 'read_only'
                  : 'read_write',
              database: (database == null || database.isEmpty)
                  ? null
                  : database,
              host:
                  entry['host']?.toString() ??
                  entry['database_host']?.toString() ??
                  responseHost,
              port:
                  _nullableInt(entry['port'] ?? entry['database_port']) ??
                  responsePort,
            ),
          );
        }
      }
      final databaseRecords = <ProjectManagedDatabaseRecord>[];
      final userRecords = <ProjectManagedDatabaseUserRecord>[];
      final observedAt = DateTime.now();
      for (final database in databases) {
        final record = ProjectManagedDatabaseRepository.fromBackendDatabase(
          projectId: project.id,
          serverId: server.id,
          engine: engine.name,
          databaseName: database,
          observedAt: observedAt,
        );
        if (record != null) {
          databaseRecords.add(record);
        }
      }
      for (final user in users) {
        final database = user.database?.trim();
        if (database == null || database.isEmpty) {
          continue;
        }
        final record = ProjectManagedDatabaseRepository.fromBackendUser(
          projectId: project.id,
          serverId: server.id,
          engine: engine.name,
          databaseName: database,
          username: user.username,
          accessMode: user.accessMode,
          host: user.host,
          port: user.port,
          observedAt: observedAt,
        );
        if (record != null) {
          userRecords.add(record);
        }
      }
      await ref
          .read(projectManagedDatabaseProvider.notifier)
          .replaceScope(
            projectId: project.id,
            serverId: server.id,
            databases: databaseRecords,
            users: userRecords,
          );
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
            expectedEpoch: requestEpoch,
          )) {
        return;
      }
      final nextSelectedDatabase = _resolveSelectedDatabase(
        availableDatabases: databases,
        preferredDatabase: _selectedDatabase,
      );
      final nextSelectedUsername = _resolveSelectedUsername(
        users: users,
        selectedDatabase: nextSelectedDatabase,
        preferredUsername: _selectedUsername,
      );

      _applyState(() {
        _serviceRunning = running;
        _serviceConfigured = configured;
        _serviceStatusVerified = statusVerified;
        // coverage-gate: detached_storage_success_state
        _serviceStorageStatus = storageStatus;
        // end coverage-gate
        _engineVersion = response['engine_version']?.toString().trim();
        _serviceHost = response['host']?.toString().trim();
        final rawPort = response['port'];
        _servicePort = rawPort is int
            ? rawPort
            : int.tryParse(rawPort?.toString() ?? '');
        _selectedDatabase = nextSelectedDatabase;
        _selectedUsername = nextSelectedUsername;
        _databases = databases;
        _users = users;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (!isCurrentWorkspaceIds(
        projectId: expectedProjectId,
        serverId: expectedServerId,
        expectedEpoch: requestEpoch,
      )) {
        return;
      }
      _applyState(() {
        _isLoading = false;
        _serviceRunning = false;
        _serviceConfigured = server.serviceDatabaseEnabled;
        _serviceStatusVerified = false;
        _serviceRuntimeStatus = server.serviceDatabaseEnabled
            ? const ContainerRuntimeStatus.unknown()
            : const ContainerRuntimeStatus.notConfigured();
        // coverage-gate: detached_storage_failure_reset
        _serviceStorageStatus = const PostgresStorageStatus();
        // end coverage-gate
        _engineVersion = null;
        _serviceHost = null;
        _servicePort = null;
        _setDatabaseErrorState(
          message: 'Could not load project databases: $error',
        );
      });
    }
  }

  void _selectDatabase({required String? value}) {
    _applyState(() {
      _selectedDatabase = value;
      final selectedUsername = _resolveSelectedUsername(
        users: _users,
        selectedDatabase: value,
        preferredUsername: _selectedUsername,
      );
      final selectedUser = _userForSelection(
        users: _users,
        selectedDatabase: value,
        selectedUsername: selectedUsername,
      );
      _selectedUsername = selectedUsername;
      _serviceHost = selectedUser?.host;
      _servicePort = selectedUser?.port;
    });
  }

  // coverage-gate: database_mutation
  Future<void> _runDatabaseMutation({
    required _ProjectDatabaseEngine engine,
    required Server server,
    required Project project,
    required String operationId,
    required String busyAction,
    required Map<String, dynamic> settingsOverrides,
    required String defaultSuccessMessage,
    String? busyUsername,
    bool showCredentials = false,
    Future<void> Function(Map<String, dynamic> response)? onSuccess,
  }) async {
    final expectedProjectId = project.id;
    final expectedServerId = server.id;
    final feedback = ref.read(projectDatabaseActionFeedbackProvider.notifier);
    final journalRepository = ref.read(appReleaseRepositoryProvider);
    ProjectManagedOperationJournalRecord? journal;
    var remoteSucceeded = false;
    _applyState(() {
      _busyAction = busyAction;
      _busyUsername = busyUsername;
      _error = null;
      _errorDetails = null;
      _errorTitle = null;
    });
    feedback.clear(projectId: expectedProjectId, serverId: expectedServerId);
    try {
      journal = await journalRepository.createJournalEntry(
        projectId: project.id,
        serverId: server.id,
        surface: 'database',
        operationType: operationId,
        request: settingsOverrides,
      );
      final response = await _runDatabaseWorkflow(
        engine: engine,
        server: server,
        project: project,
        operationId: operationId,
        settingsOverrides: settingsOverrides,
      );
      if (response['status'] != 'success') {
        final message =
            response['msg']?.toString().trim() ?? 'Database action failed.';
        await journalRepository.updateJournalStatus(
          id: journal.id,
          status: 'failed',
          result: response,
          errorMessage: message,
        );
        feedback.showFailure(
          projectId: expectedProjectId,
          serverId: expectedServerId,
          message: message,
          details: response['details']?.toString(),
        );
        if (!mounted ||
            !isCurrentWorkspaceIds(
              projectId: expectedProjectId,
              serverId: expectedServerId,
            )) {
          return;
        }
        _applyState(() {
          _busyAction = null;
          _busyUsername = null;
          _setDatabaseErrorState(
            message: message,
            details: response['details']?.toString(),
          );
        });
        _showDatabaseErrorAtTop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
        // One report per invocation: this branch returns.
        ref
            .read(appAnalyticsServiceProvider)
            .trackDatabaseEvent(
              engine: _analyticsEngineForDatabase(engine),
              outcome: DataOperationOutcome.failure,
            );
        return;
      }
      final responseConnectionUri = _webAppConnectionUriForEngine(
        engine: engine,
        connectionUri: response['connection_uri']?.toString(),
      );
      final parsedConnection = _parseConnectionUriCredentials(
        responseConnectionUri,
      );
      final responsePassword =
          response['password']?.toString().trim() ?? parsedConnection.password;
      final responseUsername =
          response['username']?.toString().trim() ?? parsedConnection.username;
      final responseDatabase =
          response['database_name']?.toString().trim() ??
          parsedConnection.databaseName;
      final resolvedUsername =
          responseUsername ?? settingsOverrides['username']?.toString().trim();
      final resolvedDatabase =
          responseDatabase ??
          settingsOverrides['database_name']?.toString().trim();
      final journalReplayResult = _databaseJournalReplayResult(
        response: response,
        settingsOverrides: settingsOverrides,
        connectionUri: responseConnectionUri,
        password: responsePassword,
        username: resolvedUsername,
        databaseName: resolvedDatabase,
      );
      await journalRepository.updateJournalStatus(
        id: journal.id,
        status: 'remote_success',
        result: journalReplayResult,
        sanitizeResult: false,
      );
      remoteSucceeded = true;
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
          )) {
        return;
      }
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
      });
      final message = response['msg']?.toString().trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            (message == null || message.isEmpty)
                ? defaultSuccessMessage
                : message,
          ),
        ),
      );
      if (responsePassword != null &&
          responsePassword.isNotEmpty &&
          resolvedUsername != null &&
          resolvedUsername.isNotEmpty) {
        _storeKnownPassword(
          engine: engine,
          projectId: expectedProjectId,
          serverId: expectedServerId,
          username: resolvedUsername,
          databaseName: resolvedDatabase,
          password: responsePassword,
        );
      }
      if (resolvedDatabase != null &&
          resolvedDatabase.isNotEmpty &&
          resolvedUsername != null &&
          resolvedUsername.isNotEmpty) {
        _applyState(() {
          _selectedDatabase = resolvedDatabase;
          _selectedUsername = resolvedUsername;
        });
      }
      if (showCredentials) {
        await _showCredentialsDialog(
          title: 'Database credentials',
          message: engine == _ProjectDatabaseEngine.postgres
              ? 'Deploy Dash saved these PostgreSQL credentials locally for '
                    'this project.'
              : 'Save these details now. The generated password is shown once.',
          password: responsePassword,
          connectionUri: responseConnectionUri,
        );
      }
      await _applyDatabaseMutationToLocalCatalog(
        engine: engine,
        server: server,
        project: project,
        operationId: operationId,
        settingsOverrides: settingsOverrides,
        response: response,
      );
      await journalRepository.updateJournalStatus(
        id: journal.id,
        status: 'committed_local',
        result: _databaseJournalCompletionResult(response),
      );
      await onSuccess?.call(response);
      // The mutation fully resolved: remote success plus local catalog.
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: _analyticsEngineForDatabase(engine),
            outcome: DataOperationOutcome.success,
          );
    } catch (error) {
      if (journal != null && !remoteSucceeded) {
        await journalRepository.updateJournalStatus(
          id: journal.id,
          status: 'failed',
          errorMessage: error.toString(),
        );
      }
      feedback.showFailure(
        projectId: expectedProjectId,
        serverId: expectedServerId,
        message: 'Database action failed: $error',
      );
      if (!mounted) {
        return;
      }
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
        _setDatabaseErrorState(message: 'Database action failed: $error');
      });
      _showDatabaseErrorAtTop();
      ref
          .read(appAnalyticsServiceProvider)
          .trackDatabaseEvent(
            engine: _analyticsEngineForDatabase(engine),
            outcome: DataOperationOutcome.failure,
          );
    }
  }

  // end coverage-gate
  Map<String, dynamic> _databaseJournalReplayResult({
    required Map<String, dynamic> response,
    required Map<String, dynamic> settingsOverrides,
    required String? connectionUri,
    required String? password,
    required String? username,
    required String? databaseName,
  }) {
    return <String, dynamic>{
      if (response['status'] != null) 'status': response['status'],
      if (response['msg'] != null) 'msg': response['msg'],
      if (databaseName != null && databaseName.isNotEmpty)
        'database_name': databaseName,
      if (response['deleted_database_name'] != null)
        'deleted_database_name': response['deleted_database_name'],
      if (username != null && username.isNotEmpty) 'username': username,
      if (response['deleted_username'] != null)
        'deleted_username': response['deleted_username'],
      if (settingsOverrides['access_mode'] != null)
        'access_mode': settingsOverrides['access_mode'],
      if (connectionUri != null && connectionUri.isNotEmpty)
        'connection_uri': connectionUri,
      if (password != null && password.isNotEmpty) 'password': password,
      if (response['host'] != null) 'host': response['host'],
      if (response['port'] != null) 'port': response['port'],
    };
  }

  Map<String, dynamic> _databaseJournalCompletionResult(
    Map<String, dynamic> response,
  ) {
    return <String, dynamic>{
      if (response['status'] != null) 'status': response['status'],
      if (response['msg'] != null) 'msg': response['msg'],
    };
  }

  Future<void> _applyDatabaseMutationToLocalCatalog({
    required _ProjectDatabaseEngine engine,
    required Server server,
    required Project project,
    required String operationId,
    required Map<String, dynamic> settingsOverrides,
    required Map<String, dynamic> response,
  }) async {
    await ref
        .read(projectManagedDatabaseRepositoryProvider)
        .applyOperationResult(
          projectId: project.id,
          serverId: server.id,
          engine: engine.name,
          operationType: operationId,
          request: settingsOverrides,
          result: response,
        );
    await ref
        .read(projectManagedDatabaseProvider.notifier)
        .loadScope(projectId: project.id, serverId: server.id);
    await _loadLocalManagedDatabases(
      engine: engine,
      project: project,
      server: server,
      requestEpoch: workspaceBindEpoch,
    );
  }

  Future<void> _refreshFromUi({
    required _ProjectDatabaseEngine engine,
    required Server server,
    required Project project,
  }) async {
    final feedback = ref.read(projectDatabaseActionFeedbackProvider.notifier);
    _applyState(() {
      _busyAction = 'refresh';
      _busyUsername = null;
      _error = null;
      _errorDetails = null;
      _errorTitle = null;
    });
    feedback.clear(projectId: project.id, serverId: server.id);
    final requestEpoch = advanceWorkspaceEpoch();
    try {
      await _refreshProjectDatabases(
        engine: engine,
        project: project,
        server: server,
        requestEpoch: requestEpoch,
      );
    } finally {
      if (mounted) {
        _applyState(() {
          if (_busyAction == 'refresh') {
            _busyAction = null;
            _busyUsername = null;
          }
        });
      }
    }
  }

  Future<void> _rotateUserPassword({
    required Server server,
    required Project project,
    required _ProjectDatabaseUserRecord user,
  }) async {
    await _runDatabaseMutation(
      engine: _selectedEngine,
      server: server,
      project: project,
      operationId: 'project_rotate_password',
      busyAction: 'rotate_password',
      busyUsername: user.username,
      settingsOverrides: <String, dynamic>{
        'username': logicalManagedPostgresName(
          projectName: project.name,
          remoteName: user.username,
        ),
        if (user.database != null)
          'database_name': logicalManagedPostgresName(
            projectName: project.name,
            remoteName: user.database!,
          ),
      },
      defaultSuccessMessage: 'Password reset.',
      showCredentials: true,
    );
  }

  Future<void> _removeUser({
    required Server server,
    required Project project,
    required _ProjectDatabaseUserRecord user,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AppDestructiveConfirmDialog(
          title: 'Delete user',
          description:
              'Delete database user "${user.username}"? This removes the '
              'login and its access to this project\'s databases.',
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _runDatabaseMutation(
      engine: _selectedEngine,
      server: server,
      project: project,
      operationId: 'project_delete_user',
      busyAction: 'remove_user',
      busyUsername: user.username,
      settingsOverrides: <String, dynamic>{
        'username': logicalManagedPostgresName(
          projectName: project.name,
          remoteName: user.username,
        ),
        if (user.database != null)
          'database_name': logicalManagedPostgresName(
            projectName: project.name,
            remoteName: user.database!,
          ),
      },
      defaultSuccessMessage: 'Database user deleted.',
      showCredentials: false,
    );
  }

  Future<void> _deleteSelectedDatabase({
    required Server server,
    required Project project,
    required String databaseName,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AppDestructiveConfirmDialog(
          title: 'Delete database',
          description:
              'Delete PostgreSQL database "$databaseName" and '
              'remove its managed users?',
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    await _runDatabaseMutation(
      engine: _selectedEngine,
      server: server,
      project: project,
      operationId: 'project_delete_database',
      busyAction: 'delete_database',
      settingsOverrides: <String, dynamic>{
        'database_name': logicalManagedPostgresName(
          projectName: project.name,
          remoteName: databaseName,
        ),
      },
      defaultSuccessMessage: 'Database "$databaseName" deleted.',
      showCredentials: false,
      onSuccess: (_) async {
        await ref
            .read(projectDatabaseAccessRepositoryProvider)
            .deleteUsersForOwnerDatabase(
              serverId: server.id,
              ownerProjectId: project.id,
              engine: 'postgres',
              databaseName: databaseName,
            );
        await _refreshLinkedProjects(project: project, server: server);
      },
    );
  }

  // coverage-gate: normalize_database_isolation
  Future<void> _normalizeSelectedDatabase({
    required Server server,
    required Project project,
    required String databaseName,
  }) async {
    final logicalDatabaseName = logicalManagedPostgresName(
      projectName: project.name,
      remoteName: databaseName,
    );
    final feedback = ref.read(projectDatabaseActionFeedbackProvider.notifier);
    _applyState(() {
      _busyAction = 'normalize_database';
      _busyUsername = null;
      _error = null;
      _errorDetails = null;
      _errorTitle = null;
    });
    feedback.clear(projectId: project.id, serverId: server.id);
    final plan = await _runDatabaseWorkflow(
      engine: _selectedEngine,
      server: server,
      project: project,
      operationId: 'project_normalize_database',
      settingsOverrides: <String, dynamic>{
        'database_name': logicalDatabaseName,
      },
      dryRun: true,
    );
    if (!mounted) {
      return;
    }
    if (plan['status'] != 'success') {
      final message =
          plan['msg']?.toString().trim() ??
          'Could not load the normalization plan.';
      final details = plan['details']?.toString().trim();
      feedback.showFailure(
        projectId: project.id,
        serverId: server.id,
        message: message,
        details: details,
      );
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
        _setDatabaseErrorState(message: message, details: details);
      });
      _showDatabaseErrorAtTop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      return;
    }
    final users = <String>[
      ..._normalizePlanNames(plan['read_write_users']),
      ..._normalizePlanNames(plan['read_only_users']),
    ];
    final losing = _normalizePlanNames(plan['roles_losing_connect']);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AppDestructiveConfirmDialog(
          title: 'Normalize database isolation',
          description:
              'Move "$databaseName" to its dedicated owner role and cut off '
              'roles that connect without an explicit grant. Project users '
              'keep their access.',
          confirmLabel: 'Normalize',
          confirmButtonKey: const Key('database-normalize-confirm-button'),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Users normalized (${users.length}):'),
              const SizedBox(height: 4),
              if (users.isEmpty)
                const Text('No users to normalize.')
              else
                for (final user in users) Text(user),
              const SizedBox(height: 12),
              Text('Roles that lose access (${losing.length}):'),
              const SizedBox(height: 4),
              if (losing.isEmpty)
                const Text('No roles lose access.')
              else
                for (final role in losing) Text(role),
            ],
          ),
        );
      },
    );
    if (confirmed != true) {
      _applyState(() {
        _busyAction = null;
        _busyUsername = null;
      });
      return;
    }
    await _runDatabaseMutation(
      engine: _selectedEngine,
      server: server,
      project: project,
      operationId: 'project_normalize_database',
      busyAction: 'normalize_database',
      settingsOverrides: <String, dynamic>{
        'database_name': logicalDatabaseName,
        'confirmed_normalize_users': users,
        'confirmed_lost_connect_roles': losing,
      },
      defaultSuccessMessage: 'Database "$databaseName" normalized.',
      showCredentials: false,
    );
  }

  /// Reads one name list from a normalize plan, tolerating a missing key.
  ///
  /// A plan that omits a list normalizes nothing for it rather than failing
  /// the whole report: the apply confirms exactly what was reviewed.
  List<String> _normalizePlanNames(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    return value
        .whereType<String>()
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList(growable: false);
  }

  // end coverage-gate
  void _storeKnownPassword({
    required _ProjectDatabaseEngine engine,
    required String projectId,
    required String serverId,
    required String username,
    required String password,
    String? databaseName,
  }) {
    final key = _credentialLookupKey(
      engine: engine,
      projectId: projectId,
      serverId: serverId,
      username: username,
      databaseName: databaseName,
    );
    _knownUserPasswords[key] = password;
  }

  String? _knownPasswordForSelection({
    required _ProjectDatabaseEngine engine,
    required String? projectId,
    required String? serverId,
    required String? username,
    required String? databaseName,
  }) {
    if (username == null || username.trim().isEmpty) {
      return null;
    }
    final scopedKey = _credentialLookupKey(
      engine: engine,
      projectId: projectId,
      serverId: serverId,
      username: username,
      databaseName: databaseName,
    );
    if (_knownUserPasswords.containsKey(scopedKey)) {
      return _knownUserPasswords[scopedKey];
    }
    final unscopedKey = _credentialLookupKey(
      engine: engine,
      projectId: projectId,
      serverId: serverId,
      username: username,
    );
    final unscopedPassword = _knownUserPasswords[unscopedKey];
    if (unscopedPassword != null) {
      return unscopedPassword;
    }
    return null;
  }
}

/// Maps the workspace database engine to its analytics vocabulary.
///
/// Exhaustive with no default: adding a workspace engine value fails
/// compilation here until its database-event hook is decided.
DatabaseEngine _analyticsEngineForDatabase(_ProjectDatabaseEngine engine) {
  switch (engine) {
    case _ProjectDatabaseEngine.postgres:
      return DatabaseEngine.postgres;
  }
}
