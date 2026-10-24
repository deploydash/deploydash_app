part of '../server_management_view.dart';

class _ServicesTab extends ConsumerStatefulWidget {
  const _ServicesTab(this.server, {this.onTerminalLine});

  final Server? server;
  final ServerTerminalLineWriter? onTerminalLine;

  @override
  ConsumerState<_ServicesTab> createState() => _ServicesTabState();
}

class _ServicesTabState extends ConsumerState<_ServicesTab>
    with ServerScopedConsumerState<_ServicesTab> {
  static const int _maxRecentServiceActivities = 5;
  static const int _temporaryPostgresRemoteAccessSeconds = 3600;
  static const String _webStatusRunKind = 'web_status_refresh';
  static const String _databaseStatusRunKind = 'postgres_status_refresh';
  static const String _postgresRemoteAccessRunKind =
      'postgres_remote_access_refresh';
  static const String _webActionRunKind = 'web_service_action';
  static const String _databaseActionRunKind = 'postgres_service_action';
  late List<_ServerServiceRecord> _services;
  final List<_ServiceActivityEntry> _recentServiceActivity =
      <_ServiceActivityEntry>[];
  List<OperationQueueSnapshot> _operationQueue = <OperationQueueSnapshot>[];
  StreamSubscription<List<OperationQueueSnapshot>>? _queueSubscription;
  ServerWebServerConfig _webServerConfig = ServerWebServerConfig.defaults;
  ServerPostgresConfig _postgresConfig = ServerPostgresConfig.defaults;
  _FirewallStagedState? _postgresRemoteAccessStagedState;
  PostgresStorageStatus _postgresStorageStatus = const PostgresStorageStatus();
  // coverage-gate: postgres_remote_access_security_fields
  bool _postgresRemoteAccessAllowsPostgres = false;
  List<String> _postgresRemoteAccessSourceCidrs = const <String>[];
  String? _postgresRemoteAccessDetectedAddress;
  bool _postgresTlsEnabled = false;
  String? _postgresTlsCaFingerprint;
  String? _postgresTlsCaCertificate;
  bool _isRefreshingPostgresRemoteAccess = false;
  bool _isMutatingPostgresRemoteAccess = false;
  String? _postgresRemoteAccessError;
  // end coverage-gate

  @override
  void initState() {
    super.initState();
    bindServerScope(widget.server);
    _webServerConfig =
        widget.server?.webServerConfig ?? ServerWebServerConfig.defaults;
    _postgresConfig =
        widget.server?.postgresConfig ?? ServerPostgresConfig.defaults;
    _services = _buildInitialServices(widget.server);
    _bindOperationCenterStreams();
    unawaited(_loadRecentServiceActivity());
    unawaited(_refreshWebServerStatus());
    unawaited(_refreshDatabaseStatus());
    unawaited(_refreshPostgresRemoteAccessStatus(quiet: true));
  }

  @override
  void didUpdateWidget(covariant _ServicesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousServerId = oldWidget.server?.id;
    final currentServerId = widget.server?.id;
    if (previousServerId != currentServerId) {
      bindServerScope(widget.server);
      _webServerConfig =
          widget.server?.webServerConfig ?? ServerWebServerConfig.defaults;
      _postgresConfig =
          widget.server?.postgresConfig ?? ServerPostgresConfig.defaults;
      _services = _buildInitialServices(widget.server);
      _postgresRemoteAccessStagedState = null;
      _postgresStorageStatus = const PostgresStorageStatus();
      // coverage-gate: postgres_remote_access_security_reset
      _postgresRemoteAccessAllowsPostgres = false;
      _postgresRemoteAccessSourceCidrs = const <String>[];
      _postgresRemoteAccessDetectedAddress = null;
      _postgresTlsEnabled = false;
      _postgresTlsCaFingerprint = null;
      _postgresTlsCaCertificate = null;
      _isRefreshingPostgresRemoteAccess = false;
      _isMutatingPostgresRemoteAccess = false;
      _postgresRemoteAccessError = null;
      // end coverage-gate
      _recentServiceActivity.clear();
      _bindOperationCenterStreams();
      unawaited(_loadRecentServiceActivity());
      unawaited(_refreshWebServerStatus());
      unawaited(_refreshDatabaseStatus());
      unawaited(_refreshPostgresRemoteAccessStatus(quiet: true));
    }
  }

  @override
  void dispose() {
    _queueSubscription?.cancel();
    super.dispose();
  }

  void _applyState(VoidCallback update) {
    setState(update);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final operationCenterSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_operationQueue.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              AppStatusBadge(
                icon: Icons.pending_actions,
                label:
                    '${_operationQueue.where((entry) => entry.state == OperationQueueState.queued).length} waiting',
                tone: AppStatusTone.warning,
              ),
              AppStatusBadge(
                icon: Icons.play_circle_outline,
                label:
                    '${_operationQueue.where((entry) => entry.state != OperationQueueState.queued).length} in progress',
                tone: AppStatusTone.info,
              ),
              if (_operationQueue.any((entry) => entry.isStale))
                AppStatusBadge(
                  icon: Icons.hourglass_disabled_outlined,
                  label:
                      '${_operationQueue.where((entry) => entry.isStale).length} stalled',
                  tone: AppStatusTone.warning,
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Container(
          key: const Key('services-operation-center'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
          child: _operationQueue.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No changes are waiting or running right now.'),
                )
              : Column(
                  children: [
                    for (int i = 0; i < _operationQueue.length; i += 1) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.circle,
                              size: 12,
                              color: operationStateColor(
                                _operationQueue[i].state,
                                orange: YaruColors.orange,
                                theme: theme,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_activeOperationTitle(_operationQueue[i])} • '
                                    '${operationStateLabel(_operationQueue[i].state)}',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'This service change is '
                                    '${operationStateLabel(_operationQueue[i].state).toLowerCase()}.',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  if (_operationQueue[i].isStale)
                                    Text(
                                      'This change looks stuck. Review it and '
                                      'cancel or retry it manually if needed.',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.error,
                                          ),
                                    ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _operationTimestampText(_operationQueue[i]),
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.textTheme.bodySmall?.color
                                          ?.withValues(alpha: 0.75),
                                    ),
                                  ),
                                  if (_operationQueue[i].queuePosition != null)
                                    Text(
                                      'Waiting position: ${_operationQueue[i].queuePosition}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .textTheme
                                                .bodySmall
                                                ?.color
                                                ?.withValues(alpha: 0.75),
                                          ),
                                    ),
                                  if (_operationQueue[i]
                                      .blockingResources
                                      .isNotEmpty)
                                    Text(
                                      'Waiting on: ${_operationQueue[i].blockingResources.join(', ')}',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .textTheme
                                                .bodySmall
                                                ?.color
                                                ?.withValues(alpha: 0.75),
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            if (ref
                                .read(sshServiceProvider)
                                .canCancelOperation(
                                  _operationQueue[i].operationInstanceId,
                                ))
                              TextButton(
                                onPressed: () => unawaited(
                                  _cancelOperationQueueEntry(
                                    _operationQueue[i].operationInstanceId,
                                  ),
                                ),
                                child: const Text('Cancel'),
                              ),
                          ],
                        ),
                      ),
                      if (i < _operationQueue.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.dividerColor.withValues(alpha: 0.35),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
    final recentActivitySection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const Key('services-recent-activity'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
          child: _recentServiceActivity.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No recent service activity yet.'),
                )
              : Column(
                  children: [
                    for (
                      int i = 0;
                      i < _recentServiceActivity.length;
                      i += 1
                    ) ...[
                      _ServiceActivityRow(activity: _recentServiceActivity[i]),
                      if (i < _recentServiceActivity.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.dividerColor.withValues(alpha: 0.35),
                        ),
                    ],
                  ],
                ),
        ),
      ],
    );
    return ListView(
      key: const Key('server-management-services-tab'),
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            AppStatusBadge(
              icon: Icons.check_circle,
              label: '$_runningServices ready',
              tone: AppStatusTone.positive,
            ),
            AppStatusBadge(
              icon: Icons.pause_circle_outline,
              label: '$_stoppedServices stopped',
              tone: AppStatusTone.warning,
            ),
            AppStatusBadge(
              icon: Icons.sync,
              label: '$_provisioningServices in progress',
              tone: AppStatusTone.info,
            ),
          ],
        ),
        const SizedBox(height: 18),
        AppWorkspaceSection(
          title: servicesAvailableHeading(),
          subtitle: 'Enable only the services this server needs.',
          child: _availableServices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('All available services are already enabled.'),
                )
              : Column(
                  children: [
                    for (int i = 0; i < _availableServices.length; i += 1) ...[
                      _ProvisionServiceRow(
                        service: _availableServices[i],
                        enableSupported: _supportsRuntimeManagement(
                          _availableServices[i].id,
                        ),
                        unsupportedReason: servicesUnsupportedEnableReason(),
                        onEnable: () =>
                            _enableService(_availableServices[i].id),
                      ),
                      if (i < _availableServices.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.dividerColor.withValues(alpha: 0.35),
                        ),
                    ],
                  ],
                ),
        ),
        AppWorkspaceSection(
          title: servicesEnabledHeading(),
          subtitle: 'Review service readiness and make explicit changes.',
          child: _enabledServices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('No services are enabled yet.'),
                )
              : Column(
                  children: [
                    for (int i = 0; i < _enabledServices.length; i += 1) ...[
                      _ManageServiceRow(
                        service: _enabledServices[i],
                        controlState: _buildActionControlState(
                          _enabledServices[i],
                        ),
                        footer: _enabledServices[i].id == 'database'
                            ? Column(
                                children: [
                                  _PostgresStorageFooter(
                                    service: _enabledServices[i],
                                    storage: _postgresStorageStatus,
                                    migrateConflictReason:
                                        _formatConflictReason(
                                          _evaluateServiceConflict(
                                            serviceId: 'database',
                                            operationId:
                                                'service_migrate_storage',
                                            settings:
                                                buildPostgresServiceSettings(
                                                  _postgresConfig,
                                                ),
                                          ),
                                        ),
                                    removeConflictReason: _formatConflictReason(
                                      _evaluateServiceConflict(
                                        serviceId: 'database',
                                        operationId:
                                            'service_remove_legacy_storage',
                                        settings: buildPostgresServiceSettings(
                                          _postgresConfig,
                                        ),
                                      ),
                                    ),
                                    onMigrate: () =>
                                        unawaited(_migratePostgresStorage()),
                                    onRemoveDetachedVolume: (volume) =>
                                        unawaited(
                                          _removePostgresDetachedVolume(volume),
                                        ),
                                    onRemoveRetainedVolume: (volume) =>
                                        unawaited(
                                          _removePostgresRetainedVolume(volume),
                                        ),
                                    onRemoveRetainedStorageSubpath:
                                        (retained) => unawaited(
                                          _removePostgresRetainedStorageSubpath(
                                            retained,
                                          ),
                                        ),
                                  ),
                                  const SizedBox(height: 10),
                                  _PostgresRemoteAccessFooter(
                                    service: _enabledServices[i],
                                    stagedState:
                                        _postgresRemoteAccessStagedState,
                                    allowsPostgres:
                                        _postgresRemoteAccessAllowsPostgres,
                                    sourceCidrs:
                                        _postgresRemoteAccessSourceCidrs,
                                    detectedAddress:
                                        _postgresRemoteAccessDetectedAddress,
                                    tlsEnabled: _postgresTlsEnabled,
                                    tlsCaFingerprint: _postgresTlsCaFingerprint,
                                    tlsCaCertificate: _postgresTlsCaCertificate,
                                    serverHost: widget.server?.host ?? '',
                                    isRefreshing:
                                        _isRefreshingPostgresRemoteAccess,
                                    isMutating: _isMutatingPostgresRemoteAccess,
                                    error: _postgresRemoteAccessError,
                                    onOpen: (sourceCidrs) => unawaited(
                                      _enableTemporaryPostgresRemoteAccess(
                                        sourceCidrs,
                                      ),
                                    ),
                                    onClose: () => unawaited(
                                      _closeTemporaryPostgresRemoteAccess(),
                                    ),
                                    onRefresh: () => unawaited(
                                      _refreshPostgresRemoteAccessStatus(),
                                    ),
                                    formatDateTime: _formatServicesDateTime,
                                  ),
                                ],
                              )
                            : null,
                        onStartStop: () =>
                            _toggleServiceState(_enabledServices[i].id),
                        onRestart: () =>
                            _restartService(_enabledServices[i].id),
                        onConfigure: () =>
                            _openConfigureModal(_enabledServices[i]),
                        onDelete: switch (_enabledServices[i].id) {
                          'database' => _deleteDatabaseService,
                          _ => null,
                        },
                      ),
                      if (i < _enabledServices.length - 1)
                        Divider(
                          height: 1,
                          thickness: 1,
                          color: theme.dividerColor.withValues(alpha: 0.35),
                        ),
                    ],
                  ],
                ),
        ),
        AppMasterDetail(
          master: AppWorkspaceSection(
            title: servicesOperationCenterHeading(),
            child: operationCenterSection,
          ),
          detail: AppWorkspaceSection(
            title: servicesRecentActivityHeading(),
            child: recentActivitySection,
          ),
          masterFlex: 1,
          detailFlex: 1,
        ),
      ],
    );
  }
}

