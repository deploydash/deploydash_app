part of '../server_management_view.dart';

/// Maps a service workflow operation id to its analytics vocabulary.
///
/// One owner for the mapping: both service funnels look up the same table,
/// so a new operation id is one entry here, never a second switch. An
/// unknown future operation id maps to nothing and reports nothing until
/// it is added — never a free-form string.
const _serviceOperationActions = <String, ServiceAction>{
  'service_enable': ServiceAction.enable,
  'service_start': ServiceAction.start,
  'service_stop': ServiceAction.stop,
  'service_restart': ServiceAction.restart,
  'service_configure': ServiceAction.configure,
  'service_delete': ServiceAction.delete,
  'service_migrate_storage': ServiceAction.migrateStorage,
  'service_remove_legacy_storage': ServiceAction.removeLegacyStorage,
  'service_upgrade_major': ServiceAction.upgradeMajor,
};

extension _ServicesTabActions on _ServicesTabState {
  bool _requiresStateRevalidation(String operationId) {
    return switch (operationId) {
      'service_start' => true,
      'service_stop' => true,
      'service_restart' => true,
      'service_delete' => true,
      _ => false,
    };
  }

  Future<_ServiceActionPrecheck> _revalidateWebActionState({
    required String operationId,
    required Map<String, dynamic> connection,
  }) async {
    if (!_requiresStateRevalidation(operationId)) {
      return const _ServiceActionPrecheck.allowed();
    }
    final sshService = ref.read(sshServiceProvider);
    final response = await sshService.runWorkflow(
      workflowId: 'http',
      operationId: 'service_status',
      connection: connection,
      params: const <String, dynamic>{'dry_run': false},
    );
    final Map<String, dynamic> result;
    switch (response) {
      case Ok<Map<String, dynamic>>(:final value):
        result = value;
      case Err<Map<String, dynamic>>():
        // The action itself reports an engine failure; do not fabricate a
        // stale status precondition from an error envelope.
        return const _ServiceActionPrecheck.allowed();
    }
    final status = result['service_status'];
    final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(status);
    final running = runtimeStatus.isProcessActive;
    _patchService(
      'proxy',
      (service) => service.copyWith(status: runtimeStatus),
    );
    if (operationId == 'service_start' && running) {
      return const _ServiceActionPrecheck.blocked(
        'Web server is already running (revalidated).',
      );
    }
    if (operationId == 'service_stop' && !running) {
      return const _ServiceActionPrecheck.blocked(
        'Web server is already stopped (revalidated).',
      );
    }
    if (operationId == 'service_restart' && !running) {
      return const _ServiceActionPrecheck.blocked(
        'Web server is stopped; start it instead of restart.',
      );
    }
    return const _ServiceActionPrecheck.allowed();
  }

