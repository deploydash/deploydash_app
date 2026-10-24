part of '../server_management_view.dart';

class _OverviewTab extends ConsumerStatefulWidget {
  const _OverviewTab(this.server);

  final Server? server;

  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  bool _isLoading = false;
  String? _errorMessage;
  DateTime? _lastUpdatedAt;
  Map<String, dynamic> _metrics = const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    unawaited(_fetchOverviewMetrics());
  }

  @override
  void didUpdateWidget(covariant _OverviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousId = oldWidget.server?.id;
    final currentId = widget.server?.id;
    if (previousId != currentId) {
      _metrics = const <String, dynamic>{};
      _errorMessage = null;
      _lastUpdatedAt = null;
      unawaited(_fetchOverviewMetrics());
    }
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  Future<void> _fetchOverviewMetrics() async {
    if (_isLoading) {
      return;
    }
    final selectedServer = widget.server;
    if (selectedServer == null) {
      setState(() {
        _errorMessage = 'No server selected.';
      });
      return;
    }

    final connection = await _buildConnectionPayload(selectedServer);
    if (connection == null) {
      setState(() {
        _errorMessage =
            'This server is missing SSH access details. Update the connection first.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'overview_metrics',
                    connection: connection,
                    params: const <String, dynamic>{'dry_run': false},
                  ))
              .diagnosticPayload;

      if (!mounted) {
        return;
      }

      final isSuccess = response['status']?.toString() == 'success';
      final message = response['msg']?.toString().trim();
      final resolvedMessage = message == null || message.isEmpty
          ? (isSuccess
                ? 'Server activity updated.'
                : 'Couldn’t load server activity.')
          : message;

      if (isSuccess) {
        final metrics = mapFrom(response['metrics']);
        setState(() {
          _isLoading = false;
          _metrics = metrics;
          _lastUpdatedAt = DateTime.now();
        });
      } else {
        setState(() {
          _isLoading = false;
          _errorMessage = resolvedMessage;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = 'Couldn’t load server activity. $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = buildOverviewMetricsView(_metrics);
    final canRequestMetrics = widget.server != null;
    final uiState = buildOverviewUiState(
      canRequestMetrics: canRequestMetrics,
      metrics: _metrics,
      errorMessage: _errorMessage,
      lastUpdatedAt: _lastUpdatedAt,
    );
    // Hoisted so the `!= null` check promotes it; a public final field is
    // never promoted.
    final visibleErrorMessage = uiState.visibleErrorMessage;

    if (uiState.showInitialLoading) {
      return const Center(
        child: SizedBox(
          width: 72,
          height: 72,
          child: CircularProgressIndicator(strokeWidth: 4),
        ),
      );
    }

    return ListView(
      key: const Key('server-management-overview-tab'),
      children: [
        Align(
          alignment: Alignment.topRight,
          child: IconButton(
            key: const Key('overview-refresh-button'),
            onPressed: _isLoading ? null : _fetchOverviewMetrics,
            tooltip: 'Refresh',
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(YaruIcons.refresh, size: 18),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _GaugeCard(
              title: 'CPU',
              subtitle:
                  '${formatOverviewUnit(view.cpuUsagePercent, '%')} used • load 1m ${view.load1m?.toStringAsFixed(2) ?? 'Unavailable'}',
              value: (view.cpuUsagePercent ?? 0) / 100,
              color: overviewGaugeColor(view.cpuUsagePercent),
            ),
            _GaugeCard(
              title: 'RAM',
              subtitle:
                  '${formatOverviewUnit(view.memoryUsedPercent, '%')} used • ${formatOverviewUnit(view.memoryUsedMb, ' GB', divisor: 1024)} of ${formatOverviewUnit(view.memoryTotalMb, ' GB', divisor: 1024)}',
              value: (view.memoryUsedPercent ?? 0) / 100,
              color: overviewGaugeColor(view.memoryUsedPercent),
            ),
            _GaugeCard(
              title: 'Root storage',
              subtitle:
                  '${formatOverviewUnit(view.diskUsedPercent, '%')} used • ${formatOverviewUnit(view.diskFreeGb, ' GB')} free',
              value: (view.diskUsedPercent ?? 0) / 100,
              color: overviewGaugeColor(view.diskUsedPercent),
            ),
            _InfoCard(
              title: 'Uptime',
              value: formatOverviewUptime(view.uptimeSeconds),
              subtitle:
                  'Started ${formatOverviewTimestamp(view.bootedAt, fallback: 'Unavailable')}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Last updated: ${uiState.lastUpdatedLabel}',
          key: const Key('overview-last-updated'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (visibleErrorMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            visibleErrorMessage,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _errorMessage != null ? YaruColors.red : null,
            ),
          ),
        ],
        const SizedBox(height: 16),
        AppWorkspaceSection(
          title: 'Network',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 240,
                    child: _CompactMetricTile(
                      label: 'Primary interface',
                      value: view.topInterfaceName,
                      subtle: true,
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'Receive',
                      value: formatOverviewUnit(view.topInterfaceRx, ' kB/s'),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'Send',
                      value: formatOverviewUnit(view.topInterfaceTx, ' kB/s'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AppTechnicalDetails(
                title: 'All network interfaces',
                child: view.interfaces.isEmpty
                    ? const Text('Interface details are unavailable.')
                    : Column(
                        children: view.interfaces
                            .map((interface) {
                              final rx = formatOverviewUnit(
                                interface.rxKbps,
                                ' kB/s',
                              );
                              final tx = formatOverviewUnit(
                                interface.txKbps,
                                ' kB/s',
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _DualThroughputRow(
                                  label: interface.name,
                                  leftValueLabel: 'RX $rx',
                                  rightValueLabel: 'TX $tx',
                                  leftFraction:
                                      interface.rxKbps /
                                      view.maxInterfaceThroughput,
                                  rightFraction:
                                      interface.txKbps /
                                      view.maxInterfaceThroughput,
                                ),
                              );
                            })
                            .toList(growable: false),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppWorkspaceSection(
          title: 'Disk I/O',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 240,
                    child: _CompactMetricTile(
                      label: 'Busiest device',
                      value: view.topDeviceName,
                      subtle: true,
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'Read',
                      value: formatOverviewUnit(view.totalReadKbps, ' kB/s'),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'Write',
                      value: formatOverviewUnit(view.totalWriteKbps, ' kB/s'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AppTechnicalDetails(
                title: 'All storage devices',
                child: view.devices.isEmpty
                    ? const Text('Storage device details are unavailable.')
                    : Column(
                        children: view.devices
                            .map((device) {
                              final read = formatOverviewUnit(
                                device.readKbps,
                                ' kB/s',
                              );
                              final write = formatOverviewUnit(
                                device.writeKbps,
                                ' kB/s',
                              );
                              final util = formatOverviewUnit(
                                device.utilPercent,
                                '%',
                              );
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _UtilizationRow(
                                  label: device.name,
                                  subtitle:
                                      'Read $read • Write $write • Used $util',
                                  utilization: device.utilPercent / 100,
                                ),
                              );
                            })
                            .toList(growable: false),
                      ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppTechnicalDetails(
          title: 'Metric collection details',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'Retention',
                      value: '${view.retentionDays} days',
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: _CompactMetricTile(
                      label: 'sysstat files',
                      value: '${view.sysstatFileCount}',
                    ),
                  ),
                  SizedBox(
                    width: 220,
                    child: _CompactMetricTile(
                      label: 'Root inode usage',
                      value: formatOverviewUnit(view.diskInodeUsedPercent, '%'),
                      subtle: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (view.oldestFile != null)
                Text(
                  'Oldest file: ${view.oldestFile}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (view.newestFile != null)
                Text(
                  'Newest file: ${view.newestFile}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              Text(
                'Collected at: ${formatOverviewTimestamp(view.collectedAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