class _ProvisionServiceRow extends StatelessWidget {
  const _ProvisionServiceRow({
    required this.service,
    required this.onEnable,
    this.enableSupported = true,
    this.unsupportedReason,
  });

  final _ServerServiceRecord service;
  final VoidCallback onEnable;
  final bool enableSupported;
  final String? unsupportedReason;

  @override
  Widget build(BuildContext context) {
    final isInstalling =
        service.isBusy ||
        service.status.effectiveStatus ==
            ContainerRuntimeEffectiveStatus.provisioning;
    // Hoisted so the `== null` check promotes it; a widget field is never
    // promoted.
    final unsupportedReason = this.unsupportedReason;
    return Padding(
      key: Key('service-available-${service.id}'),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(service.icon, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  service.name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  service.purpose,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          () {
            final button = FilledButton(
              key: Key('service-enable-${service.id}'),
              onPressed: isInstalling || !enableSupported ? null : onEnable,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isInstalling) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(isInstalling ? 'Installing...' : 'Enable'),
                ],
              ),
            );
            if (enableSupported || unsupportedReason == null) {
              return button;
            }
            return Tooltip(message: unsupportedReason, child: button);
          }(),
        ],
      ),
    );
  }
}

class _ManageServiceRow extends StatelessWidget {
  const _ManageServiceRow({
    required this.service,
    required this.controlState,
    required this.onStartStop,
    required this.onRestart,
    required this.onConfigure,
    this.footer,
    this.onDelete,
  });