  Future<_ServiceActionPrecheck> _revalidateDatabaseActionState({
    required String operationId,
    required Server server,
    required Map<String, dynamic> connection,
    Map<String, dynamic>? settings,
  }) async {
    if (!_requiresStateRevalidation(operationId)) {
      return const _ServiceActionPrecheck.allowed();
    }
    final sshService = ref.read(sshServiceProvider);
    final response = await sshService.runWorkflow(
      workflowId: 'postgres',
      operationId: 'service_status',
      connection: connection,
      params: <String, dynamic>{
        'dry_run': false,
        ...?settings == null
            ? null
            : <String, dynamic>{
                'settings': {
                  ...settings,
                  'expected_databases': await _postgresExpectedDatabases(
                    server,
                  ),
                },
              },
      },
    );
    final Map<String, dynamic> result;
    switch (response) {
      case Ok<Map<String, dynamic>>(:final value):
        result = value;
      case Err<Map<String, dynamic>>():
        // The action itself reports an engine failure; do not fabricate a
        // stale status precondition from an error envelope.
        return const _ServiceActionPrecheck.allowed();
    }
    final status = result['service_status'];
    final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(status);
    final running = runtimeStatus.isProcessActive;
    final configured = status is Map && status['configured'] == true;
    _patchService(
      'database',
      (service) =>
          service.copyWith(isProvisioned: configured, status: runtimeStatus),
    );
    // coverage-gate: postgres_storage_status_revalidate
    _applyState(() {
      _postgresStorageStatus = PostgresStorageStatus.fromServiceStatus(status);
    });
    // end coverage-gate

    if (operationId == 'service_start' && running) {
      return const _ServiceActionPrecheck.blocked(
        'Database service is already running (revalidated).',
      );
    }
    if (operationId == 'service_stop' && !running) {
      return const _ServiceActionPrecheck.blocked(
        'Database service is already stopped (revalidated).',
      );
    }
    if (operationId == 'service_restart' && !running) {
      return const _ServiceActionPrecheck.blocked(
        'Database service is stopped; start it instead of restart.',
      );
    }
    if (operationId == 'service_delete' && !configured) {
      return const _ServiceActionPrecheck.blocked(
        'Database service is not configured anymore.',
      );
    }
    return const _ServiceActionPrecheck.allowed();
  }

  /// Reports one service action resolving, skipping unknown operation ids.
  ///
  /// Called at each funnel resolve point: the outcome is known there, while
  /// precheck blocks, validation rejects, and stale runs return before any
  /// report.
  void _reportServiceEvent(String operationId, DataOperationOutcome outcome) {
    final action = _serviceOperationActions[operationId];
    if (action == null) {
      return;
    }
    ref
        .read(appAnalyticsServiceProvider)
        .trackServiceEvent(action: action, outcome: outcome);
  }

  Future<bool> _runWebServerAction({
    required String operationId,
    required ContainerRuntimeStatus statusAfterSuccess,
    Map<String, dynamic>? settings,
    String? showSuccessMessage,
  }) async {
    final server = widget.server;
    if (server == null) {
      _showServiceMessage('Select a server before managing services.');
      return false;
    }
    final run = captureServerRun(
      server: server,
      kind: _ServicesTabState._webActionRunKind,
      metadata: <String, Object?>{'operationId': operationId},
    );

    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      _showServiceMessage(servicesCredentialsRequiredMessage());
      return false;
    }

    final webPrecheck = await _revalidateWebActionState(
      operationId: operationId,
      connection: connection,
    );
    if (!webPrecheck.allowed) {
      _showServiceMessage(webPrecheck.message);
      return false;
    }

