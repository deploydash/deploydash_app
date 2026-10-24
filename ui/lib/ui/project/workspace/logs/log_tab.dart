part of '../../project_workspace.dart';

class _LogTabView extends StatelessWidget {
  const _LogTabView();

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final logPanelHeight = (viewportHeight * 0.56).clamp(420.0, 720.0);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        DefaultTabController(
          length: 2,
          child: AppWorkspaceSection(
            key: const Key('app-log-card'),
            icon: Icons.receipt_long,
            title: 'Logs',
            subtitle:
                'Review runtime output and deployment history for this web app.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TabBar(
                  key: const Key('app-log-tab-bar'),
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: const [
                    Tab(key: Key('log-runtime-tab'), text: 'Web app runtime'),
                    Tab(key: Key('log-deployment-tab'), text: 'Deployment log'),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: logPanelHeight,
                  child: const TabBarView(
                    children: [_RuntimeLogSummary(), _DeploymentLogSummary()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RuntimeLogSummary extends ConsumerStatefulWidget {
  const _RuntimeLogSummary();

  @override
  ConsumerState<_RuntimeLogSummary> createState() => _RuntimeLogSummaryState();
}

class _RuntimeLogSummaryState extends ConsumerState<_RuntimeLogSummary> {
  final TextEditingController _filterController = TextEditingController();
  final Queue<String> _runtimeLineSignatureOrder = Queue<String>();
  final Set<String> _runtimeLineSignatures = <String>{};
  String _filter = '';
  int? _secondsUntilNextRuntimeRefresh;
  bool _isFetchingRuntimeLogs = false;
  bool _runtimeStreamingEnabled = false;
  String? _runtimeLogStatus;
  DateTime? _nextRuntimeRefreshAt;
  Timer? _runtimeCountdownTimer;
  Timer? _runtimeStreamTimer;

  static const int _manualTailLines = 300;
  static const int _streamTailLines = 120;
  static const Duration _streamPollInterval = Duration(seconds: 20);
  static const int _maxRuntimeSignatures = 5000;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _runtimeCountdownTimer?.cancel();
    _runtimeStreamTimer?.cancel();
    _filterController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  bool _recordRuntimeLineSignature(String line) {
    final normalized = line.trim();
    if (normalized.isEmpty) {
      return false;
    }
    if (_runtimeLineSignatures.contains(normalized)) {
      return false;
    }
    _runtimeLineSignatures.add(normalized);
    _runtimeLineSignatureOrder.addLast(normalized);
    while (_runtimeLineSignatureOrder.length > _maxRuntimeSignatures) {
      final evicted = _runtimeLineSignatureOrder.removeFirst();
      _runtimeLineSignatures.remove(evicted);
    }
    return true;
  }

  void _appendRuntimeLogLine({
    required String message,
    required String serverLabel,
    required String source,
    required String taskType,
    DateTime? createdAt,
  }) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final now = createdAt ?? DateTime.now();
    final timestamp = formatClockTime(now);
    final renderedLine = '[$serverLabel $timestamp] $trimmed';
    final selectedProject = ref.read(selectedProjectProvider);
    final selectedServer = ref.read(selectedServerProvider);
    final scope = WorkspaceScope.fromSelection(selectedProject, selectedServer);
    unawaited(
      ref
          .read(terminalLogRepositoryProvider)
          .appendLog(
            message: trimmed,
            renderedLine: renderedLine,
            projectId: scope?.projectId,
            serverId: scope?.serverId,
            serverLabel: serverLabel,
            source: source,
            taskType: taskType,
            createdAt: now,
          ),
    );
  }

  void _startRuntimeStreaming() {
    _runtimeStreamTimer?.cancel();
    _runtimeCountdownTimer?.cancel();
    _nextRuntimeRefreshAt = DateTime.now().add(_streamPollInterval);
    _secondsUntilNextRuntimeRefresh = _streamPollInterval.inSeconds;
    _runtimeCountdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_runtimeStreamingEnabled) {
        return;
      }
      final target = _nextRuntimeRefreshAt;
      if (target == null) {
        return;
      }
      final remaining = target.difference(DateTime.now()).inSeconds;
      final normalized = remaining < 0 ? 0 : remaining;
      if (normalized != _secondsUntilNextRuntimeRefresh) {
        setState(() {
          _secondsUntilNextRuntimeRefresh = normalized;
        });
      }
    });
    _runtimeStreamTimer = Timer.periodic(_streamPollInterval, (_) {
      _nextRuntimeRefreshAt = DateTime.now().add(_streamPollInterval);
      if (mounted) {
        setState(() {
          _secondsUntilNextRuntimeRefresh = _streamPollInterval.inSeconds;
        });
      }
      unawaited(_fetchRuntimeLogs(background: true));
    });
  }

  void _stopRuntimeStreaming() {
    _runtimeCountdownTimer?.cancel();
    _runtimeCountdownTimer = null;
    _runtimeStreamTimer?.cancel();
    _runtimeStreamTimer = null;
    _nextRuntimeRefreshAt = null;
    _secondsUntilNextRuntimeRefresh = null;
  }

  Future<bool> _fetchRuntimeLogs({bool background = false}) async {
    if (_isFetchingRuntimeLogs) {
      return false;
    }

    final selectedProject = ref.read(selectedProjectProvider);
    if (selectedProject == null) {
      if (!background) {
        setState(() {
          _runtimeLogStatus = 'Choose a project before you load app activity.';
        });
      }
      return false;
    }

    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer == null) {
      if (!background) {
        setState(() {
          _runtimeLogStatus = 'Choose a server before you load app activity.';
        });
      }
      return false;
    }

    final connection = await _buildConnectionPayload(selectedServer);
    if (connection == null) {
      if (!background) {
        setState(() {
          _runtimeLogStatus = serverCredentialsReconnectMessage();
        });
      }
      return false;
    }

    final tailLines = background ? _streamTailLines : _manualTailLines;
    final serverLabel = selectedServer.name.trim().isEmpty
        ? 'Server'
        : selectedServer.name.trim();
    setState(() {
      _isFetchingRuntimeLogs = true;
      _runtimeLogStatus = runtimeLogsFetchStatus(background: background);
    });

    try {
      final response =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'app',
                    operationId: 'runtime_logs',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'log_tail_lines': tailLines,
                      'settings': buildRuntimeLogSettings(selectedProject),
                    },
                  ))
              .diagnosticPayload;