  final _ServerServiceRecord service;
  final _ServiceActionControlState controlState;
  final VoidCallback onStartStop;
  final VoidCallback onRestart;
  final VoidCallback onConfigure;
  final Widget? footer;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final status = service.status;
    // Hoisted so the `!= null` check promotes it; a widget field is never
    // promoted.
    final footer = this.footer;
    final isUpdatingStatus =
        service.isBusy &&
        status.effectiveStatus != ContainerRuntimeEffectiveStatus.provisioning;
    final statusLabel = isUpdatingStatus ? 'Updating status' : status.label;
    final showSpinner =
        isUpdatingStatus ||
        status.effectiveStatus == ContainerRuntimeEffectiveStatus.provisioning;
    final startStopLabel = status.isProcessActive ? 'Stop' : 'Start';
    final startStopBlockedReason = !service.isBusy
        ? controlState.startStopBlockedReason
        : null;
    final restartBlockedReason = !service.isBusy
        ? controlState.restartBlockedReason
        : null;
    final configureBlockedReason = !service.isBusy
        ? controlState.configureBlockedReason
        : null;
    final deleteBlockedReason = !service.isBusy
        ? controlState.deleteBlockedReason
        : null;
    final blockedMessages = <String>{
      if (startStopBlockedReason != null)
        '$startStopLabel blocked: $startStopBlockedReason',
      if (restartBlockedReason != null)
        'Restart blocked: $restartBlockedReason',
      if (configureBlockedReason != null)
        'Configure blocked: $configureBlockedReason',
      if (deleteBlockedReason != null && onDelete != null)
        'Delete blocked: $deleteBlockedReason',
    }.toList(growable: false);