    final previousService = _serviceById('proxy');
    _patchService(
      'proxy',
      (service) => service.copyWith(
        isProvisioned: service.isProvisioned || operationId == 'service_enable',
        status: const ContainerRuntimeStatus.provisioning(),
        isBusy: true,
      ),
    );

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'http',
        operationId: operationId,
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          ...?settings == null ? null : <String, dynamic>{'settings': settings},
        },
        onEvent: _appendServiceLogEvent,
      )).diagnosticPayload;

      if (!isCurrentServerRun(run)) {
        return false;
      }

      if (result['status'] == 'success') {
        final successMessage =
            showSuccessMessage ??
            result['msg']?.toString() ??
            'Operation completed.';
        _patchService(
          'proxy',
          (service) => service.copyWith(
            isProvisioned:
                service.isProvisioned || operationId == 'service_enable',
            status: statusAfterSuccess,
            isBusy: false,
          ),
        );
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Web server • ${_serviceOperationLabel(operationId)}',
            details: 'Completed',
            message: successMessage,
            level: _ServiceActivityLevel.success,
          ),
          refreshHistory: true,
        );
        _showServiceMessage(successMessage);
        _reportServiceEvent(operationId, DataOperationOutcome.success);
        return true;
      }

      final failureMessage = result['msg']?.toString().trim().isNotEmpty == true
          ? result['msg'].toString().trim()
          : 'Operation failed.';
      _patchService(
        'proxy',
        (service) => service.copyWith(
          isProvisioned:
              previousService?.isProvisioned ?? service.isProvisioned,
          status:
              previousService?.status ?? const ContainerRuntimeStatus.stopped(),
          isBusy: false,
        ),
      );
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Web server • ${_serviceOperationLabel(operationId)}',
          details: 'Failed',
          message: failureMessage,
          level: _ServiceActivityLevel.error,
        ),
        refreshHistory: true,
      );
      _showServiceMessage(failureMessage);
      _reportServiceEvent(operationId, DataOperationOutcome.failure);
      return false;
    } catch (error) {
      if (!isCurrentServerRun(run)) {
        return false;
      }
      _patchService(
        'proxy',
        (service) => service.copyWith(
          isProvisioned:
              previousService?.isProvisioned ?? service.isProvisioned,
          status:
              previousService?.status ?? const ContainerRuntimeStatus.stopped(),
          isBusy: false,
        ),
      );
      final message = 'Web server action failed: $error';
      _reportServiceEvent(operationId, DataOperationOutcome.failure);
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Web server • ${_serviceOperationLabel(operationId)}',
          details: 'Failed',
          message: message,
          level: _ServiceActivityLevel.error,
        ),
        refreshHistory: true,
      );
      _showServiceMessage(message);
      return false;
    } finally {
      if (isCurrentServerRun(run)) {
        await _refreshWebServerStatus();
      }
    }
  }

  Future<bool> _runDatabaseAction({
    required String operationId,
    ContainerRuntimeStatus? statusAfterSuccess,
    Map<String, dynamic>? settings,
    String? showSuccessMessage,
  }) async {
    final server = widget.server;
    if (server == null) {
      _showServiceMessage('Select a server before managing services.');
      return false;
    }
    final run = captureServerRun(
      server: server,
      kind: _ServicesTabState._databaseActionRunKind,
      metadata: <String, Object?>{'operationId': operationId},
    );

    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      _showServiceMessage(servicesCredentialsRequiredMessage());
      return false;
    }

    final databasePrecheck = await _revalidateDatabaseActionState(
      operationId: operationId,
      server: server,
      connection: connection,
      settings: settings,
    );
    if (!databasePrecheck.allowed) {
      _showServiceMessage(databasePrecheck.message);
      return false;
    }

    final previousService = _serviceById('database');
    _patchService(
      'database',
      (service) => service.copyWith(
        isProvisioned: service.isProvisioned,
        status: const ContainerRuntimeStatus.provisioning(),
        isBusy: true,
      ),
    );

    // The detachment fallback needs the desktop's known databases on the
    // storage and upgrade operations; other operations ignore the key.
    final effectiveSettings =
        operationId == 'service_migrate_storage' ||
            operationId == 'service_remove_legacy_storage' ||
            operationId == 'service_upgrade_major'
        ? <String, dynamic>{
            ...?settings,
            'expected_databases': await _postgresExpectedDatabases(server),
          }
        : settings;

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'postgres',
        operationId: operationId,
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          ...?effectiveSettings == null
              ? null
              : <String, dynamic>{'settings': effectiveSettings},
        },
        onEvent: _appendServiceLogEvent,
      )).diagnosticPayload;

      if (!isCurrentServerRun(run)) {
        return false;
      }

      if (result['status'] == 'success') {
        if (operationId == 'service_enable' ||
            operationId == 'service_delete') {
          await _syncDatabaseServiceEnabled(operationId == 'service_enable');
          if (!isCurrentServerRun(run)) {
            return true;
          }
        }
        final successMessage =
            showSuccessMessage ??
            result['msg']?.toString() ??
            'Operation completed.';
        _patchService(
          'database',
          (service) => service.copyWith(
            isProvisioned: operationId == 'service_delete'
                ? false
                : (service.isProvisioned ||
                      operationId == 'service_enable' ||
                      operationId == 'service_configure'),
            // A null expectation keeps the current status: removal never
            // touches the container, so there is no new state to claim.
            status: statusAfterSuccess ?? service.status,
            isBusy: false,
          ),
        );
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Database • ${_serviceOperationLabel(operationId)}',
            details: 'Completed',
            message: successMessage,
            level: _ServiceActivityLevel.success,
          ),
          refreshHistory: true,
        );
        _showServiceMessage(successMessage);
        _reportServiceEvent(operationId, DataOperationOutcome.success);
        return true;
      }

      final failureMessage = result['msg']?.toString().trim().isNotEmpty == true
          ? result['msg'].toString().trim()
          : 'Operation failed.';
      _appendServiceLogEvent(<String, dynamic>{
        'type': 'operation_error',
        'level': 'error',
        'message': failureMessage,
      });
      final failureDetails =
          result['details']?.toString().trim().isNotEmpty == true
          ? result['details'].toString().trim()
          : null;
      if (failureDetails != null) {
        _appendServiceLogEvent(<String, dynamic>{
          'type': 'operation_error_details',
          'level': 'error',
          'message': failureDetails,
        });
      }
      _patchService(
        'database',
        (service) => service.copyWith(
          isProvisioned:
              previousService?.isProvisioned ?? service.isProvisioned,
          status:
              previousService?.status ?? const ContainerRuntimeStatus.stopped(),
          isBusy: false,
        ),
      );
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Database • ${_serviceOperationLabel(operationId)}',
          details: 'Failed',
          message: failureMessage,
          level: _ServiceActivityLevel.error,
        ),
        refreshHistory: true,
      );
      _showServiceMessage(failureMessage);
      _reportServiceEvent(operationId, DataOperationOutcome.failure);
      return false;
    } catch (error) {
      if (!isCurrentServerRun(run)) {
        return false;
      }
      _appendServiceLogEvent(<String, dynamic>{
        'type': 'operation_exception',
        'level': 'error',
        'message': 'Database action failed: $error',
      });
      _patchService(
        'database',
        (service) => service.copyWith(
          isProvisioned:
              previousService?.isProvisioned ?? service.isProvisioned,
          status:
              previousService?.status ?? const ContainerRuntimeStatus.stopped(),
          isBusy: false,
        ),
      );
      final message = 'Database action failed: $error';
      _reportServiceEvent(operationId, DataOperationOutcome.failure);
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Database • ${_serviceOperationLabel(operationId)}',
          details: 'Failed',
          message: message,
          level: _ServiceActivityLevel.error,
        ),
        refreshHistory: true,
      );
      _showServiceMessage(message);
      return false;
    } finally {
      if (isCurrentServerRun(run)) {
        await _refreshDatabaseStatus();
      }
    }
  }

  // coverage-gate: postgres_service_delete_policy_catalog
  Future<void> _deleteDatabaseService() async {
    final confirmed = await _showDeleteDatabaseConfirmationDialog(context);
    if (!confirmed) {
      return;
    }

    final removed = await _runDatabaseAction(
      operationId: 'service_delete',
      statusAfterSuccess: const ContainerRuntimeStatus.notConfigured(),
      settings: buildPostgresServiceSettings(_postgresConfig),
      showSuccessMessage: 'Database service deleted.',
    );
    if (!removed) {
      return;
    }
    await ref
        .read(projectBackupProvider.notifier)
        .deletePoliciesForServer(widget.server!.id);
  }
  // end coverage-gate

  // coverage-gate: postgres_expected_databases
  /// The managed database names this desktop knows on [server], sorted.
  ///
  /// Feeds the detachment fallback: the ownership registry travels with
  /// the data, so only the desktop can tell a fresh cluster from a
  /// detached one. A failing local read yields no expectations rather
  /// than breaking status, so storage keeps working when the app
  /// database is unavailable.
  Future<List<String>> _postgresExpectedDatabases(Server server) async {
    try {
      final projects = await ref
          .read(projectRepositoryProvider)
          .listProjects(serverId: server.id);
      if (projects.isEmpty) {
        return const [];
      }
      final repository = ref.read(projectManagedDatabaseRepositoryProvider);
      final names = <String>{};
      for (final project in projects) {
        final databases = await repository.listDatabasesForScope(
          projectId: project.id,
          serverId: server.id,
        );
        names.addAll(databases.map((database) => database.databaseName));
      }
      return names.toList()..sort();
    } on Object catch (error) {
      debugPrint('Postgres expectations read failed: $error');
      return const [];
    }
  }
  // end coverage-gate

  // coverage-gate: postgres_storage_migrate_action
  Future<void> _migratePostgresStorage() async {
    final confirmed = await _showMigratePostgresStorageDialog(context);
    if (!confirmed) {
      return;
    }
    await _runDatabaseAction(
      operationId: 'service_migrate_storage',
      statusAfterSuccess: const ContainerRuntimeStatus.ready(),
      settings: buildPostgresServiceSettings(_postgresConfig),
      showSuccessMessage: 'Database storage migrated.',
    );
  }
  // end coverage-gate

  // coverage-gate: postgres_major_upgrade_action
  /// Moves the database to the major version the upgrade flow returned.
  ///
  /// The local version flips only after the engine reports success: a
  /// failed upgrade leaves the cluster on the old volume, so persisting
  /// the target first would strand the desktop ahead of the server.
  Future<void> _upgradePostgresMajor(ServerPostgresConfig target) async {
    final upgraded = await _runDatabaseAction(
      operationId: 'service_upgrade_major',
      statusAfterSuccess: const ContainerRuntimeStatus.ready(),
      settings: buildPostgresServiceSettings(target),
      showSuccessMessage: postgresUpgradeSuccessMessage(target.postgresVersion),
    );
    if (!upgraded) {
      return;
    }
    final persistedConfig = await _persistPostgresConfigWithPassword(target);
    _postgresConfig = persistedConfig;
  }
  // end coverage-gate

  // coverage-gate: postgres_storage_remove_action
  /// Removes one dangling anonymous volume from the old-copies list.
  ///
  /// The engine removes exactly the volume named in the settings, so every
  /// row dispatches its own volume rather than sharing one ambiguous
  /// button: with several candidates, "the old copy" names nothing.
  Future<void> _removePostgresDetachedVolume(String volume) async {
    await _removePostgresOldCopy(
      volume,
      serviceName: 'old database copy',
      warning: postgresStorageRemoveDialogWarning(),
      acknowledgeLabel: postgresStorageRemoveDialogAcknowledge(),
      showSuccessMessage: 'Old database copy removed.',
    );
  }

  /// Removes one kept pre-upgrade copy from the retained list.
  ///
  /// Same engine operation as the dangling-volume removal, with the
  /// pre-upgrade copy texts: the ledger names the volume, the dialog
  /// confirms its destruction, and only an explicit confirmation removes
  /// the rollback data.
  Future<void> _removePostgresRetainedVolume(String volume) async {
    await _removePostgresOldCopy(
      volume,
      serviceName: 'pre-upgrade database copy',
      warning: postgresUpgradeRemoveDialogWarning(),
      acknowledgeLabel: postgresUpgradeRemoveDialogAcknowledge(),
      showSuccessMessage: postgresUpgradeRemoveSuccessMessage(),
    );
  }

  /// Removes one ledger-attributed directory without deleting its live volume.
  Future<void> _removePostgresRetainedStorageSubpath(
    PostgresRetainedStorageSubpath retained,
  ) async {
    await _removePostgresOldCopy(
      retained.volume,
      subpath: retained.subpath,
      serviceName: 'storage-migration database copy',
      warning: postgresStorageRemoveDialogWarning(),
      acknowledgeLabel: postgresStorageRemoveDialogAcknowledge(),
      showSuccessMessage: 'Old database copy removed.',
    );
  }

  /// Confirms and removes one explicitly named old data copy.
  Future<void> _removePostgresOldCopy(
    String volume, {
    String? subpath,
    required String serviceName,
    required String warning,
    required String acknowledgeLabel,
    required String showSuccessMessage,
  }) async {
    final confirmed = await _showDeleteServiceConfirmationDialog(
      context: context,
      serviceName: serviceName,
      warning: warning,
      acknowledgeLabel: acknowledgeLabel,
      dialogKey: const Key('service-remove-storage-dialog'),
    );
    if (!confirmed) {
      return;
    }
    await _runDatabaseAction(
      operationId: 'service_remove_legacy_storage',
      statusAfterSuccess: null,
      settings: <String, dynamic>{
        ...buildPostgresServiceSettings(_postgresConfig),
        'legacy_storage_volume': volume,
        'legacy_storage_subpath': ?subpath,
      },
      showSuccessMessage: showSuccessMessage,
    );
  }
  // end coverage-gate

  Future<void> _syncDatabaseServiceEnabled(bool enabled) async {
    final widgetServer = widget.server;
    if (widgetServer == null) {
      return;
    }
    final catalogServer = ref.read(serverCatalogProvider).selectedServer;
    if (catalogServer == null || catalogServer.id != widgetServer.id) {
      return;
    }
    if (catalogServer.serviceDatabaseEnabled == enabled) {
      return;
    }
    await ref
        .read(serverCatalogProvider.notifier)
        .updateSelectedServerServices(
          enableDatabases: enabled,
          enableEmailAccounts: catalogServer.serviceEmailEnabled,
          enableDomains: catalogServer.serviceDomainEnabled,
        );
  }

  Future<ServerPostgresConfig> _persistPostgresConfigWithPassword(
    ServerPostgresConfig config,
  ) async {
    final password =
        trimOrNull(config.superuserPassword) ??
        generatePostgresServicePassword();
    final normalizedExtensions =
        config.enabledExtensions
            .where(ServerPostgresConfig.supportedExtensions.contains)
            .toSet()
            .toList()
          ..sort((left, right) => left.compareTo(right));
    final normalized = ServerPostgresConfig(
      postgresVersion: config.postgresVersion,
      superuserPassword: password,
      enabledExtensions: normalizedExtensions,
    );
    await ref
        .read(serverCatalogProvider.notifier)
        .updateSelectedServerPostgresConfig(normalized);
    return normalized;
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  Map<String, dynamic> _buildWebServerSettings(ServerWebServerConfig config) {
    final hostname = _defaultHostnameForServer(widget.server);
    return <String, dynamic>{
      'default_hostname': hostname,
      'server_ip': null,
      'default_page_title': 'Deploy Dash HTTP gateway is online',
      'default_page_message':
          'Caddy is running and ready to proxy Django/Laravel/Rails/Next.js '
          'apps.',
      'serve_ip_over_https': true,
      'enable_https_redirect': config.enableHttpsRedirect,
      'enable_response_compression': config.enableCompression,
      'enable_access_logs': config.enableAccessLogs,
      'enable_on_demand_tls': false,
      'on_demand_tls_ask_endpoint': null,
      'enable_dns_plugin_cloudflare': config.enableDnsPluginCloudflare,
      'enable_dns_plugin_porkbun': config.enableDnsPluginPorkbun,
      'enable_dns_plugin_namecheap': config.enableDnsPluginNamecheap,
      'enable_dns_plugin_cloudns': config.enableDnsPluginCloudns,
      'enable_dns_plugin_easydns': config.enableDnsPluginEasydns,
    };
  }

  Map<String, dynamic> _buildFirewallSettingsForServices(
    ServerFirewallConfig config,
  ) {
    return <String, dynamic>{
      ...config.toJsonMap(),
      'locked_ports': _lockedFirewallPortsForServer(),
    };
  }

  Map<String, dynamic> _buildTemporaryPostgresFirewallSettings(
    ServerFirewallConfig config,
    List<String> sourceCidrs,
  ) {
    // coverage-gate: postgres_remote_access_source_settings
    return <String, dynamic>{
      ..._buildFirewallSettingsForServices(
        ServerFirewallConfig(
          strictMode: config.strictMode,
          allowPostgres: true,
          allowDns: config.allowDns,
          allowSmtp: config.allowSmtp,
          allowMailReceive: config.allowMailReceive,
          rollbackTimeoutSeconds:
              _ServicesTabState._temporaryPostgresRemoteAccessSeconds,
          customRules: config.customRules,
        ),
      ),
      'postgres_source_cidrs': sourceCidrs,
    };
    // end coverage-gate
  }

  List<int> _lockedFirewallPortsForServer() {
    return lockedPortsForSshPort(widget.server?.port ?? 22);
  }

  _FirewallStagedState? _parseStagedFirewallState(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final token = raw['token']?.toString().trim();
    if (token == null || token.isEmpty) {
      return null;
    }
    final expiresAtRaw = raw['expires_at']?.toString().trim();
    DateTime? expiresAt;
    if (expiresAtRaw != null && expiresAtRaw.isNotEmpty) {
      expiresAt = DateTime.tryParse(expiresAtRaw)?.toLocal();
    }
    return _FirewallStagedState(token: token, expiresAt: expiresAt);
  }

  bool _readAllowPostgresFromStagedState(dynamic raw) {
    if (raw is! Map) {
      return false;
    }
    final value = raw['allow_postgres'];
    if (value is bool) {
      return value;
    }
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized == '1' || normalized == 'true';
    }
    return false;
  }

  /// Reads the exact client networks that the staged firewall currently trusts.
  List<String> _readPostgresSourceCidrsFromStagedState(dynamic raw) {
    if (raw is! Map) {
      return const <String>[];
    }
    final values = raw['postgres_source_cidrs'];
    if (values is! List) {
      return const <String>[];
    }
    return values
        .map((value) => value.toString().trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  String _formatServicesDateTime(DateTime value) {
    String twoDigits(int raw) => raw.toString().padLeft(2, '0');
    final year = value.year.toString().padLeft(4, '0');
    final month = twoDigits(value.month);
    final day = twoDigits(value.day);
    final hour = twoDigits(value.hour);
    final minute = twoDigits(value.minute);
    final second = twoDigits(value.second);
    return '$year-$month-$day $hour:$minute:$second';
  }

  String _defaultHostnameForServer(Server? server) {
    final host = server?.host.trim().toLowerCase() ?? '';
    if (host.isEmpty) {
      return 'localhost';
    }
    final isIpv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host);
    if (host == 'localhost' || (!isIpv4 && host.contains('.'))) {
      return host;
    }
    return 'localhost';
  }

  void _showServiceMessage(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty || !mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(trimmed)));
  }

  void _appendServiceLogEvent(Map<String, dynamic> event) {
    final message = event['message']?.toString() ?? '';
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final type = (event['type']?.toString() ?? '').toLowerCase();
    final isDetail = serviceDetailEventTypes.contains(type);
    final source = type.startsWith('pyinfra') ? 'pyinfra' : 'engine';
    widget.onTerminalLine?.call(
      trimmed,
      detail: isDetail,
      source: source,
      taskType: 'server_services',
    );
  }

  _ServiceActionControlState _buildActionControlState(
    _ServerServiceRecord service,
  ) {
    if (!_supportsRuntimeManagement(service.id)) {
      return _ServiceActionControlState(
        startStopEnabled: false,
        restartEnabled: false,
        configureEnabled: false,
        deleteEnabled: false,
        startStopBlockedReason: servicesUnsupportedEnableReason(),
        restartBlockedReason: servicesUnsupportedEnableReason(),
        configureBlockedReason: servicesUnsupportedEnableReason(),
        deleteBlockedReason: servicesUnsupportedEnableReason(),
      );
    }

    final startStopOperationId = service.status.isProcessActive
        ? 'service_stop'
        : 'service_start';
    final startStopConflict = _evaluateServiceConflict(
      serviceId: service.id,
      operationId: startStopOperationId,
    );
    final restartConflict = _evaluateServiceConflict(
      serviceId: service.id,
      operationId: 'service_restart',
    );
    final configureConflict = _evaluateServiceConflict(
      serviceId: service.id,
      operationId: 'service_configure',
      settings: switch (service.id) {
        'database' => buildPostgresServiceSettings(_postgresConfig),
        _ => _buildWebServerSettings(_webServerConfig),
      },
    );
    final deleteConflict = service.id == 'database'
        ? _evaluateServiceConflict(
            serviceId: service.id,
            operationId: 'service_delete',
            settings: buildPostgresServiceSettings(_postgresConfig),
          )
        : null;

    final startStopEnabled = !_isBlockedConflict(startStopConflict);
    final restartEnabled = !_isBlockedConflict(restartConflict);
    final configureEnabled = !_isBlockedConflict(configureConflict);
    final startStopBlockedReason = _formatConflictReason(startStopConflict);
    final restartBlockedReason = _formatConflictReason(restartConflict);
    final configureBlockedReason = _formatConflictReason(configureConflict);

    return _ServiceActionControlState(
      startStopEnabled: startStopEnabled,
      restartEnabled: restartEnabled,
      configureEnabled: configureEnabled,
      deleteEnabled: !_isBlockedConflict(deleteConflict),
      startStopBlockedReason: startStopBlockedReason,
      restartBlockedReason: restartBlockedReason,
      configureBlockedReason: configureBlockedReason,
      deleteBlockedReason: _formatConflictReason(deleteConflict),
    );
  }

  bool _supportsRuntimeManagement(String serviceId) {
    return serviceId == 'proxy' || serviceId == 'database';
  }

  bool _isBlockedConflict(OperationConflictEvaluation? evaluation) {
    return evaluation?.isBlocked == true;
  }

  String? _formatConflictReason(OperationConflictEvaluation? evaluation) {
    if (evaluation == null || !evaluation.isBlocked) {
      return null;
    }
    final segments = <String>[evaluation.message.trim()];
    if (evaluation.blockingOperationIds.isNotEmpty) {
      segments.add('Blocked by ${evaluation.blockingOperationIds.join(', ')}.');
    }
    if (evaluation.blockingResources.isNotEmpty) {
      segments.add('Resource: ${evaluation.blockingResources.join(', ')}.');
    }
    return segments.where((segment) => segment.isNotEmpty).join(' ');
  }

  OperationConflictEvaluation? _evaluateServiceConflict({
    required String serviceId,
    required String operationId,
    Map<String, dynamic>? settings,
  }) {
    final server = widget.server;
    if (server == null) {
      return null;
    }
    final workflowId = switch (serviceId) {
      'proxy' => 'http',
      'database' => 'postgres',
      _ => null,
    };
    if (workflowId == null) {
      return null;
    }
    // Conflict evaluation is local and keys only on the target host. It is
    // not an engine dispatch, so it must not materialize a credential payload.
    final connection = <String, dynamic>{
      'host': server.host,
      'port': server.port,
      'username': server.sshUser,
    };
    final params = <String, dynamic>{
      'dry_run': false,
      ...?settings == null ? null : <String, dynamic>{'settings': settings},
    };
    return ref
        .read(sshServiceProvider)
        .evaluateWorkflowConflict(
          workflowId: workflowId,
          operationId: operationId,
          connection: connection,
          params: params,
        );
  }
}
