part of '../server_management_view.dart';

extension _ServicesTabActivity on _ServicesTabState {
  void _bindOperationCenterStreams() {
    _queueSubscription?.cancel();
    final sshService = ref.read(sshServiceProvider);
    _operationQueue = _filterQueueForActiveServer(
      sshService.getOperationQueueSnapshot(hostKey: widget.server?.host),
    );
    _queueSubscription = sshService.watchOperationQueue().listen((snapshot) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _operationQueue = _filterQueueForActiveServer(snapshot);
      });
    });
  }

  List<OperationQueueSnapshot> _filterQueueForActiveServer(
    List<OperationQueueSnapshot> snapshots,
  ) {
    final currentHost = widget.server?.host.trim().toLowerCase();
    if (currentHost == null || currentHost.isEmpty) {
      return snapshots;
    }
    return snapshots
        .where((entry) {
          final entryHost = entry.hostKey?.trim().toLowerCase();
          return (entryHost == null || entryHost == currentHost) &&
              isActiveServiceLifecycleOperation(entry);
        })
        .toList(growable: false);
  }

  Future<void> _loadRecentServiceActivity() async {
    final sshService = ref.read(sshServiceProvider);
    final historyResult = await sshService.getRecentTaskHistory(limit: 40);
    final historyEntries = switch (historyResult) {
      Ok<List<EngineTaskHistoryEntry>>(:final value) => value,
      // History is supplementary to the live queue; a typed engine failure
      // deliberately leaves the activity list empty.
      Err<List<EngineTaskHistoryEntry>>() => const <EngineTaskHistoryEntry>[],
    };
    if (!mounted) {
      return;
    }
    final serviceEntries = historyEntries
        .where((entry) {
          if (entry.action != 'run_workflow') {
            return false;
          }
          return isServiceLifecycleOperation(
            workflowId: entry.workflowId,
            operationId: entry.operationId,
          );
        })
        .toList(growable: false);
    if (serviceEntries.isEmpty) {
      return;
    }

    final activity = serviceEntries.reversed
        .take(_ServicesTabState._maxRecentServiceActivities)
        .map(_serviceActivityFromTaskHistory)
        .toList(growable: false);
    _applyState(() {
      _recentServiceActivity
        ..clear()
        ..addAll(activity);
    });
  }

  _ServiceActivityEntry _serviceActivityFromTaskHistory(
    EngineTaskHistoryEntry entry,
  ) {
    final scope = switch (entry.workflowId) {
      'postgres' => 'Database',
      _ => 'Web server',
    };
    final operation = _serviceOperationLabel(entry.operationId);
    final completedAt = entry.completedAt;
    final timestamp = completedAt == null
        ? ''
        : formatClockTime(completedAt.toLocal());
    final prefix = timestamp.isEmpty ? scope : '$scope • $timestamp';
    final statusLabel = entry.cancelled
        ? 'Cancelled'
        : (entry.status == 'success' ? 'Completed' : 'Failed');
    final message = '$scope was ${operation.toLowerCase()}.';
    final details = '$operation • $statusLabel';
    final level = entry.status == 'success'
        ? _ServiceActivityLevel.success
        : entry.cancelled
        ? _ServiceActivityLevel.warning
        : _ServiceActivityLevel.error;
    return _ServiceActivityEntry(
      headline: prefix,
      details: details,
      message: message,
      level: level,
    );
  }

  // Pure delegate kept: 8 callers (2 here + 6 in services_tab_actions.dart),
  // above the 3-caller inline bar (D-57 T-015 verdict).
  String _serviceOperationLabel(String? operationId) {
    return serviceOperationLabel(operationId);
  }

  void _recordServiceActivity(
    _ServiceActivityEntry entry, {
    bool refreshHistory = false,
  }) {
    if (!mounted) {
      return;
    }
    _applyState(() {
      _recentServiceActivity.insert(0, entry);
      if (_recentServiceActivity.length >
          _ServicesTabState._maxRecentServiceActivities) {
        _recentServiceActivity.removeRange(
          _ServicesTabState._maxRecentServiceActivities,
          _recentServiceActivity.length,
        );
      }
    });
    if (refreshHistory) {
      unawaited(_loadRecentServiceActivity());
    }
  }

  Future<void> _cancelOperationQueueEntry(String operationInstanceId) async {
    final sshService = ref.read(sshServiceProvider);
    final cancellation = await sshService.cancelOperation(operationInstanceId);
    final cancelled = switch (cancellation) {
      Ok<bool>(:final value) => value,
      Err<bool>() => false,
    };
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          cancelled
              ? 'Cancellation requested.'
              : 'Unable to cancel this operation.',
        ),
      ),
    );
  }

  // The snapshot picker stays local: 3 lines in a different file from its
  // bottom-sheet twin, and a shared picker home for 3 lines is the cure
  // worse than the disease (D-45-pair-1 LEAVE precedent, D-57 T-015).
  String _operationTimestampText(OperationQueueSnapshot entry) {
    final candidate = entry.completedAt ?? entry.startedAt ?? entry.submittedAt;
    final local = candidate.toLocal();
    return formatClockTime(local);
  }

  String _activeOperationTitle(OperationQueueSnapshot entry) {
    final scope = entry.workflowId == 'postgres' ? 'Database' : 'Web server';
    final operation = _serviceOperationLabel(entry.workflowOperationId);
    return '$scope • $operation';
  }

  List<_ServerServiceRecord> _buildInitialServices(Server? server) {
    final databaseEnabled = server?.serviceDatabaseEnabled ?? false;
    final emailEnabled = server?.serviceEmailEnabled ?? false;
    final domainEnabled = server?.serviceDomainEnabled ?? false;
    return <_ServerServiceRecord>[
      const _ServerServiceRecord(
        id: 'proxy',
        name: 'Web server',
        purpose:
            'Caddy routes web traffic to apps and handles HTTPS/SSL certificates',
        icon: Icons.public,
        isProvisioned: true,
        status: ContainerRuntimeStatus.ready(),
        internalPorts: '80, 443',
        externalPorts: '80, 443',
      ),
      _ServerServiceRecord(
        id: 'database',
        name: 'Database (Postgres)',
        purpose: 'Managed PostgreSQL server',
        icon: Icons.storage_rounded,
        isProvisioned: databaseEnabled,
        status: databaseEnabled
            ? const ContainerRuntimeStatus.stopped()
            : const ContainerRuntimeStatus.notConfigured(),
        internalPorts: '5432',
        externalPorts: '5432',
      ),
      _ServerServiceRecord(
        id: 'email',
        name: 'Email',
        purpose:
            'Stalwart Mail Server manages mailboxes and outbound email delivery',
        icon: Icons.mail_outline,
        isProvisioned: emailEnabled,
        status: emailEnabled
            ? const ContainerRuntimeStatus.stopped()
            : const ContainerRuntimeStatus.notConfigured(),
        internalPorts: '25, 465, 587',
        externalPorts: '25, 465, 587',
      ),
      _ServerServiceRecord(
        id: 'domain',
        name: 'DNS and domains',
        purpose: 'BIND9 manages DNS records and domain routing',
        icon: Icons.language_rounded,
        isProvisioned: domainEnabled,
        status: domainEnabled
            ? const ContainerRuntimeStatus.stopped()
            : const ContainerRuntimeStatus.notConfigured(),
        internalPorts: '53',
        externalPorts: '53',
      ),
    ];
  }

  List<_ServerServiceRecord> get _availableServices => _services
      .where((service) => !service.isProvisioned)
      .toList(growable: false);

  List<_ServerServiceRecord> get _enabledServices => _services
      .where((service) => service.isProvisioned)
      .toList(growable: false);

  int get _runningServices =>
      _enabledServices.where((service) => service.status.isReady).length;

  int get _stoppedServices =>
      _enabledServices.where((service) => service.status.isStoppedLike).length;

  int get _provisioningServices => _enabledServices
      .where(
        (service) =>
            service.status.effectiveStatus ==
            ContainerRuntimeEffectiveStatus.provisioning,
      )
      .length;
}