      if (!mounted) {
        return false;
      }

      final ok = response['status'] == 'success';
      final runtimeLines = response['runtime_log_lines'];
      if (runtimeLines is Iterable) {
        for (final rawLine in runtimeLines) {
          final line = rawLine?.toString().trim() ?? '';
          if (line.isEmpty || !_recordRuntimeLineSignature(line)) {
            continue;
          }
          _appendRuntimeLogLine(
            message: line,
            serverLabel: serverLabel,
            source: 'app_runtime',
            taskType: 'app_runtime_logs',
          );
        }
      }
      final statusMessage = response['msg']?.toString().trim();
      final fallback = ok
          ? runtimeLogsFetchSuccessMessage()
          : runtimeLogsFetchFailureMessage();
      final resolvedMessage = statusMessage == null || statusMessage.isEmpty
          ? fallback
          : statusMessage;

      setState(() {
        _isFetchingRuntimeLogs = false;
        _runtimeLogStatus = background && ok
            ? runtimeLogsFetchStatus(background: true)
            : resolvedMessage;
      });
      return true;
    } catch (error) {
      if (!mounted) {
        return false;
      }
      final failure = 'Runtime log fetch failed: $error';
      setState(() {
        _isFetchingRuntimeLogs = false;
        _runtimeLogStatus = failure;
      });
      return false;
    }
  }

  bool _isRuntimeRecord(TerminalLogRecord record) {
    return record.source == 'app_runtime' ||
        record.source == 'app_runtime_failed_candidate' ||
        record.source == 'app_runtime_failed_rollback_candidate';
  }

  @override
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    final scope = WorkspaceScope.fromSelection(selectedProject, selectedServer);
    // Hoisted so the `!= null` checks promote them; a State field is never
    // promoted.
    final secondsUntilNextRuntimeRefresh = _secondsUntilNextRuntimeRefresh;
    final runtimeLogStatus = _runtimeLogStatus;
    final logsFuture = scope == null
        ? Future.value(const <TerminalLogRecord>[])
        : ref
              .watch(terminalLogRepositoryProvider)
              .listRecentLogsForScope(
                projectId: scope.projectId,
                serverId: scope.serverId,
                limit: 1200,
              );

    return FutureBuilder<List<TerminalLogRecord>>(
      future: logsFuture,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? const <TerminalLogRecord>[];
        final runtimeLogs = logs
            .where(_isRuntimeRecord)
            .toList(growable: false);
        final normalizedFilter = _filter.trim().toLowerCase();
        final filteredLogs = normalizedFilter.isEmpty
            ? runtimeLogs
            : runtimeLogs
                  .where((record) {
                    final haystack =
                        '${record.renderedLine}\n${record.source}\n${record.taskType ?? ''}'
                            .toLowerCase();
                    return haystack.contains(normalizedFilter);
                  })
                  .toList(growable: false);
        final visibleLogText = filteredLogs
            .map((record) => record.renderedLine)
            .join('\n');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('log-filter-field'),
              controller: _filterController,
              onChanged: (value) => setState(() {
                _filter = value;
              }),
              decoration: InputDecoration(
                hintText: 'Filter logs by keyword',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.trim().isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _filterController.clear();
                          setState(() {
                            _filter = '';
                          });
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${filteredLogs.length} log lines',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () => setState(() {}),
                  icon: const Icon(
                    Icons.refresh,
                    size: 16,
                    semanticLabel: 'Refresh',
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isFetchingRuntimeLogs
                      ? null
                      : () => _fetchRuntimeLogs(background: false),
                  icon: _isFetchingRuntimeLogs
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.dns, size: 16),
                  label: Text(
                    _isFetchingRuntimeLogs
                        ? 'Fetching runtime logs...'
                        : 'Fetch runtime logs',
                  ),
                ),
                const Spacer(),
                const Text('Live stream'),
                const SizedBox(width: 4),
                Switch(
                  key: const Key('log-runtime-stream-switch'),
                  value: _runtimeStreamingEnabled,
                  onChanged: (value) {
                    setState(() {
                      _runtimeStreamingEnabled = value;
                      _runtimeLogStatus = value
                          ? 'Streaming runtime logs...'
                          : 'Runtime log streaming paused.';
                    });
                    if (value) {
                      _startRuntimeStreaming();
                      unawaited(_fetchRuntimeLogs(background: true));
                    } else {
                      _stopRuntimeStreaming();
                    }
                  },
                ),
                if (_runtimeStreamingEnabled &&
                    secondsUntilNextRuntimeRefresh != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    'Next refresh in ${secondsUntilNextRuntimeRefresh}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            if (runtimeLogStatus != null) ...[
              const SizedBox(height: 4),
              Text(
                runtimeLogStatus,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectionArea(
                  child: visibleLogText.isEmpty
                      ? const AppEmptyStateView(
                          key: Key('runtime-log-empty-state'),
                          icon: Icons.receipt_long_outlined,
                          title: 'No runtime logs yet',
                          message:
                              'Fetch runtime logs when you need the latest app output.',
                        )
                      : SingleChildScrollView(
                          child: SelectableText(
                            visibleLogText,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DeploymentLogSummary extends ConsumerStatefulWidget {
  const _DeploymentLogSummary();

  @override
  ConsumerState<_DeploymentLogSummary> createState() =>
      _DeploymentLogSummaryState();
}

class _DeploymentLogSummaryState extends ConsumerState<_DeploymentLogSummary> {
  final TextEditingController _filterController = TextEditingController();
  String _filter = '';
  int _refreshTick = 0;

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  bool _isDeploymentRecord(TerminalLogRecord record) {
    return record.taskType == 'app_deploy' || record.source == 'app_deploy';
  }

  @override
  Widget build(BuildContext context) {
    final selectedProject = ref.watch(selectedProjectProvider);
    final selectedServer = ref.watch(selectedServerProvider);
    final scope = WorkspaceScope.fromSelection(selectedProject, selectedServer);
    final logsFuture = scope == null
        ? Future.value(const <TerminalLogRecord>[])
        : ref
              .watch(terminalLogRepositoryProvider)
              .listRecentLogsForScope(
                projectId: scope.projectId,
                serverId: scope.serverId,
                limit: 1200,
              );

    return FutureBuilder<List<TerminalLogRecord>>(
      key: ValueKey(_refreshTick),
      future: logsFuture,
      builder: (context, snapshot) {
        final logs = snapshot.data ?? const <TerminalLogRecord>[];
        final deploymentLogs = latestDeploymentAttemptLogs(
          logs.where(_isDeploymentRecord).toList(growable: false),
        );
        final outcome = deploymentLogOutcome(deploymentLogs);
        final normalizedFilter = _filter.trim().toLowerCase();
        final filteredLogs = normalizedFilter.isEmpty
            ? deploymentLogs
            : deploymentLogs
                  .where((record) {
                    final haystack =
                        '${record.renderedLine}\n${record.source}\n${record.taskType ?? ''}'
                            .toLowerCase();
                    return haystack.contains(normalizedFilter);
                  })
                  .toList(growable: false);
        final visibleLogText = filteredLogs
            .map((record) => record.renderedLine)
            .join('\n');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('deployment-log-filter-field'),
              controller: _filterController,
              onChanged: (value) => setState(() {
                _filter = value;
              }),
              decoration: InputDecoration(
                hintText: 'Filter deployment logs by keyword',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _filter.trim().isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _filterController.clear();
                          setState(() {
                            _filter = '';
                          });
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${filteredLogs.length} log lines',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () {
                    setState(() {
                      _refreshTick += 1;
                    });
                  },
                  icon: const Icon(
                    Icons.refresh,
                    size: 16,
                    semanticLabel: 'Refresh',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (outcome != null) ...[
              Container(
                key: const Key('deployment-log-latest-outcome'),
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: outcome.kind == DeploymentLogOutcomeKind.failed
                      ? Theme.of(context).colorScheme.errorContainer
                      : Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      outcome.label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      outcome.details,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectionArea(
                  child: visibleLogText.isEmpty
                      ? Text(
                          'No deployment logs yet.',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : SingleChildScrollView(
                          child: SelectableText(
                            visibleLogText,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
