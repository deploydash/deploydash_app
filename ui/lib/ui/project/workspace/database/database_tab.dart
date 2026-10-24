part of '../../project_workspace.dart';

class _DatabaseTabView extends ConsumerStatefulWidget {
  const _DatabaseTabView({
    this.onOpenServerServices,
    this.onOpenBackupTab,
    this.pickPostgresRestoreSqlFile,
  });

  final VoidCallback? onOpenServerServices;
  final VoidCallback? onOpenBackupTab;
  final Future<String?> Function()? pickPostgresRestoreSqlFile;

  @override
  ConsumerState<_DatabaseTabView> createState() => _DatabaseTabViewState();
}

class _ProjectDatabaseUserRecord {
  const _ProjectDatabaseUserRecord({
    required this.username,
    required this.accessMode,
    this.database,
    this.host,
    this.port,
  });

  final String username;
  final String accessMode;
  final String? database;
  final String? host;
  final int? port;
}

class _DatabaseUserAccessCard extends StatelessWidget {
  const _DatabaseUserAccessCard({
    required this.user,
    required this.accessLabel,
    required this.onRotatePassword,
    required this.onRemoveUser,
    required this.resetBusy,
    required this.removeBusy,
  });

  final _ProjectDatabaseUserRecord user;
  final String accessLabel;

  /// Null when the row cannot act -- no server or project selected, or another
  /// action is already running. A null callback is how the buttons below
  /// disable themselves, so there is no second flag saying the same thing.
  final VoidCallback? onRotatePassword;

  /// Null under the same conditions as [onRotatePassword].
  final VoidCallback? onRemoveUser;

