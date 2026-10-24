part of '../server_management_view.dart';

const List<String> _capabilityCategoryOrder = [
  'Build and deployment',
  'Traffic',
  'Databases',
  'Server maintenance',
];

class _UpdatesTab extends ConsumerStatefulWidget {
  const _UpdatesTab(this.server, {this.onTerminalLine});

  final Server? server;
  final ServerTerminalLineWriter? onTerminalLine;

  @override
  ConsumerState<_UpdatesTab> createState() => _UpdatesTabState();
}

class _UpdatesTabState extends ConsumerState<_UpdatesTab> {
  Map<String, ManagedCapabilityViewModel> _capabilities =
      const <String, ManagedCapabilityViewModel>{};
  bool _isRefreshing = false;
  bool _isUpdating = false;
  bool _isRollingBack = false;
  String? _busyComponentId;
  String? _statusMessage;
  String? _statusError;

  @override
  void initState() {
    super.initState();
    _loadCachedManagedSoftwareStatus();
    unawaited(_refreshToolingStatus());
  }

  @override
  void didUpdateWidget(covariant _UpdatesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server?.id != widget.server?.id) {
      setState(() {
        _capabilities = const <String, ManagedCapabilityViewModel>{};
        _statusMessage = null;
        _statusError = null;
      });
      _loadCachedManagedSoftwareStatus();
      unawaited(_refreshToolingStatus());
    }
  }

  void _loadCachedManagedSoftwareStatus() {
    final cachedStatus = widget.server?.managedSoftwareStatus;
    if (cachedStatus == null) {
      return;
    }
    _capabilities = parseManagedCapabilities(<String, dynamic>{
      'managed_software': cachedStatus.toJsonMap(),
    });
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  void _appendUpdateLogEvent(Map<String, dynamic> event) {
    final writer = widget.onTerminalLine;
    if (writer == null) {
      return;
    }
    final message = event['message']?.toString().trim();
    if (message == null || message.isEmpty) {
      return;
    }
    final eventType = event['type']?.toString().trim();
    writer(
      message,
      detail: event['level']?.toString().toLowerCase() == 'debug',
      source: eventType == null || eventType.isEmpty
          ? 'updates'
          : 'updates:$eventType',
      taskType: 'updates',
    );
  }

  Future<void> _refreshToolingStatus({bool quiet = false}) async {
    final server = widget.server;
    if (server == null) {
      setState(() {
        _statusError = 'No server selected.';
      });
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      setState(() {
        _statusError =
            'This server is missing the saved SSH details needed to check updates.';
      });
      return;
    }

    setState(() {
      _isRefreshing = true;
      _statusError = null;
      if (!quiet) {
        _statusMessage = null;
      }
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'tooling_status',
                    connection: connection,
                    params: const <String, dynamic>{'dry_run': false},
                    onEvent: _appendUpdateLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        final parsedCapabilities = parseManagedCapabilities(result);
        await _cacheManagedSoftwareStatus(result);
        setState(() {
          _capabilities = parsedCapabilities;
          _statusMessage =
              result['msg']?.toString() ?? 'Server update status refreshed.';
          _statusError = null;
          _isRefreshing = false;
        });
      } else {
        final message =
            result['msg']?.toString() ?? 'Failed to refresh update status.';
        setState(() {
          _statusError = message;
          _isRefreshing = false;
        });
        await _showUpdatesErrorDialog(message);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = 'Failed to refresh update status: $error';
      setState(() {
        _statusError = message;
        _isRefreshing = false;
      });
      await _showUpdatesErrorDialog(message);
    }
  }

  Future<void> _cacheManagedSoftwareStatus(Map<String, dynamic> result) async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final managedSoftware = result['managed_software'];
    if (managedSoftware is! Map) {
      return;
    }
    await ref
        .read(serverRepositoryProvider)
        .updateServerManagedSoftwareStatus(
          serverId: server.id,
          status: ServerManagedSoftwareStatus.fromJsonMap(
            mapFrom(managedSoftware),
          ),
        );
  }

  Future<void> _updateTooling({List<String>? componentIds}) async {
    // Non-null: the tab-level button requires `server != null` to enable, and
    // a per-capability button only exists once capabilities have loaded --
    // which needs a server, since `_loadCachedManagedSoftwareStatus` returns
    // early without one and `didUpdateWidget` clears them when the server id
    // changes. An early return here instead would be an unreachable branch
    // under `server_updates_coverage.sh`'s 100% gate.
    final server = widget.server!;
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }
    final selectedIds = componentIds ?? updateableCapabilityIds(_capabilities);

    setState(() {
      _isUpdating = true;
      _busyComponentId = selectedIds.length == 1 ? selectedIds.single : null;
      _statusError = null;
      _statusMessage = selectedIds.length == 1
          ? 'Updating ${_capabilities[selectedIds.single]?.label ?? 'managed software'}...'
          : 'Updating managed server software...';
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'tooling_update',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'component_ids': selectedIds,
                    },
                    onEvent: _appendUpdateLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        final parsedCapabilities = parseManagedCapabilities(result);
        await _cacheManagedSoftwareStatus(result);
        setState(() {
          _capabilities = parsedCapabilities;
          _statusMessage =
              result['msg']?.toString() ?? 'Managed server software updated.';
          _statusError = null;
          _isUpdating = false;
          _busyComponentId = null;
        });
        if (_capabilities.isEmpty) {
          await _refreshToolingStatus(quiet: true);
        }
      } else {
        final message =
            result['msg']?.toString() ?? 'Failed to update server tooling.';
        setState(() {
          _statusError = message;
          _isUpdating = false;
          _busyComponentId = null;
        });
        await _showUpdatesErrorDialog(message);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = 'Failed to update server tooling: $error';
      setState(() {
        _statusError = message;
        _isUpdating = false;
        _busyComponentId = null;
      });
      await _showUpdatesErrorDialog(message);
    }
  }

  Future<void> _rollbackTooling(ManagedCapabilityViewModel capability) async {
    // Non-null for the same reason as in `_updateTooling`: reaching this
    // needs a rendered capability row, which needs a loaded server.
    final server = widget.server!;
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }
    var restoreData = false;
    if (capability.offersDataRestore) {
      // coverage-gate: postgres_rollback_action
      final choice = await _confirmPostgresRollback(capability);
      // No mounted check: the modal choice can only complete with a value
      // while this tab is still beneath it. A null choice -- dismissed or
      // disposed -- returns before any mounted-sensitive work below.
      if (choice == null) {
        return;
      }
      if (choice == PostgresRollbackChoice.restoreData) {
        final restoreConfirmed = await _confirmPostgresDataRestore(capability);
        if (restoreConfirmed != true) {
          return;
        }
        restoreData = true;
      }
      // end coverage-gate
    } else {
      final confirmed = await _confirmRollback(capability);
      if (!confirmed || !mounted) {
        return;
      }
    }

    setState(() {
      _isRollingBack = true;
      _busyComponentId = capability.id;
      _statusError = null;
      _statusMessage = 'Rolling back ${capability.label}...';
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'tooling_rollback',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'component_id': capability.id,
                      'restore_data': restoreData,
                    },
                    onEvent: _appendUpdateLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        final parsedCapabilities = parseManagedCapabilities(result);
        await _cacheManagedSoftwareStatus(result);
        setState(() {
          _capabilities = parsedCapabilities;
          _statusMessage =
              result['msg']?.toString() ??
              'Managed server software rolled back.';
          _statusError = null;
          _isRollingBack = false;
          _busyComponentId = null;
        });
      } else {
        final message =
            result['msg']?.toString() ?? 'Failed to rollback managed software.';
        setState(() {
          _statusError = message;
          _isRollingBack = false;
          _busyComponentId = null;
        });
        await _showUpdatesErrorDialog(message);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = 'Failed to rollback managed software: $error';
      setState(() {
        _statusError = message;
        _isRollingBack = false;
        _busyComponentId = null;
      });
      await _showUpdatesErrorDialog(message);
    }
  }

  // coverage-gate: postgres_rollback_dialogs
  Future<bool> _confirmRollback(ManagedCapabilityViewModel capability) async {
    final destructive =
        capability.riskLevel == 'destructive' || capability.riskLevel == 'high';
    final description =
        'Deploy Dash will restore the last recorded rollback snapshot for ${capability.label}.';
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        if (destructive) {
          return AppDestructiveConfirmDialog(
            title: 'Rollback ${capability.label}?',
            description: description,
            confirmLabel: 'Rollback',
          );
        }
        return AppConfirmDialog(
          title: 'Rollback ${capability.label}?',
          description: description,
          confirmLabel: 'Rollback',
          onConfirm: () {},
        );
      },
    );
    return result == true;
  }

  /// Asks which PostgreSQL rollback to run: the default image-only rollback
  /// that keeps every row, or the explicit pre-update-backup restore.
  ///
  /// Returns null when the user dismisses the choice without answering.
  Future<PostgresRollbackChoice?> _confirmPostgresRollback(
    ManagedCapabilityViewModel capability,
  ) {
    return showDialog<PostgresRollbackChoice>(
      context: context,
      builder: (context) {
        return AppDialogScaffold(
          title: 'Rollback ${capability.label}?',
          description:
              'Deploy Dash will restore the previous PostgreSQL image. Your data stays exactly as it is.',
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(PostgresRollbackChoice.restoreData),
              child: Text(capability.dataRestoreLabel),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(PostgresRollbackChoice.keepData),
              child: const Text('Roll back'),
            ),
          ],
          child: const SizedBox.shrink(),
        );
      },
    );
  }

  /// Confirms the destructive half of the PostgreSQL rollback choice:
  /// replacing the live database with the pre-update backup.
  Future<bool?> _confirmPostgresDataRestore(
    ManagedCapabilityViewModel capability,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AppDestructiveConfirmDialog(
          title: '${capability.dataRestoreLabel}?',
          description:
              'This replaces the live database with the pre-update backup. Everything written since the update will be lost.',
          confirmLabel: 'Restore data',
        );
      },
    );
  }
  // end coverage-gate

  Future<void> _showUpdatesErrorDialog(String message) async {
    if (!mounted) {
      return;
    }
    await showAppNotice(context, title: 'Update failed', message: message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _isRefreshing || _isUpdating || _isRollingBack;
    // Hoisted so the `!= null` checks below promote them; a field cannot be.
    final statusMessage = _statusMessage;
    final statusError = _statusError;
    final server = widget.server;
    final canUpdate =
        !busy &&
        updateableCapabilityIds(_capabilities).isNotEmpty &&
        server != null;
    final capabilities = _capabilities.values.toList(growable: false);

    return ListView(
      key: const Key('server-management-updates-tab'),
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        AppWorkspaceSection(
          title: 'Managed server capabilities',
          subtitle:
              'Each row is updated as one capability. Internal files, images, and helpers are shown only as details.',
          icon: Icons.system_update_alt,
          headerAction: Tooltip(
            message: 'Refresh update status',
            child: IconButton(
              key: const Key('server-updates-refresh-tooling'),
              onPressed: busy ? null : () => _refreshToolingStatus(),
              icon: _isRefreshing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (capabilities.isEmpty)
                Text(
                  _isRefreshing
                      ? 'Checking server capabilities...'
                      : 'Update status has not been checked yet.',
                )
              else
                _CapabilityInventory(
                  capabilities: capabilities,
                  busy: busy,
                  busyComponentId: _busyComponentId,
                  onUpdate: (capability) {
                    _updateTooling(componentIds: [capability.id]);
                  },
                  onRollback: _rollbackTooling,
                ),
              if (statusMessage != null) ...[
                const SizedBox(height: 12),
                Text(statusMessage, style: theme.textTheme.bodySmall),
              ],
              if (statusError != null) ...[
                const SizedBox(height: 12),
                Text(
                  statusError,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('server-updates-update-tooling'),
                  onPressed: canUpdate ? _updateTooling : null,
                  icon: _isUpdating
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(
                    managedUpdateButtonLabel(
                      capabilities: _capabilities,
                      isUpdating: _isUpdating,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CapabilityInventory extends StatelessWidget {
  const _CapabilityInventory({
    required this.capabilities,
    required this.busy,
    required this.busyComponentId,
    required this.onUpdate,
    required this.onRollback,
  });

  final List<ManagedCapabilityViewModel> capabilities;
  final bool busy;
  final String? busyComponentId;
  final ValueChanged<ManagedCapabilityViewModel> onUpdate;
  final ValueChanged<ManagedCapabilityViewModel> onRollback;

  @override
  Widget build(BuildContext context) {
    final byCategory = <String, List<ManagedCapabilityViewModel>>{};
    for (final capability in capabilities) {
      byCategory.putIfAbsent(capability.category, () => []).add(capability);
    }
    final orderedCategories = [
      ..._capabilityCategoryOrder.where(byCategory.containsKey),
      ...byCategory.keys.where((category) {
        return !_capabilityCategoryOrder.contains(category);
      }),
    ];

    final sections = <Widget>[];
    for (final category in orderedCategories) {
      // Every entry of `orderedCategories` came from `byCategory`'s own keys,
      // so the lookup always hits; `?? const []` says that without asserting
      // it, and renders an empty section rather than throwing if it ever
      // stops being true.
      final items =
          byCategory[category] ?? const <ManagedCapabilityViewModel>[];
      sections.add(
        _CapabilityCategorySection(
          category: category,
          capabilities: items,
          busy: busy,
          busyComponentId: busyComponentId,
          onUpdate: onUpdate,
          onRollback: onRollback,
        ),
      );
      if (category != orderedCategories.last) {
        sections.add(const Divider(height: 24));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }
}

class _CapabilityCategorySection extends StatelessWidget {
  const _CapabilityCategorySection({
    required this.category,
    required this.capabilities,
    required this.busy,
    required this.busyComponentId,
    required this.onUpdate,
    required this.onRollback,
  });

  final String category;
  final List<ManagedCapabilityViewModel> capabilities;
  final bool busy;
  final String? busyComponentId;
  final ValueChanged<ManagedCapabilityViewModel> onUpdate;
  final ValueChanged<ManagedCapabilityViewModel> onRollback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          category,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        for (final capability in capabilities)
          _CapabilityRow(
            capability: capability,
            busy: busy,
            busyComponentId: busyComponentId,
            onUpdate: onUpdate,
            onRollback: onRollback,
          ),
      ],
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    required this.capability,
    required this.busy,
    required this.busyComponentId,
    required this.onUpdate,
    required this.onRollback,
  });

  final ManagedCapabilityViewModel capability;
  final bool busy;
  final String? busyComponentId;
  final ValueChanged<ManagedCapabilityViewModel> onUpdate;
  final ValueChanged<ManagedCapabilityViewModel> onRollback;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rowBusy = busyComponentId == capability.id;
    final serviceStatus = capability.serviceStatus;
    final canUpdate =
        !busy && capability.canUpdate && capability.status != 'current';
    final canRollback = !busy && capability.canRollback;

    return ExpansionTile(
      key: Key('server-updates-capability-${capability.id}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 16, right: 8, bottom: 12),
      title: Row(
        children: [
          Expanded(
            child: Text(
              capability.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            children: [
              AppStatusBadge(
                label: capability.statusLabel,
                tone: _capabilityStatusTone(capability.status),
                icon: _capabilityStatusIcon(capability.status),
              ),
              if (serviceStatus != null)
                AppStatusBadge(
                  label: 'Service ${serviceStatus.label}',
                  tone: appContainerRuntimeStatusTone(
                    serviceStatus.effectiveStatus,
                  ),
                  icon: _serviceStatusIcon(serviceStatus.effectiveStatus),
                ),
            ],
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          capability.summary.isEmpty
              ? capability.description
              : capability.summary,
          style: theme.textTheme.bodySmall,
        ),
      ),
      children: [
        if (capability.description.isNotEmpty) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              capability.description,
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 8),
        ],
        for (final detail in capability.details)
          _CapabilityDetailRow(detail: detail),
        if (capability.riskLevel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Risk: ${managedCapabilityRiskLabel(capability.riskLevel)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: Key('server-updates-update-${capability.id}'),
              onPressed: canUpdate ? () => onUpdate(capability) : null,
              icon: rowBusy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: Text(capability.actionLabel),
            ),
            OutlinedButton.icon(
              key: Key('server-updates-rollback-${capability.id}'),
              onPressed: canRollback ? () => onRollback(capability) : null,
              icon: const Icon(Icons.restore),
              label: Text(capability.rollbackLabel),
            ),
          ],
        ),
      ],
    );
  }
}

class _CapabilityDetailRow extends StatelessWidget {
  const _CapabilityDetailRow({required this.detail});

  final CapabilityDetailViewModel detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = detail.current.trim().isEmpty
        ? 'Not installed'
        : detail.current.trim();
    final target = detail.target.trim().isEmpty
        ? 'Managed by Deploy Dash'
        : detail.target.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail.label, style: theme.textTheme.bodySmall),
                const SizedBox(height: 2),
                Text(
                  'Current: $current',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Target: $target',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppStatusBadge(
            label: detail.statusLabel,
            tone: _capabilityStatusTone(detail.status),
            icon: _capabilityStatusIcon(detail.status),
          ),
        ],
      ),
    );
  }
}

AppStatusTone _capabilityStatusTone(String status) {
  return switch (status) {
    'current' => AppStatusTone.positive,
    'update_available' => AppStatusTone.warning,
    'missing' => AppStatusTone.negative,
    'not_configured' => AppStatusTone.neutral,
    _ => AppStatusTone.negative,
  };
}

IconData _capabilityStatusIcon(String status) {
  return switch (status) {
    'current' => Icons.verified_outlined,
    'update_available' => Icons.system_update_alt,
    'missing' => Icons.error_outline,
    'not_configured' => Icons.remove_circle_outline,
    _ => Icons.warning_amber_outlined,
  };
}

IconData _serviceStatusIcon(ContainerRuntimeEffectiveStatus status) {
  return switch (status) {
    ContainerRuntimeEffectiveStatus.ready => Icons.favorite_outline,
    ContainerRuntimeEffectiveStatus.starting ||
    ContainerRuntimeEffectiveStatus.restarting ||
    ContainerRuntimeEffectiveStatus.provisioning => Icons.sync,
    ContainerRuntimeEffectiveStatus.unhealthy => Icons.heart_broken_outlined,
    ContainerRuntimeEffectiveStatus.stopped => Icons.stop_circle_outlined,
    ContainerRuntimeEffectiveStatus.missing ||
    ContainerRuntimeEffectiveStatus.notConfigured =>
      Icons.remove_circle_outline,
    ContainerRuntimeEffectiveStatus.unknown => Icons.help_outline,
  };
}