    Widget buildActionButton({
      required Key key,
      required String label,
      required VoidCallback? onPressed,
      String? disabledReason,
      ButtonStyle? style,
    }) {
      final button = OutlinedButton(
        key: key,
        onPressed: onPressed,
        style: style,
        child: Text(label),
      );
      if (disabledReason == null || disabledReason.trim().isEmpty) {
        return button;
      }
      return Tooltip(message: disabledReason, child: button);
    }

    return Padding(
      key: Key('service-row-${service.id}'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(service.icon, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      service.purpose,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              AppStatusBadge(
                label: statusLabel,
                tone: isUpdatingStatus
                    ? AppStatusTone.info
                    : appContainerRuntimeStatusTone(status.effectiveStatus),
                leading: showSpinner
                    ? const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.circle, size: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Ports exposed\n'
            'Internal: ${service.internalPorts}\n'
            'External: ${service.externalPorts}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              buildActionButton(
                key: Key('service-start-stop-${service.id}'),
                label: startStopLabel,
                onPressed: service.isBusy || !controlState.startStopEnabled
                    ? null
                    : onStartStop,
                disabledReason: startStopBlockedReason,
              ),
              buildActionButton(
                key: Key('service-restart-${service.id}'),
                label: 'Restart',
                onPressed: service.isBusy || !controlState.restartEnabled
                    ? null
                    : onRestart,
                disabledReason: restartBlockedReason,
              ),
              buildActionButton(
                key: Key('service-configure-${service.id}'),
                label: 'Configure',
                onPressed: service.isBusy || !controlState.configureEnabled
                    ? null
                    : onConfigure,
                disabledReason: configureBlockedReason,
              ),
              if (onDelete != null)
                buildActionButton(
                  key: Key('service-delete-${service.id}'),
                  label: 'Delete',
                  onPressed: service.isBusy || !controlState.deleteEnabled
                      ? null
                      : onDelete,
                  disabledReason: deleteBlockedReason,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: YaruColors.red,
                    side: const BorderSide(color: YaruColors.red),
                  ),
                ),
            ],
          ),
          if (blockedMessages.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final message in blockedMessages)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          if (footer != null) ...[const SizedBox(height: 10), footer],
        ],
      ),
    );
  }
}