  final bool resetBusy;
  final bool removeBusy;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      key: Key('database-user-${user.username}'),
      margin: const EdgeInsets.only(bottom: 10),
      radius: 10,
      borderColor: Theme.of(context).colorScheme.outlineVariant,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(user.username, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _LabeledValueRow(label: 'Permission', value: accessLabel),
          const SizedBox(height: 6),
          _LabeledValueRow(
            label: 'Database',
            value: user.database ?? 'Unknown',
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: Key('database-user-reset-${user.username}'),
                onPressed: onRotatePassword,
                child: Text(resetBusy ? 'Resetting...' : 'Reset password'),
              ),
              OutlinedButton(
                key: Key('database-user-delete-${user.username}'),
                onPressed: onRemoveUser,
                child: Text(removeBusy ? 'Deleting...' : 'Delete user'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _ProjectDatabaseEngine { postgres }

enum _DatabaseTabSection { sqlite, postgres }

class _DatabaseTabViewState extends ConsumerState<_DatabaseTabView>
    with WorkspaceScopedConsumerState<_DatabaseTabView> {
  static const String _sqliteDefaultMountPath = '/var/lib/deploydash/sqlite';
  static const String _sqliteDefaultFileName = 'app.sqlite3';

  bool _isLoading = true;
  String? _busyAction;
  String? _busyUsername;
  bool _serviceRunning = false;
  bool _serviceConfigured = false;
  bool _serviceStatusVerified = false;
  ContainerRuntimeStatus _serviceRuntimeStatus =
      const ContainerRuntimeStatus.unknown();
  PostgresStorageStatus _serviceStorageStatus = const PostgresStorageStatus();
  String? _engineVersion;
  String? _error;
  String? _errorDetails;
  String? _errorTitle;
  String? _sqliteError;
  String? _sqliteBusyAction;
  String? _sqliteBusyDatabaseId;
  String? _serviceHost;
  int? _servicePort;
  String? _selectedDatabase;
  String? _selectedUsername;
  _ProjectDatabaseEngine _selectedEngine = _ProjectDatabaseEngine.postgres;
  _DatabaseTabSection _selectedSection = _DatabaseTabSection.sqlite;
  List<String> _databases = const <String>[];
  List<_ProjectDatabaseUserRecord> _users =
      const <_ProjectDatabaseUserRecord>[];
  final Map<String, String> _knownUserPasswords = <String, String>{};
  List<ProjectNetworkGroupRecord> _linkedProjectGroups =
      const <ProjectNetworkGroupRecord>[];
  bool _sharingLoading = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _isLoading = true;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _applyState(VoidCallback update) {
    setState(update);
  }

  void _showDatabaseErrorAtTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  // coverage-gate: database_selection_bind
  void _bindSelection(Project? project, Server? server) {
    final projectId = project?.id;
    final serverId = server?.id;
    if (projectId == null ||
        serverId == null ||
        project == null ||
        server == null) {
      return;
    }
    final engine = _resolveEngineForServer(server);
    final section = _resolveSectionForServer(server);
    final currentScope = currentWorkspaceScope;
    final keepActionError =
        currentScope != null &&
        currentScope.matches(projectId: projectId, serverId: serverId) &&
        _selectedSection == section;
    final requestEpoch = bindWorkspaceSelection(
      project,
      server,
      discriminator: _databaseBindDiscriminator(server, section: section),
    );
    setState(() {
      _selectedEngine = engine;
      _selectedSection = section;
      _isLoading = true;
      if (!keepActionError) {
        _error = null;
        _errorDetails = null;
        _errorTitle = null;
        _sqliteError = null;
      }
      _sqliteBusyAction = null;
      _sqliteBusyDatabaseId = null;
      _serviceRunning = false;
      _serviceConfigured = server.serviceDatabaseEnabled;
      _serviceStatusVerified = false;
      _serviceRuntimeStatus = server.serviceDatabaseEnabled
          ? const ContainerRuntimeStatus.unknown()
          : const ContainerRuntimeStatus.notConfigured();
      _serviceStorageStatus = const PostgresStorageStatus();
      _engineVersion = null;
      _serviceHost = null;
      _servicePort = null;
      _selectedDatabase = null;
      _selectedUsername = null;
      _databases = const <String>[];
      _users = const <_ProjectDatabaseUserRecord>[];
      _knownUserPasswords.clear();
      _linkedProjectGroups = const <ProjectNetworkGroupRecord>[];
      _sharingLoading = false;
    });
    unawaited(
      ref.read(projectSqliteDatabasesProvider.notifier).loadProject(projectId),
    );
    unawaited(
      _loadLocalManagedDatabases(
        engine: engine,
        project: project,
        server: server,
        requestEpoch: requestEpoch,
      ),
    );
    unawaited(_refreshLinkedProjects(project: project, server: server));
  }

  // end coverage-gate
  // coverage-gate: detached_storage_local_catalog
  Future<void> _loadLocalManagedDatabases({
    required _ProjectDatabaseEngine engine,
    required Project project,
    required Server server,
    required int requestEpoch,
  }) async {
    final expectedProjectId = project.id;
    final expectedServerId = server.id;
    try {
      final repository = ref.read(projectManagedDatabaseRepositoryProvider);
      final databaseRows = await repository.listDatabasesForScope(
        projectId: project.id,
        serverId: server.id,
        engine: engine.name,
      );
      final userRows = await repository.listUsersForScope(
        projectId: project.id,
        serverId: server.id,
        engine: engine.name,
      );
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
            expectedEpoch: requestEpoch,
          )) {
        return;
      }
      final databases =
          databaseRows
              .map((row) => row.databaseName)
              .where((name) => name.trim().isNotEmpty)
              .toSet()
              .toList(growable: false)
            ..sort();
      final users = userRows
          .map(
            (row) => _ProjectDatabaseUserRecord(
              username: row.username,
              accessMode: row.accessMode == 'read_only'
                  ? 'read_only'
                  : 'read_write',
              database: row.databaseName,
              host: row.host,
              port: row.port,
            ),
          )
          .toList(growable: false);
      for (final row in userRows) {
        final password = row.password?.trim();
        if (password == null || password.isEmpty) {
          continue;
        }
        _storeKnownPassword(
          engine: engine,
          projectId: project.id,
          serverId: server.id,
          username: row.username,
          password: password,
          databaseName: row.databaseName,
        );
      }
      final selectedDatabase = _resolveSelectedDatabase(
        availableDatabases: databases,
        preferredDatabase: _selectedDatabase,
      );
      final selectedUsername = _resolveSelectedUsername(
        users: users,
        selectedDatabase: selectedDatabase,
        preferredUsername: _selectedUsername,
      );
      final selectedUser = _userForSelection(
        users: users,
        selectedDatabase: selectedDatabase,
        selectedUsername: selectedUsername,
      );
      setState(() {
        _serviceConfigured = server.serviceDatabaseEnabled;
        _serviceRunning = server.serviceDatabaseEnabled;
        _serviceStatusVerified = false;
        _serviceRuntimeStatus = server.serviceDatabaseEnabled
            ? const ContainerRuntimeStatus.unknown()
            : const ContainerRuntimeStatus.notConfigured();
        _serviceStorageStatus = const PostgresStorageStatus();
        _serviceHost = selectedUser?.host;
        _servicePort = selectedUser?.port;
        _selectedDatabase = selectedDatabase;
        _selectedUsername = selectedUsername;
        _databases = databases;
        _users = users;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted ||
          !isCurrentWorkspaceIds(
            projectId: expectedProjectId,
            serverId: expectedServerId,
            expectedEpoch: requestEpoch,
          )) {
        return;
      }
      setState(() {
        _isLoading = false;
        _serviceConfigured = server.serviceDatabaseEnabled;
        _serviceRunning = server.serviceDatabaseEnabled;
        _serviceStatusVerified = false;
        _serviceRuntimeStatus = server.serviceDatabaseEnabled
            ? const ContainerRuntimeStatus.unknown()
            : const ContainerRuntimeStatus.notConfigured();
        _serviceStorageStatus = const PostgresStorageStatus();
        _setDatabaseErrorState(
          message: 'Could not load local database catalog: $error',
        );
      });
    }
  }
  // end coverage-gate

  void _scheduleSelectionBind(Project? project, Server? server) {
    final scope = workspaceScopeFor(project, server);
    if (server != null &&
        scope != null &&
        currentWorkspaceScope?.key == scope.key) {
      final selectionDiscriminator = _databaseSelectionDiscriminator(server);
      if (workspaceBindDiscriminator == selectionDiscriminator ||
          workspaceBindDiscriminator.startsWith('$selectionDiscriminator::')) {
        return;
      }
    }
    scheduleWorkspaceSelectionBind(
      project: project,
      server: server,
      discriminator: server == null
          ? ''
          : _databaseSelectionDiscriminator(server),
      onBind: _bindSelection,
    );
  }

  String _databaseSelectionDiscriminator(Server server) {
    return '${server.updatedAt?.microsecondsSinceEpoch ?? 0}';
  }

  String _databaseBindDiscriminator(
    Server server, {
    required _DatabaseTabSection section,
  }) {
    return '${_databaseSelectionDiscriminator(server)}::${section.name}';
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  void _scheduleSqliteLoad(Project? project) {
    final projectId = project?.id;
    if (projectId == null || project == null) {
      return;
    }
    final sqliteByProject = ref.read(projectSqliteDatabasesProvider);
    if (sqliteByProject.containsKey(projectId)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      ref.read(projectSqliteDatabasesProvider.notifier).loadProject(projectId);
    });
  }

  // coverage-gate: database_error_state
  void _setDatabaseErrorState({
    required String message,
    String? details,
    String? title,
  }) {
    _error = message;
    // toString-first: trimOrNull takes String? (D-87).
    _errorDetails = trimOrNull(details?.toString());
    _errorTitle = title;
  }

  // end coverage-gate

  @override
  // coverage-gate: database_tab_build
  Widget build(BuildContext context) {
    final selectedServer = ref.watch(selectedServerProvider);
    final selectedProject = ref.watch(selectedProjectProvider);
    final actionFeedback = selectedProject == null || selectedServer == null
        ? null
        : ref
              .watch(projectDatabaseActionFeedbackProvider)
              .forScope(
                projectId: selectedProject.id,
                serverId: selectedServer.id,
              );
    final allProjects = ref.watch(projectListProvider);
    final sqliteByProject = ref.watch(projectSqliteDatabasesProvider);
    _scheduleSqliteLoad(selectedProject);
    final sqliteDatabases = selectedProject == null
        ? const <ProjectSqliteDatabase>[]
        : (sqliteByProject[selectedProject.id] ??
              const <ProjectSqliteDatabase>[]);

    final postgresEnabled = selectedServer?.serviceDatabaseEnabled == true;
    final managedDatabaseEnabled = postgresEnabled;

    _scheduleSelectionBind(selectedProject, selectedServer);
    if (managedDatabaseEnabled) {
      _selectedEngine = _ProjectDatabaseEngine.postgres;
    }

    final selectedManagedEngine = _engineForSection(_selectedSection);
    final showingManagedSection = selectedManagedEngine != null;
    final selectedManagedEngineEnabled = switch (selectedManagedEngine) {
      _ProjectDatabaseEngine.postgres => postgresEnabled,
      null => false,
    };
    // coverage-gate: detached_storage_readiness
    final managedDatabaseReady =
        showingManagedSection &&
        selectedManagedEngineEnabled &&
        !_isLoading &&
        _serviceConfigured &&
        !_serviceStorageStatus.hasDetachedError;
    // end coverage-gate
    final serviceKnownStopped = _serviceStatusVerified && !_serviceRunning;

    final serviceHost = _serviceHost;
    final host = (serviceHost != null && serviceHost.isNotEmpty)
        ? serviceHost
        : (selectedServer?.host ?? 'Not connected');
    final port =
        _servicePort ??
        _defaultPortForEngine(engine: _selectedEngine, server: selectedServer);
    final engineVersion = _engineVersion?.trim();
    final engineLabel = switch (_selectedEngine) {
      _ProjectDatabaseEngine.postgres =>
        (engineVersion != null && engineVersion.isNotEmpty)
            ? 'PostgreSQL $engineVersion'
            : 'PostgreSQL ${selectedServer?.postgresConfig.postgresVersion ?? '17'}',
    };
    final healthLabel = !_serviceConfigured
        ? 'Not configured'
        : !_serviceStatusVerified
        ? 'Not checked'
        : _serviceRuntimeStatus.label;
    final statusLabel = !_serviceConfigured
        ? 'Setup needed'
        : !_serviceStatusVerified
        ? 'Configured'
        : _serviceRuntimeStatus.label;
    final statusTone = !_serviceConfigured
        ? AppStatusTone.neutral
        : !_serviceStatusVerified
        ? AppStatusTone.info
        : appContainerRuntimeStatusTone(_serviceRuntimeStatus.effectiveStatus);
    final topActionBusy =
        _busyAction == 'create_database' ||
        _busyAction == 'connect_existing' ||
        _busyAction == 'delete_database' ||
        _busyAction == 'normalize_database' ||
        _busyAction == 'restore_local_sql' ||
        _busyAction == 'refresh';
    final refreshBusy = _busyAction == 'refresh';
    final createBusy = _busyAction == 'create_database';
    final connectBusy = _busyAction == 'connect_existing';
    final deleteDatabaseBusy = _busyAction == 'delete_database';
    final normalizeBusy = _busyAction == 'normalize_database';
    final restoreLocalSqlBusy = _busyAction == 'restore_local_sql';

    // Resolved once: the action feedback wins, the tab's own error is the
    // fallback, and null means there is nothing to report. That makes the
    // card's condition below the same question as its content.
    final errorMessage = actionFeedback?.message ?? _error;
    final errorDetails = actionFeedback?.details ?? _errorDetails;

    final selectedDatabase = _selectedDatabase;
    final selectedDatabaseDropdownValue =
        selectedDatabase != null && _databases.contains(selectedDatabase)
        ? selectedDatabase
        : null;
    final usersForSelectedDatabase = selectedDatabase == null
        ? const <_ProjectDatabaseUserRecord>[]
        : _users
              .where((user) => user.database == selectedDatabase)
              .toList(growable: false);
    _ProjectDatabaseUserRecord? selectedUser;
    final selectedUsername = _selectedUsername;
    if (selectedUsername != null && usersForSelectedDatabase.isNotEmpty) {
      for (final user in usersForSelectedDatabase) {
        if (user.username == selectedUsername) {
          selectedUser = user;
          break;
        }
      }
    }
    final selectedPassword = _knownPasswordForSelection(
      engine: _selectedEngine,
      projectId: selectedProject?.id,
      serverId: selectedServer?.id,
      username: selectedUser?.username,
      databaseName: selectedDatabase,
    );
    final connectionHost = _webAppHostForEngine(
      engine: _selectedEngine,
      host: host,
    );
    final connectionString =
        (selectedDatabase != null &&
            selectedUser != null &&
            selectedPassword != null &&
            selectedPassword.isNotEmpty &&
            connectionHost.trim().isNotEmpty)
        ? buildManagedPostgresDatabaseUrl(
            username: selectedUser.username,
            password: selectedPassword,
            port: port,
            databaseName: selectedDatabase,
            host: connectionHost,
          )
        : null;
    final managedEngineName = switch (_selectedEngine) {
      _ProjectDatabaseEngine.postgres => 'PostgreSQL',
    };
    // coverage-gate: detached_storage_card
    final storageError = _serviceStorageStatus.storageError;
    final managedStateCard = !managedDatabaseEnabled
        ? _DatabaseManagedServiceStateCard(
            state: this,
            message: 'Database service is disabled for this server.',
            description:
                'Enable PostgreSQL in Server Management to use '
                'managed database controls.',
          )
        : (_error != null && showingManagedSection)
        ? null
        : !showingManagedSection
        ? null
        : _isLoading
        ? AppWorkspaceSection(
            key: const Key('database-managed-loading-card'),
            icon: Icons.hourglass_top,
            title: 'Managed databases',
            subtitle: 'Loading $managedEngineName status...',
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        : storageError != null
        ? _DatabaseManagedServiceStateCard(
            state: this,
            message: 'Data volume may be detached',
            description: storageError,
          )
        : !_serviceConfigured
        ? _DatabaseManagedServiceStateCard(
            state: this,
            message: '$managedEngineName service is not configured yet.',
            description:
                'Finish $managedEngineName setup in Server Management, then '
                'return to this tab.',
          )
        : null;
    // end coverage-gate

    return ListView(
      key: const Key('database-tab-scroll'),
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        AppWorkspaceSection(
          key: const Key('database-type-tabs-card'),
          icon: Icons.table_rows_outlined,
          title: 'Database type',
          subtitle: 'Switch workspace context by database type.',
          child: SegmentedButton<_DatabaseTabSection>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment<_DatabaseTabSection>(
                value: _DatabaseTabSection.sqlite,
                label: Text('SQLite', key: Key('database-type-sqlite-tab')),
              ),
              ButtonSegment<_DatabaseTabSection>(
                value: _DatabaseTabSection.postgres,
                label: Text(
                  'PostgreSQL',
                  key: Key('database-type-postgres-tab'),
                ),
              ),
            ],
            selected: <_DatabaseTabSection>{_selectedSection},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) {
                return;
              }
              final nextSection = selection.first;
              if (nextSection == _selectedSection) {
                return;
              }
              final nextEngine = _engineForSection(nextSection);
              if (nextEngine == null) {
                setState(() {
                  _selectedSection = _DatabaseTabSection.sqlite;
                });
                return;
              }
              final canSwitch = switch (nextEngine) {
                _ProjectDatabaseEngine.postgres => postgresEnabled,
              };
              if (!canSwitch) {
                setState(() {
                  _selectedSection = nextSection;
                });
                return;
              }
              if (selectedServer == null || selectedProject == null) {
                return;
              }
              setState(() {
                _selectedSection = nextSection;
                _selectedEngine = nextEngine;
                _isLoading = true;
                _error = null;
                _errorDetails = null;
                _errorTitle = null;
                _serviceConfigured = selectedServer.serviceDatabaseEnabled;
                _serviceRunning = selectedServer.serviceDatabaseEnabled;
                _serviceStatusVerified = false;
                _serviceRuntimeStatus = selectedServer.serviceDatabaseEnabled
                    ? const ContainerRuntimeStatus.unknown()
                    : const ContainerRuntimeStatus.notConfigured();
                _serviceStorageStatus = const PostgresStorageStatus();
                _serviceHost = null;
                _servicePort = null;
                _selectedDatabase = null;
                _selectedUsername = null;
                _databases = const <String>[];
                _users = const <_ProjectDatabaseUserRecord>[];
              });
              final requestEpoch = updateWorkspaceDiscriminator(
                _databaseBindDiscriminator(
                  selectedServer,
                  section: nextSection,
                ),
              );
              unawaited(
                _loadLocalManagedDatabases(
                  engine: nextEngine,
                  project: selectedProject,
                  server: selectedServer,
                  requestEpoch: requestEpoch,
                ),
              );
              unawaited(
                _refreshLinkedProjects(
                  project: selectedProject,
                  server: selectedServer,
                ),
              );
            },
          ),
        ),
        if (_selectedSection == _DatabaseTabSection.sqlite)
          _DatabaseSqliteCard(
            state: this,
            server: selectedServer,
            project: selectedProject,
            sqliteDatabases: sqliteDatabases,
          ),
        if (_selectedSection != _DatabaseTabSection.sqlite &&
            managedStateCard != null)
          managedStateCard,
        if (_selectedSection != _DatabaseTabSection.sqlite &&
            errorMessage != null)
          AppWorkspaceSection(
            key: const Key('database-error-card'),
            icon: Icons.error_outline,
            title:
                actionFeedback?.title ??
                _errorTitle ??
                'Database action failed',
            subtitle: 'Review the issue and retry after fixing the cause.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  key: const Key('database-error-pill'),
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          errorMessage,
                          key: const Key('database-error-text'),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (errorDetails != null) ...[
                  const SizedBox(height: 10),
                  SelectableText(
                    errorDetails,
                    key: const Key('database-error-details-text'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Check Database service status in Server Management, then retry.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      key: const Key('database-error-retry-button'),
                      onPressed:
                          selectedServer == null ||
                              selectedProject == null ||
                              refreshBusy
                          ? null
                          : () => _refreshFromUi(
                              engine: _selectedEngine,
                              server: selectedServer,
                              project: selectedProject,
                            ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                    if (errorDetails != null)
                      OutlinedButton.icon(
                        key: const Key('database-error-copy-details-button'),
                        onPressed: () async {
                          final payload = '$errorMessage\n\n$errorDetails';
                          await Clipboard.setData(ClipboardData(text: payload));
                          if (!context.mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Error details copied.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy details'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (_selectedSection != _DatabaseTabSection.sqlite &&
            managedDatabaseReady)
          Builder(
            builder: (context) {
              final overviewCard = AppWorkspaceSection(
                key: const Key('database-overview-card'),
                icon: YaruIcons.drive_harddisk,
                title: 'Database overview',
                subtitle: 'Core status for your project data.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppStatusBadge(label: statusLabel, tone: statusTone),
                    const SizedBox(height: 12),
                    _LabeledValueRow(label: 'Engine', value: engineLabel),
                    const SizedBox(height: 8),
                    _LabeledValueRow(
                      label: 'Databases',
                      value: _databases.length.toString(),
                    ),
                    const SizedBox(height: 8),
                    _LabeledValueRow(
                      label: 'Users',
                      value: _users.length.toString(),
                    ),
                    const SizedBox(height: 8),
                    _LabeledValueRow(label: 'Health', value: healthLabel),
                  ],
                ),
              );

              final actionsCard = AppWorkspaceSection(
                key: const Key('database-actions-card'),
                icon: Icons.playlist_add_check_circle_outlined,
                title: 'Databases',
                subtitle: 'Create and refresh project databases.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      !_serviceConfigured
                          ? 'Enable the Database service in Server Management before creating project databases.'
                          : 'Create databases here. Choose a database in the card below to manage its connection details and users.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    if (_databases.isEmpty) ...[
                      AppCard(
                        margin: EdgeInsets.zero,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.storage_outlined,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'No databases created yet.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Create your first database to continue.',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('database-create-button'),
                          onPressed:
                              (serviceKnownStopped ||
                                  topActionBusy ||
                                  _isLoading ||
                                  selectedServer == null ||
                                  selectedProject == null)
                              ? null
                              : () => _showCreateDatabaseDialog(
                                  server: selectedServer,
                                  project: selectedProject,
                                ),
                          icon: const Icon(Icons.add),
                          label: Text(
                            createBusy ? 'Creating...' : 'Create database',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              (topActionBusy ||
                                  _isLoading ||
                                  selectedServer == null ||
                                  selectedProject == null)
                              ? null
                              : () => _refreshFromUi(
                                  engine: _selectedEngine,
                                  server: selectedServer,
                                  project: selectedProject,
                                ),
                          icon: const Icon(Icons.refresh),
                          label: Text(
                            refreshBusy ? 'Refreshing...' : 'Refresh',
                          ),
                        ),
                      ],
                    ),
                    if (_databases.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        _databases.length == 1
                            ? '1 database available.'
                            : '${_databases.length} databases available.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      for (final database in _databases)
                        AppResourceRow(
                          key: Key('database-resource-$database'),
                          title: database,
                          subtitle: database == selectedDatabase
                              ? 'Selected database'
                              : 'Managed PostgreSQL database',
                          leading: const Icon(Icons.storage_outlined),
                          selected: database == selectedDatabase,
                          onTap: topActionBusy || _isLoading
                              ? null
                              : () => _selectDatabase(value: database),
                        ),
                    ],
                  ],
                ),
              );

              final selectedDatabaseCard = AppDetailPane(
                key: const Key('database-selected-card'),
                title: 'Selected database',
                subtitle:
                    'Choose a database, then manage its connection details and users.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String?>(
                      key: const Key(
                        'database-actions-select-database-dropdown',
                      ),
                      initialValue: selectedDatabaseDropdownValue,
                      decoration: const InputDecoration(
                        labelText: 'Select the database you want to work with',
                      ),
                      items: <DropdownMenuItem<String?>>[
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Select a database'),
                        ),
                        ..._databases.map(
                          (db) => DropdownMenuItem<String?>(
                            value: db,
                            child: Text(db),
                          ),
                        ),
                      ],
                      onChanged:
                          (_databases.isEmpty ||
                              topActionBusy ||
                              _isLoading ||
                              selectedProject == null)
                          ? null
                          : (value) => _selectDatabase(value: value),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _databases.isEmpty
                          ? 'Create a database first, then manage its connection details and users here.'
                          : 'Connection details and users below apply to the selected database.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (selectedDatabase != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        'Selected: $selectedDatabase',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('database-delete-button'),
                          onPressed:
                              (selectedDatabase == null ||
                                  serviceKnownStopped ||
                                  topActionBusy ||
                                  _isLoading ||
                                  selectedServer == null ||
                                  selectedProject == null)
                              ? null
                              : () => _deleteSelectedDatabase(
                                  server: selectedServer,
                                  project: selectedProject,
                                  databaseName: selectedDatabase,
                                ),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(
                            deleteDatabaseBusy
                                ? 'Deleting...'
                                : 'Delete database',
                          ),
                        ),
                        // coverage-gate: normalize_database_button
                        OutlinedButton.icon(
                          key: const Key('database-normalize-button'),
                          onPressed:
                              (selectedDatabase == null ||
                                  serviceKnownStopped ||
                                  topActionBusy ||
                                  _isLoading ||
                                  selectedServer == null ||
                                  selectedProject == null)
                              ? null
                              : () => _normalizeSelectedDatabase(
                                  server: selectedServer,
                                  project: selectedProject,
                                  databaseName: selectedDatabase,
                                ),
                          icon: const Icon(Icons.security_outlined),
                          label: Text(
                            normalizeBusy
                                ? 'Normalizing...'
                                : 'Normalize isolation',
                          ),
                        ),
                        // end coverage-gate
                        OutlinedButton.icon(
                          key: const Key('database-restore-local-sql-button'),
                          onPressed:
                              (selectedDatabase == null ||
                                  serviceKnownStopped ||
                                  topActionBusy ||
                                  _isLoading ||
                                  selectedServer == null ||
                                  selectedProject == null)
                              ? null
                              : () => _restoreLocalPostgresSql(
                                  server: selectedServer,
                                  project: selectedProject,
                                  databaseName: selectedDatabase,
                                ),
                          icon: const Icon(Icons.upload_file_outlined),
                          label: Text(
                            restoreLocalSqlBusy
                                ? 'Importing...'
                                : 'Import .sql into DB',
                          ),
                        ),
                      ],
                    ),
                    if (selectedDatabase == null) ...[
                      const SizedBox(height: 8),
                      const Text('Select a database before deleting it.'),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Select a database before restoring a .sql file.',
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    AppCard(
                      key: const Key('database-connection-card'),
                      margin: EdgeInsets.zero,
                      padding: const EdgeInsets.all(16),
                      radius: 12,
                      borderColor: Theme.of(context).colorScheme.outlineVariant,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connection details',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Values your app can use to connect safely.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          _LabeledValueRow(
                            label: 'Selected database',
                            value: selectedDatabase ?? 'Not configured yet',
                          ),
                          const SizedBox(height: 12),
                          if (usersForSelectedDatabase.isNotEmpty) ...[
                            DropdownButtonFormField<String>(
                              key: const Key('database-select-user-dropdown'),
                              initialValue: selectedUser?.username,
                              decoration: const InputDecoration(
                                labelText: 'Active user',
                              ),
                              items: usersForSelectedDatabase
                                  .map(
                                    (user) => DropdownMenuItem<String>(
                                      value: user.username,
                                      child: Text(user.username),
                                    ),
                                  )
                                  .toList(growable: false),
                              onChanged: topActionBusy
                                  ? null
                                  : (value) {
                                      if (value == null) {
                                        return;
                                      }
                                      final selectedUser = _userForSelection(
                                        users: _users,
                                        selectedDatabase: selectedDatabase,
                                        selectedUsername: value,
                                      );
                                      setState(() {
                                        _selectedUsername = value;
                                        _serviceHost = selectedUser?.host;
                                        _servicePort = selectedUser?.port;
                                      });
                                    },
                            ),
                            const SizedBox(height: 12),
                          ] else if (selectedDatabase != null) ...[
                            Text(
                              'No database users exist for the selected database yet.',
                              key: const Key(
                                'database-selected-db-no-user-hint',
                              ),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                          ],
                          AppCard(
                            margin: EdgeInsets.zero,
                            fillColor: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _LabeledValueRow(
                                  label: 'Host',
                                  value: connectionHost,
                                ),
                                const SizedBox(height: 8),
                                _LabeledValueRow(label: 'Port', value: '$port'),
                                const SizedBox(height: 8),
                                _LabeledValueRow(
                                  label: 'Database',
                                  value:
                                      selectedDatabase ?? 'Not configured yet',
                                ),
                                const SizedBox(height: 8),
                                _LabeledValueRow(
                                  label: 'Username',
                                  value:
                                      selectedUser?.username ??
                                      'Not configured yet',
                                ),
                                const SizedBox(height: 8),
                                _LabeledValueRow(
                                  label: 'Password',
                                  value:
                                      selectedPassword ??
                                      'Not captured in this session',
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const Key(
                                  'database-copy-connection-button',
                                ),
                                onPressed: connectionString == null
                                    ? null
                                    : () async {
                                        await Clipboard.setData(
                                          ClipboardData(text: connectionString),
                                        );
                                        if (!context.mounted) {
                                          return;
                                        }
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Connection string copied.',
                                            ),
                                          ),
                                        );
                                      },
                                icon: const Icon(Icons.copy),
                                label: const Text('Copy connection string'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'To use these credentials in a web app, add the connection string or separate values in the Environment variables editor.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    AppCard(
                      key: const Key('database-access-card'),
                      margin: EdgeInsets.zero,
                      padding: const EdgeInsets.all(16),
                      radius: 12,
                      borderColor: Theme.of(context).colorScheme.outlineVariant,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Database users',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Create and manage login details for the selected database.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          if (selectedDatabase != null) ...[
                            _LabeledValueRow(
                              label: 'Selected database',
                              value: selectedDatabase,
                            ),
                            const SizedBox(height: 12),
                          ],
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const Key('database-link-button'),
                                onPressed:
                                    (serviceKnownStopped ||
                                        topActionBusy ||
                                        _isLoading ||
                                        selectedServer == null ||
                                        selectedProject == null)
                                    ? null
                                    : () => _showConnectExistingDialog(
                                        server: selectedServer,
                                        project: selectedProject,
                                      ),
                                icon: const Icon(
                                  Icons.person_add_alt_1_outlined,
                                ),
                                label: Text(
                                  connectBusy
                                      ? 'Creating...'
                                      : 'Create database user',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_databases.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                'Create a database first, then add users for it.',
                              ),
                            )
                          else if (selectedDatabase == null)
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                'Select a database to manage its users.',
                              ),
                            )
                          else if (usersForSelectedDatabase.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                'No database users exist for $selectedDatabase yet.',
                              ),
                            ),
                          for (final user in usersForSelectedDatabase)
                            _DatabaseUserAccessCard(
                              user: user,
                              accessLabel: _databaseAccessLabel(
                                user.accessMode,
                              ),
                              resetBusy:
                                  _busyAction == 'rotate_password' &&
                                  _busyUsername == user.username,
                              removeBusy:
                                  _busyAction == 'remove_user' &&
                                  _busyUsername == user.username,
                              onRotatePassword:
                                  (topActionBusy ||
                                      selectedServer == null ||
                                      selectedProject == null)
                                  ? null
                                  : () => _rotateUserPassword(
                                      server: selectedServer,
                                      project: selectedProject,
                                      user: user,
                                    ),
                              onRemoveUser:
                                  (topActionBusy ||
                                      selectedServer == null ||
                                      selectedProject == null)
                                  ? null
                                  : () => _removeUser(
                                      server: selectedServer,
                                      project: selectedProject,
                                      user: user,
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );

              return AppMasterDetail(
                master: Column(children: [overviewCard, actionsCard]),
                detail: selectedDatabaseCard,
              );
            },
          ),
        if (_selectedSection != _DatabaseTabSection.sqlite &&
            selectedServer != null &&
            selectedProject != null) ...[
          _ProjectDatabaseSharingCard(
            state: this,
            project: selectedProject,
            projects: allProjects,
          ),
        ],
        AppWorkspaceSection(
          key: const Key('database-backups-card'),
          icon: Icons.history,
          title: 'Backups',
          subtitle: 'Use project backup workflows for snapshots and recovery.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Database backup and restore controls now live in the Backup tab.',
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('database-open-backup-tab-button'),
                onPressed: widget.onOpenBackupTab,
                icon: const Icon(Icons.backup),
                label: const Text('Open Backup tab'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
// end coverage-gate
