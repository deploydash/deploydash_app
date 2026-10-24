// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _BackupStateMethods on _BackupSummaryState {
  // coverage-gate: backup_selection
  void _scheduleSelectionBind(Project? project, Server? server) {
    scheduleWorkspaceSelectionBind(
      project: project,
      server: server,
      discriminator: _backupBindDiscriminator(_selectedEngine),
      onBind: _bindSelection,
    );
  }

  String _backupBindDiscriminator(_BackupEngineChoice engine) {
    return engine.name;
  }

  _BackupEngineChoice _resolveEngineForServer(Server server) {
    return _BackupEngineChoice.postgres;
  }

  Future<void> _bindSelection(Project project, Server server) async {
    final projectId = project.id;
    final serverId = server.id;
    final engine = _resolveEngineForServer(server);
    final operationEpoch = bindWorkspaceSelection(
      project,
      server,
      discriminator: _backupBindDiscriminator(engine),
    );

    setState(() {
      _selectedEngine = engine;
      _isLoading = true;
      _isSaving = false;
      _error = null;
      _projectDatabases = const <String>[];
    });

    try {
      await ref
          .read(projectBackupProvider.notifier)
          .loadScope(projectId: projectId, serverId: serverId);
      await ref.read(projectSchedulerProvider.notifier).loadProject(projectId);
      await _loadProjectDatabases(
        project: project,
        server: server,
        engine: engine,
        expectedEpoch: operationEpoch,
      );
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
      // G-42: "Recent backups" used to render whatever the last visit left in
      // provider state, so a user could conclude backups had not run for days.
      // Clearing _isLoading first is deliberate: unlike G-33 these artifacts
      // are correctly attributed and merely old, so they stay on screen while
      // the newest list is fetched rather than flashing empty on every visit.
      // A failure here is reported inline and does not fail the bind.
      final refreshError = await ref
          .read(projectBackupProvider.notifier)
          .refreshArtifactsForScope(project: project, server: server);
      if (refreshError != null &&
          mounted &&
          isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        setState(() {
          _error = refreshError;
        });
      }
    } catch (error) {
      if (!isCurrentWorkspaceSelection(project, server, operationEpoch)) {
        return;
      }
      setState(() {
        _isLoading = false;
        _error = backupLoadErrorMessage(error);
      });
    }
  }

  Future<void> _loadProjectDatabases({
    required Project project,
    required Server server,
    required _BackupEngineChoice engine,
    int? expectedEpoch,
  }) async {
    if (!isCurrentWorkspaceSelection(project, server, expectedEpoch)) {
      return;
    }
    if (engine == _BackupEngineChoice.postgres &&
        !server.serviceDatabaseEnabled) {
      if (mounted) {
        setState(() {
          _projectDatabases = const <String>[];
        });
      }
      return;
    }
    await ref
        .read(projectManagedDatabaseProvider.notifier)
        .loadScope(projectId: project.id, serverId: server.id);
    if (!isCurrentWorkspaceSelection(project, server, expectedEpoch)) {
      return;
    }
    final databaseScope = ref
        .read(projectManagedDatabaseProvider)
        .scopeFor(projectId: project.id, serverId: server.id);
    final databases = databaseScope.databases
        .where((database) => database.engine == 'postgres')
        .map((database) => database.databaseName.trim())
        .where((database) => database.isNotEmpty)
        .toSet()
        .toList(growable: false);
    databases.sort();
    setState(() {
      _projectDatabases = databases;
    });
  }

  // end coverage-gate
  BackupWorkspaceEngineChoice _logicEngineChoice([
    _BackupEngineChoice? engine,
  ]) {
    return BackupWorkspaceEngineChoice.postgres;
  }

  String _taskIdForPolicy(String policyId, {_BackupEngineChoice? engine}) {
    return backupTaskIdForPolicy(
      policyId: policyId,
      engine: _logicEngineChoice(engine),
    );
  }

  BackupEngine _activeEngineRecord([_BackupEngineChoice? engine]) {
    return backupEngineRecordForSelection(_logicEngineChoice(engine));
  }

  String _activeWorkflowId([_BackupEngineChoice? engine]) {
    return backupWorkflowIdForSelection(_logicEngineChoice(engine));
  }

  bool _destinationSupportedForActiveEngine(
    BackupDestinationRecord destination,
    _BackupEngineChoice engine,
  ) {
    return backupDestinationSupportedForEngine(
      engine: _logicEngineChoice(engine),
      destinationType: destination.type,
    );
  }

  List<BackupDestinationRecord> _eligibleDestinationsForActiveEngine(
    List<BackupDestinationRecord> destinations,
  ) {
    return eligibleBackupDestinationsForEngine(
      engine: _logicEngineChoice(),
      destinations: destinations,
    );
  }

  bool _validateDestinationForActiveEngine({
    required BackupDestinationRecord destination,
    required String actionLabel,
    required _BackupEngineChoice engine,
  }) {
    if (_destinationSupportedForActiveEngine(destination, engine)) {
      return true;
    }
    setState(() {
      _isSaving = false;
      _error = '$actionLabel failed: unsupported destination type.';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('That destination type is not supported here.'),
      ),
    );
    return false;
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  Map<String, dynamic> _basePostgresSettings({
    required Project project,
    required Server server,
  }) {
    return buildBackupBasePostgresSettings(
      projectName: project.name,
      server: server,
    );
  }

  Map<String, dynamic> _destinationSettings(
    BackupDestinationRecord destination,
    _BackupEngineChoice engine,
  ) {
    return buildBackupDestinationSettings(
      engine: _logicEngineChoice(engine),
      destinationType: destination.type,
      destinationConfig: destination.config,
    );
  }

  Future<Map<String, dynamic>> _runBackupWorkflow({
    required Project project,
    required Server server,
    required _BackupEngineChoice engine,
    required String operationId,
    Map<String, dynamic>? extraSettings,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return <String, dynamic>{
        'status': 'error',
        'msg': backupMissingCredentialsMessage(),
      };
    }

    final settings = <String, dynamic>{
      ..._basePostgresSettings(project: project, server: server),
      ...?extraSettings,
    };
    return (await ref
            .read(sshServiceProvider)
            .runWorkflow(
              workflowId: _activeWorkflowId(engine),
              operationId: operationId,
              connection: connection,
              params: <String, dynamic>{'dry_run': false, 'settings': settings},
              onEvent: onEvent,
            ))
        .diagnosticPayload;
  }

  // coverage-gate: backup_journaled_workflow
  Future<_JournaledProjectWorkflowResult> _runJournaledBackupWorkflow({
    required Project project,
    required Server server,
    required _BackupEngineChoice engine,
    required String operationId,
    required Map<String, dynamic>? extraSettings,
    Map<String, dynamic>? journalRequest,
    void Function(Map<String, dynamic> event)? onEvent,
  }) async {
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      throw StateError(backupMissingCredentialsMessage());
    }

    final settings = <String, dynamic>{
      ..._basePostgresSettings(project: project, server: server),
      ...?extraSettings,
    };
    return _runJournaledProjectWorkflow(
      ref: ref,
      project: project,
      server: server,
      surface: 'backup',
      operationType: operationId,
      workflowId: _activeWorkflowId(engine),
      operationId: operationId,
      connection: connection,
      params: <String, dynamic>{'dry_run': false, 'settings': settings},
      journalRequest: journalRequest,
      onEvent: onEvent,
    );
  }

  // end coverage-gate
  bool _isBackupDetailEventType(String type) {
    return backupDetailEventTypes.contains(type);
  }

  void _appendBackupTerminalLine(
    String line, {
    String source = 'backup',
    String? taskType = 'backup',
    bool detail = false,
  }) {
    widget.onTerminalLine?.call(
      line,
      source: source,
      taskType: taskType,
      detail: detail,
    );
  }

  void _appendBackupLogEvent(Map<String, dynamic> event) {
    final message = event['message']?.toString().trim() ?? '';
    if (message.isEmpty) {
      return;
    }
    final type = event['type']?.toString().trim() ?? 'event';
    _appendBackupTerminalLine(
      message,
      source: 'backup',
      taskType: 'backup',
      detail: _isBackupDetailEventType(type),
    );
  }

  String _responseMessageWithDetails(
    Map<String, dynamic> response, {
    required String fallback,
  }) {
    return backupResponseMessageWithDetails(response, fallback: fallback);
  }

  Future<void> _showWorkspaceActionErrorDialog({
    required String title,
    required String message,
  }) async {
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppDialogScaffold(
          title: title,
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('OK'),
            ),
          ],
          child: Text(message),
        );
      },
    );
  }

  void _appendBackupResultLog({
    required String prefix,
    required Map<String, dynamic> response,
  }) {
    final status = response['status']?.toString().trim() ?? 'error';
    _appendBackupTerminalLine(
      buildBackupResultLogLine(prefix: prefix, response: response),
      source: 'backup',
      taskType: 'backup',
      detail: status != 'success',
    );
  }

  Future<Map<String, dynamic>> _testBackupDestination({
    required Project project,
    required Server server,
    required BackupDestinationType destinationType,
    required Map<String, dynamic> destinationConfig,
  }) {
    final engine = _selectedEngine;
    final extraSettings = buildBackupDestinationSettings(
      engine: _logicEngineChoice(engine),
      destinationType: destinationType,
      destinationConfig: destinationConfig,
    );
    return _runBackupWorkflow(
      project: project,
      server: server,
      engine: engine,
      operationId: 'backup_destination_test',
      extraSettings: extraSettings,
      onEvent: _appendBackupLogEvent,
    );
  }
}