class _ServiceActionControlState {
  const _ServiceActionControlState({
    this.startStopEnabled = true,
    this.restartEnabled = true,
    this.configureEnabled = true,
    this.deleteEnabled = true,
    this.startStopBlockedReason,
    this.restartBlockedReason,
    this.configureBlockedReason,
    this.deleteBlockedReason,
  });

  final bool startStopEnabled;
  final bool restartEnabled;
  final bool configureEnabled;
  final bool deleteEnabled;
  final String? startStopBlockedReason;
  final String? restartBlockedReason;
  final String? configureBlockedReason;
  final String? deleteBlockedReason;
}

class _ServiceActionPrecheck {
  const _ServiceActionPrecheck._({
    required this.allowed,
    required this.message,
  });

  const _ServiceActionPrecheck.allowed() : this._(allowed: true, message: '');

  const _ServiceActionPrecheck.blocked(String message)
    : this._(allowed: false, message: message);

  final bool allowed;
  final String message;
}

enum _ServiceActivityLevel { success, warning, error, info }

class _ServiceActivityEntry {
  const _ServiceActivityEntry({
    required this.headline,
    required this.details,
    required this.message,
    required this.level,
  });

  final String headline;
  final String details;
  final String message;
  final _ServiceActivityLevel level;
}

class _ServiceActivityRow extends StatelessWidget {
  const _ServiceActivityRow({required this.activity});

  final _ServiceActivityEntry activity;

  @override
  Widget build(BuildContext context) {
    final color = switch (activity.level) {
      _ServiceActivityLevel.success => Colors.green,
      _ServiceActivityLevel.warning => YaruColors.orange,
      _ServiceActivityLevel.error => YaruColors.red,
      _ServiceActivityLevel.info => Theme.of(context).colorScheme.primary,
    };
    final icon = switch (activity.level) {
      _ServiceActivityLevel.success => Icons.check_circle_outline,
      _ServiceActivityLevel.warning => Icons.warning_amber_rounded,
      _ServiceActivityLevel.error => Icons.error_outline,
      _ServiceActivityLevel.info => Icons.info_outline,
    };

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.headline,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  activity.details,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  activity.message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerServiceRecord {
  const _ServerServiceRecord({
    required this.id,
    required this.name,
    required this.purpose,
    required this.icon,
    required this.internalPorts,
    required this.externalPorts,
    this.isProvisioned = false,
    this.status = const ContainerRuntimeStatus.stopped(),
    this.isBusy = false,
  });

  final String id;
  final String name;
  final String purpose;
  final IconData icon;
  final String internalPorts;
  final String externalPorts;
  final bool isProvisioned;
  final ContainerRuntimeStatus status;
  final bool isBusy;

  _ServerServiceRecord copyWith({
    bool? isProvisioned,
    ContainerRuntimeStatus? status,
    bool? isBusy,
  }) {
    return _ServerServiceRecord(
      id: id,
      name: name,
      purpose: purpose,
      icon: icon,
      internalPorts: internalPorts,
      externalPorts: externalPorts,
      isProvisioned: isProvisioned ?? this.isProvisioned,
      status: status ?? this.status,
      isBusy: isBusy ?? this.isBusy,
    );
  }
}
