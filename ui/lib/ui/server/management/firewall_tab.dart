part of '../server_management_view.dart';

class _FirewallTab extends ConsumerStatefulWidget {
  const _FirewallTab(this.server, {this.onTerminalLine});

  final Server? server;
  final ServerTerminalLineWriter? onTerminalLine;

  @override
  ConsumerState<_FirewallTab> createState() => _FirewallTabState();
}

class _TwoUpRow extends StatelessWidget {
  const _TwoUpRow({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppWorkspaceBreakpoints.twoColumn) {
          return Column(children: [left, const SizedBox(height: 16), right]);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ],
        );
      },
    );
  }
}

class _FirewallTabState extends ConsumerState<_FirewallTab>
    with ServerScopedConsumerState<_FirewallTab> {
  static const String _firewallStatusRunKind = 'firewall_status_refresh';

  ServerFirewallConfig _config = ServerFirewallConfig.defaults;
  List<FirewallObservedPortView> _openPorts = <FirewallObservedPortView>[];
  bool _firewallEnabled = false;
  bool? _firewallIpv4Enabled;
  bool? _firewallIpv6Enabled;
  bool? _fail2banActive;
  bool? _fail2banEnabled;
  bool? _fail2banSshdJailActive;
  int? _fail2banCurrentlyBanned;
  int? _fail2banTotalFailed;
  bool _isRefreshing = false;
  bool _isApplying = false;
  bool _isCommitting = false;
  bool _isRollingBack = false;
  bool? _persistentRulesPresent;
  bool? _persistentRulesV4Present;
  bool? _persistentRulesV6Present;
  bool? _netfilterPersistentEnabled;
  String? _statusMessage;
  String? _statusError;
  String? _externalInterface;
  FirewallStagedStateView? _stagedState;
  late ServerFirewallConfig _lastAppliedConfig;
  ServerFirewallConfig? _preStageConfig;

  @override
  void initState() {
    super.initState();
    bindServerScope(widget.server);
    _config = widget.server?.firewallConfig ?? ServerFirewallConfig.defaults;
    _lastAppliedConfig = _config;
    unawaited(_refreshFirewallState());
  }

  @override
  void didUpdateWidget(covariant _FirewallTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server?.id != widget.server?.id) {
      bindServerScope(widget.server);
      _config = widget.server?.firewallConfig ?? ServerFirewallConfig.defaults;
      _lastAppliedConfig = _config;
      _preStageConfig = null;
      _openPorts = <FirewallObservedPortView>[];
      _stagedState = null;
      _firewallEnabled = false;
      _firewallIpv4Enabled = null;
      _firewallIpv6Enabled = null;
      _fail2banActive = null;
      _fail2banEnabled = null;
      _fail2banSshdJailActive = null;
      _fail2banCurrentlyBanned = null;
      _fail2banTotalFailed = null;
      _persistentRulesPresent = null;
      _persistentRulesV4Present = null;
      _persistentRulesV6Present = null;
      _netfilterPersistentEnabled = null;
      _statusMessage = null;
      _statusError = null;
      _externalInterface = null;
      unawaited(_refreshFirewallState());
    }
  }

  Future<void> _refreshFirewallState() async {
    final server = widget.server;
    if (server == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'No server selected.';
        _isRefreshing = false;
      });
      return;
    }

    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError =
            'This server is missing SSH access details. Update the connection first.';
        _isRefreshing = false;
      });
      return;
    }

    final run = captureServerRun(server: server, kind: _firewallStatusRunKind);
    setState(() {
      _isRefreshing = true;
      _statusError = null;
    });

    try {
      final sshService = ref.read(sshServiceProvider);
      final statusResult = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'status',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': buildFirewallSettings(
            _config,
            sshPort: widget.server?.port ?? 22,
          ),
        },
        onEvent: _appendFirewallLogEvent,
      )).diagnosticPayload;

      final portsResult = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'scan_open_ports',
        connection: connection,
        params: <String, dynamic>{'dry_run': false},
        onEvent: _appendFirewallLogEvent,
      )).diagnosticPayload;

      if (!isCurrentServerRun(run)) {
        return;
      }

      if (statusResult['status'] != 'success') {
        setState(() {
          _statusError =
              statusResult['msg']?.toString() ??
              'Unable to read firewall status.';
          _isRefreshing = false;
        });
        return;
      }

      final parsed = parseFirewallStatusViewModel(
        statusResult: statusResult,
        portsResult: portsResult,
      );
      setState(() {
        _firewallEnabled = parsed.firewallEnabled;
        _firewallIpv4Enabled = parsed.firewallIpv4Enabled;
        _firewallIpv6Enabled = parsed.firewallIpv6Enabled;
        _fail2banActive = parsed.fail2banActive;
        _fail2banEnabled = parsed.fail2banEnabled;
        _fail2banSshdJailActive = parsed.fail2banSshdJailActive;
        _fail2banCurrentlyBanned = parsed.fail2banCurrentlyBanned;
        _fail2banTotalFailed = parsed.fail2banTotalFailed;
        _persistentRulesPresent = parsed.persistentRulesPresent;
        _persistentRulesV4Present = parsed.persistentRulesV4Present;
        _persistentRulesV6Present = parsed.persistentRulesV6Present;
        _netfilterPersistentEnabled = parsed.netfilterPersistentEnabled;
        _statusMessage = parsed.statusMessage;
        _externalInterface = parsed.externalInterface;
        _stagedState = parsed.stagedState;
        _openPorts = parsed.openPorts;
        _statusError = parsed.statusError;
        _isRefreshing = false;
      });
    } catch (error) {
      if (!isCurrentServerRun(run)) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t refresh the Security workspace. $error';
        _isRefreshing = false;
      });
    }
  }

  Future<void> _updateConfig(ServerFirewallConfig next) async {
    setState(() {
      _config = next;
    });

    final server = widget.server;
    if (server == null) {
      return;
    }

    try {
      await ref
          .read(serverCatalogProvider.notifier)
          .updateSelectedServerFirewallConfig(next);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError =
            'Couldn’t save these security settings on this device. $error';
      });
    }
  }

  bool get _hasPendingConfigChanges =>
      jsonEncode(_config.toJsonMap()) !=
      jsonEncode(_lastAppliedConfig.toJsonMap());

  Future<void> _toggleCurated({
    required bool? allowPostgres,
    required bool? allowDns,
    required bool? allowSmtp,
    required bool? allowMailReceive,
    required bool? strictMode,
  }) async {
    final next = updateCuratedFirewallConfig(
      _config,
      allowPostgres: allowPostgres,
      allowDns: allowDns,
      allowSmtp: allowSmtp,
      allowMailReceive: allowMailReceive,
    );
    await _updateConfig(next);
  }

  Future<void> _updateRollbackTimeout(int seconds) async {
    final next = updateRollbackTimeoutConfig(_config, seconds);
    await _updateConfig(next);
  }

  Future<void> _addOrUpdateCustomRule({
    ServerFirewallCustomRule? current,
  }) async {
    final result = await _showCustomRuleDialog(current: current);
    if (result == null) {
      return;
    }

    final next = upsertCustomRuleConfig(_config, result, current: current);
    await _updateConfig(next);
  }

  Future<void> _deleteCustomRule(ServerFirewallCustomRule current) async {
    final next = removeCustomRuleConfig(_config, current);
    await _updateConfig(next);
  }

  Future<void> _applyFirewallChanges() async {
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
            'This server is missing SSH access details. Update the connection first.';
      });
      return;
    }

    setState(() {
      _isApplying = true;
      _statusError = null;
    });

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'apply_staged',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': buildFirewallSettings(
            _config,
            sshPort: widget.server?.port ?? 22,
          ),
        },
        onEvent: _appendFirewallLogEvent,
      )).diagnosticPayload;

      if (!mounted) {
        return;
      }

      if (result['status'] == 'success') {
        setState(() {
          _statusMessage =
              result['msg']?.toString() ??
              'Firewall rules staged successfully.';
          _stagedState = parseFirewallStagedState(result['staged_state']);
          _preStageConfig = _lastAppliedConfig;
          _lastAppliedConfig = _config;
        });
        await _refreshFirewallState();
        // One report per invocation: the outcome is known here.
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.apply,
              outcome: DataOperationOutcome.success,
            );
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ??
              'Couldn’t preview these security changes.';
        });
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.apply,
              outcome: DataOperationOutcome.failure,
            );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t preview these security changes. $error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackFirewallEvent(
            action: FirewallAction.apply,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (mounted) {
        setState(() {
          _isApplying = false;
        });
      }
    }
  }

  Future<void> _commitStagedFirewallChanges() async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }

    setState(() {
      _isCommitting = true;
      _statusError = null;
    });

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'commit',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': <String, dynamic>{
            ...buildFirewallSettings(
              _config,
              sshPort: widget.server?.port ?? 22,
            ),
            'stage_token': _stagedState?.token,
          },
        },
        onEvent: _appendFirewallLogEvent,
      )).diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        setState(() {
          _statusMessage = result['msg']?.toString() ?? 'Firewall committed.';
          _stagedState = null;
          _preStageConfig = null;
        });
        await _refreshFirewallState();
        // One report per invocation: the outcome is known here.
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.commit,
              outcome: DataOperationOutcome.success,
            );
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ??
              'Couldn’t save these security changes.';
        });
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.commit,
              outcome: DataOperationOutcome.failure,
            );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t save these security changes. $error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackFirewallEvent(
            action: FirewallAction.commit,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (mounted) {
        setState(() {
          _isCommitting = false;
        });
      }
    }
  }

  Future<void> _rollbackFirewallChanges() async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }

    setState(() {
      _isRollingBack = true;
      _statusError = null;
    });

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'rollback',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': <String, dynamic>{
            ...buildFirewallSettings(
              _config,
              sshPort: widget.server?.port ?? 22,
            ),
            'stage_token': _stagedState?.token,
          },
        },
        onEvent: _appendFirewallLogEvent,
      )).diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        setState(() {
          _statusMessage =
              result['msg']?.toString() ?? 'Firewall rollback complete.';
          _stagedState = null;
          _lastAppliedConfig = _preStageConfig ?? _lastAppliedConfig;
          _preStageConfig = null;
        });
        await _refreshFirewallState();
        // One report per invocation: the outcome is known here.
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.rollback,
              outcome: DataOperationOutcome.success,
            );
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ??
              'Couldn’t roll back these security changes.';
        });
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.rollback,
              outcome: DataOperationOutcome.failure,
            );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t roll back these security changes. $error';
      });
      ref
          .read(appAnalyticsServiceProvider)
          .trackFirewallEvent(
            action: FirewallAction.rollback,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (mounted) {
        setState(() {
          _isRollingBack = false;
        });
      }
    }
  }

  void _appendFirewallLogEvent(Map<String, dynamic> event) {
    final eventType = event['type']?.toString().trim();
    final message = event['message']?.toString().trim();
    if (message == null || message.isEmpty) {
      return;
    }
    final prefix = eventType == null || eventType.isEmpty
        ? 'firewall'
        : 'firewall:$eventType';
    widget.onTerminalLine?.call(
      '[$prefix] $message',
      detail: true,
      source: 'firewall',
      taskType: 'firewall',
    );
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  List<int> _lockedPortsForServer() {
    return lockedPortsForSshPort(widget.server?.port ?? 22);
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int raw) => raw.toString().padLeft(2, '0');
    final year = value.year.toString().padLeft(4, '0');
    final month = twoDigits(value.month);
    final day = twoDigits(value.day);
    final hour = twoDigits(value.hour);
    final minute = twoDigits(value.minute);
    final second = twoDigits(value.second);
    return '$year-$month-$day $hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` checks below promote them. A field cannot be
    // promoted -- another isolate could in principle reassign it between the
    // check and the read -- so reading a field through `!` is the shape this
    // pattern exists to avoid.
    final stagedState = _stagedState;
    final stagedExpiresAt = stagedState?.expiresAt;
    final fail2banEnabled = _fail2banEnabled;
    final firewallIpv4Enabled = _firewallIpv4Enabled;
    final firewallIpv6Enabled = _firewallIpv6Enabled;
    final persistentRulesPresent = _persistentRulesPresent;
    final netfilterPersistentEnabled = _netfilterPersistentEnabled;
    final externalInterface = _externalInterface?.trim();
    final statusMessage = _statusMessage?.trim();
    final statusError = _statusError?.trim();
    final lockedPorts = _lockedPortsForServer();
    final sshPort = widget.server?.port ?? 22;
    final allowedPorts = firewallAllowedPortSummary(_config, sshPort: sshPort);
    final protectionTiles = buildProtectionMetrics(
      sshPort: sshPort,
      fail2banActive: _fail2banActive,
      fail2banSshdJailActive: _fail2banSshdJailActive,
      fail2banCurrentlyBanned: _fail2banCurrentlyBanned,
      fail2banTotalFailed: _fail2banTotalFailed,
    );
    final lockedRows = <DataRow>[
      DataRow(
        cells: [
          DataCell(Text('$sshPort')),
          const DataCell(Text('TCP')),
          const DataCell(Text('SSH access (required by Deploy Dash)')),
        ],
      ),
      const DataRow(
        cells: [
          DataCell(Text('80')),
          DataCell(Text('TCP')),
          DataCell(Text('HTTP')),
        ],
      ),
      const DataRow(
        cells: [
          DataCell(Text('443')),
          DataCell(Text('TCP')),
          DataCell(Text('HTTPS')),
        ],
      ),
    ];
    for (final lockedPort in lockedPorts) {
      if (lockedPort == sshPort || lockedPort == 80 || lockedPort == 443) {
        continue;
      }
      lockedRows.add(
        DataRow(
          cells: [
            DataCell(Text('$lockedPort')),
            const DataCell(Text('TCP')),
            const DataCell(Text('Locked required port')),
          ],
        ),
      );
    }

    return ListView(
      key: const Key('server-management-firewall-tab'),
      children: [
        AppWorkspaceSection(
          title: 'SSH port protection',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Deploy Dash keeps SSH reachable on the configured port and '
                'uses fail2ban to slow down repeated login attempts.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: protectionTiles
                    .map(
                      (metric) => _CompactMetricTile(
                        label: metric.label,
                        value: metric.value,
                      ),
                    )
                    .toList(growable: false),
              ),
              if (fail2banEnabled != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Starts on boot: ${fail2banEnabled ? 'Enabled' : 'Disabled'}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _TwoUpRow(
          left: AppWorkspaceSection(
            title: 'Firewall status',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      label: Text(_firewallEnabled ? 'Enabled' : 'Not active'),
                      avatar: Icon(
                        _firewallEnabled ? Icons.shield : Icons.shield_outlined,
                        size: 18,
                      ),
                    ),
                    if (firewallIpv4Enabled != null)
                      Chip(
                        label: Text(
                          'IPv4: ${firewallIpv4Enabled ? 'Active' : 'Not active'}',
                        ),
                        avatar: const Icon(Icons.public, size: 18),
                      ),
                    if (firewallIpv6Enabled != null)
                      Chip(
                        label: Text(
                          'IPv6: ${firewallIpv6Enabled ? 'Active' : 'Not active'}',
                        ),
                        avatar: const Icon(Icons.public_off, size: 18),
                      ),
                    if (persistentRulesPresent != null)
                      Chip(
                        label: Text(
                          'Persistence: '
                          '${persistentRulesPresent ? 'Ready' : 'Missing'}',
                        ),
                        avatar: Icon(
                          persistentRulesPresent
                              ? Icons.save_outlined
                              : Icons.warning_amber_rounded,
                          size: 18,
                        ),
                      ),
                    if (netfilterPersistentEnabled != null)
                      Chip(
                        label: Text(
                          'Restore on boot: '
                          '${netfilterPersistentEnabled ? 'Enabled' : 'Disabled'}',
                        ),
                        avatar: const Icon(Icons.restart_alt, size: 18),
                      ),
                    const Chip(
                      label: Text('Mode: Strict'),
                      avatar: Icon(Icons.lock_outline, size: 18),
                    ),
                    if (externalInterface != null &&
                        externalInterface.isNotEmpty)
                      Chip(
                        label: Text('Interface: $externalInterface'),
                        avatar: const Icon(Icons.router, size: 18),
                      ),
                  ],
                ),
                if (statusMessage != null && statusMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      statusMessage,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (statusError != null && statusError.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      statusError,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                if (_persistentRulesPresent == false)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Saved rule files: '
                      'IPv4 ${_persistentRulesV4Present == true ? 'present' : 'missing'}, '
                      'IPv6 ${_persistentRulesV6Present == true ? 'present' : 'missing'}.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                if (stagedState != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: theme.colorScheme.tertiaryContainer.withValues(
                          alpha: 0.35,
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.schedule),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Staged security changes pending',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Allowed ports: ${allowedPorts.join(', ')}',
                                  key: const Key(
                                    'firewall-staged-port-summary',
                                  ),
                                ),
                                Text(
                                  'Automatic rollback: '
                                  '${_config.rollbackTimeoutSeconds} seconds '
                                  'unless you commit.',
                                ),
                                if (stagedExpiresAt != null)
                                  Text(
                                    'Rollback deadline: '
                                    '${_formatDateTime(stagedExpiresAt)}',
                                  ),
                                AppTechnicalDetails(
                                  title: 'Technical details',
                                  child: SelectableText(
                                    'Stage token: ${stagedState.token}',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('firewall-refresh-button'),
                      onPressed: _isRefreshing ? null : _refreshFirewallState,
                      icon: _isRefreshing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                    FilledButton.icon(
                      key: const Key('firewall-apply-button'),
                      onPressed:
                          (_isApplying ||
                              _isCommitting ||
                              _isRollingBack ||
                              !_hasPendingConfigChanges ||
                              stagedState != null)
                          ? null
                          : _applyFirewallChanges,
                      icon: _isApplying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.shield),
                      label: const Text('Stage firewall changes'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('firewall-commit-button'),
                      onPressed:
                          (_isCommitting || _isApplying || stagedState == null)
                          ? null
                          : _commitStagedFirewallChanges,
                      icon: _isCommitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: const Text('Commit'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('firewall-rollback-button'),
                      onPressed:
                          (_isRollingBack || _isApplying || stagedState == null)
                          ? null
                          : _rollbackFirewallChanges,
                      icon: _isRollingBack
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.undo),
                      label: const Text('Rollback'),
                    ),
                  ],
                ),
                if (!_hasPendingConfigChanges && stagedState == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Change a service port, rollback timeout, or custom rule '
                      'before staging firewall changes.',
                      key: const Key('firewall-no-pending-changes'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          right: AppWorkspaceSection(
            title: 'Locked required ports',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'These ports are always allowed and cannot be edited.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Port')),
                      DataColumn(label: Text('Protocol')),
                      DataColumn(label: Text('Reason')),
                    ],
                    rows: lockedRows,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        AppWorkspaceSection(
          title: 'Service ports',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_outline),
                title: Text('Strict lockdown mode'),
                subtitle: Text(
                  'Always on. Unmatched inbound traffic is denied for the host '
                  'and Docker-published ports.',
                ),
              ),
              SwitchListTile.adaptive(
                key: const Key('firewall-curated-postgres'),
                contentPadding: EdgeInsets.zero,
                value: _config.allowPostgres,
                onChanged: (value) {
                  unawaited(
                    _toggleCurated(
                      allowPostgres: value,
                      allowDns: null,
                      allowSmtp: null,
                      allowMailReceive: null,
                      strictMode: null,
                    ),
                  );
                },
                title: const Text('PostgreSQL (5432/tcp)'),
              ),
              SwitchListTile.adaptive(
                key: const Key('firewall-curated-dns'),
                contentPadding: EdgeInsets.zero,
                value: _config.allowDns,
                onChanged: (value) {
                  unawaited(
                    _toggleCurated(
                      allowPostgres: null,
                      allowDns: value,
                      allowSmtp: null,
                      allowMailReceive: null,
                      strictMode: null,
                    ),
                  );
                },
                title: const Text('DNS (53/tcp, 53/udp)'),
              ),
              SwitchListTile.adaptive(
                key: const Key('firewall-curated-smtp'),
                contentPadding: EdgeInsets.zero,
                value: _config.allowSmtp,
                onChanged: (value) {
                  unawaited(
                    _toggleCurated(
                      allowPostgres: null,
                      allowDns: null,
                      allowSmtp: value,
                      allowMailReceive: null,
                      strictMode: null,
                    ),
                  );
                },
                title: const Text('SMTP submission (25/465/587 tcp)'),
              ),
              SwitchListTile.adaptive(
                key: const Key('firewall-curated-mail-receive'),
                contentPadding: EdgeInsets.zero,
                value: _config.allowMailReceive,
                onChanged: (value) {
                  unawaited(
                    _toggleCurated(
                      allowPostgres: null,
                      allowDns: null,
                      allowSmtp: null,
                      allowMailReceive: value,
                      strictMode: null,
                    ),
                  );
                },
                title: const Text('IMAP/POP3 receive (110/995/143/993 tcp)'),
              ),
              if (_config.customRules.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Custom rules', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Protocol')),
                      DataColumn(label: Text('Port range')),
                      DataColumn(label: Text('Source CIDR')),
                      DataColumn(label: Text('Description')),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Actions')),
                    ],
                    rows: _config.customRules
                        .map(
                          (rule) => DataRow(
                            cells: [
                              DataCell(Text(rule.protocol.toUpperCase())),
                              DataCell(
                                Text(
                                  rule.portStart == rule.portEnd
                                      ? '${rule.portStart}'
                                      : '${rule.portStart}-${rule.portEnd}',
                                ),
                              ),
                              DataCell(Text(rule.sourceCidr ?? 'Any')),
                              DataCell(Text(rule.description ?? '-')),
                              DataCell(
                                Text(rule.enabled ? 'Enabled' : 'Disabled'),
                              ),
                              DataCell(
                                Wrap(
                                  spacing: 8,
                                  children: [
                                    IconButton(
                                      key: Key('firewall-edit-${rule.id}'),
                                      tooltip: 'Edit rule',
                                      icon: const Icon(
                                        Icons.edit_outlined,
                                        semanticLabel: 'Edit rule',
                                      ),
                                      onPressed: () =>
                                          _addOrUpdateCustomRule(current: rule),
                                    ),
                                    IconButton(
                                      key: Key('firewall-delete-${rule.id}'),
                                      tooltip: 'Delete rule',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        semanticLabel: 'Delete rule',
                                      ),
                                      onPressed: () => _deleteCustomRule(rule),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                        .toList(growable: false),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  key: const Key('firewall-add-custom-rule'),
                  onPressed: () => _addOrUpdateCustomRule(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add custom rule'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Rollback timeout (seconds):'),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    key: const Key('firewall-rollback-timeout-field'),
                    value: _config.rollbackTimeoutSeconds,
                    items: const [60, 90, 120, 180, 300]
                        .map(
                          (seconds) => DropdownMenuItem<int>(
                            value: seconds,
                            child: Text('$seconds'),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      unawaited(_updateRollbackTimeout(value));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AppWorkspaceSection(
          title: 'Open ports inventory',
          child: _openPorts.isEmpty
              ? Text(
                  'No open ports found yet. Refresh to check again.',
                  style: theme.textTheme.bodyMedium,
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth <
                        AppWorkspaceBreakpoints.twoColumn) {
                      return Column(
                        key: const Key('firewall-open-port-cards'),
                        children: _openPorts
                            .map(
                              (entry) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _FirewallObservedPortCard(entry),
                              ),
                            )
                            .toList(growable: false),
                      );
                    }
                    return SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Address')),
                          DataColumn(label: Text('Protocol')),
                          DataColumn(label: Text('Port')),
                          DataColumn(label: Text('Source')),
                          DataColumn(label: Text('Owner')),
                          DataColumn(label: Text('Risk')),
                        ],
                        rows: _openPorts
                            .map(
                              (entry) => DataRow(
                                cells: [
                                  DataCell(Text(entry.bindAddress)),
                                  DataCell(Text(entry.protocol.toUpperCase())),
                                  DataCell(Text(entry.port)),
                                  DataCell(Text(entry.source)),
                                  DataCell(Text(entry.owner)),
                                  DataCell(Text(entry.risk)),
                                ],
                              ),
                            )
                            .toList(growable: false),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<ServerFirewallCustomRule?> _showCustomRuleDialog({
    ServerFirewallCustomRule? current,
  }) async {
    final portStartController = TextEditingController(
      text: current == null ? '' : '${current.portStart}',
    );
    final portEndController = TextEditingController(
      text: current == null ? '' : '${current.portEnd}',
    );
    final sourceController = TextEditingController(text: current?.sourceCidr);
    final descriptionController = TextEditingController(
      text: current?.description,
    );

    String protocol = current?.protocol ?? 'tcp';
    bool enabled = current?.enabled ?? true;
    String? validationError;

    final result = await showDialog<ServerFirewallCustomRule>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            // `validationError` is captured and reassigned by the callbacks
            // below, so it cannot be promoted where it is read; this rebuild's
            // value can.
            final currentValidationError = validationError;
            return AppFormDialog(
              key: const Key('firewall-custom-rule-dialog'),
              title: current == null ? 'Add custom rule' : 'Edit rule',
              // maxWidth default 420 == the hand-rolled SizedBox-420 wrapper
              // this routing deletes (D-70).
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('firewall-custom-save-button'),
                  onPressed: () {
                    final parsedStart =
                        int.tryParse(portStartController.text.trim()) ?? -1;
                    final parsedEnd =
                        int.tryParse(portEndController.text.trim()) ?? -1;
                    final source = sourceController.text.trim();
                    final description = descriptionController.text.trim();

                    if (parsedStart < 1 || parsedStart > 65535) {
                      setDialogState(() {
                        validationError =
                            'Port start must be between 1 and 65535.';
                      });
                      return;
                    }
                    if (parsedEnd < 1 || parsedEnd > 65535) {
                      setDialogState(() {
                        validationError =
                            'Port end must be between 1 and 65535.';
                      });
                      return;
                    }
                    if (parsedEnd < parsedStart) {
                      setDialogState(() {
                        validationError =
                            'Port end must be greater than or equal to start.';
                      });
                      return;
                    }
                    if (source.isNotEmpty && !_isValidSourceCidr(source)) {
                      setDialogState(() {
                        validationError =
                            'Source CIDR must be a valid IPv4 or IPv6 CIDR block.';
                      });
                      return;
                    }

                    Navigator.of(dialogContext).pop(
                      ServerFirewallCustomRule(
                        id:
                            current?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        protocol: protocol,
                        portStart: parsedStart,
                        portEnd: parsedEnd,
                        sourceCidr: source.isEmpty ? null : source,
                        description: description.isEmpty ? null : description,
                        enabled: enabled,
                      ),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('firewall-custom-protocol-field'),
                    initialValue: protocol,
                    items: const [
                      DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                      DropdownMenuItem(value: 'udp', child: Text('UDP')),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setDialogState(() {
                        protocol = value;
                      });
                    },
                    decoration: const InputDecoration(labelText: 'Protocol'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('firewall-custom-port-start-field'),
                          controller: portStartController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port start',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          key: const Key('firewall-custom-port-end-field'),
                          controller: portEndController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port end',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('firewall-custom-source-field'),
                    controller: sourceController,
                    decoration: const InputDecoration(
                      labelText: 'Source CIDR (optional)',
                      hintText: 'e.g. 203.0.113.0/24 or 2001:db8::/64',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('firewall-custom-description-field'),
                    controller: descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    key: const Key('firewall-custom-enabled-toggle'),
                    contentPadding: EdgeInsets.zero,
                    value: enabled,
                    onChanged: (value) {
                      setDialogState(() {
                        enabled = value;
                      });
                    },
                    title: const Text('Enabled'),
                  ),
                  if (currentValidationError != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        key: const Key('firewall-custom-validation-error'),
                        currentValidationError,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );

    return result;
  }

  bool _isValidSourceCidr(String value) {
    final trimmed = value.trim();
    final segments = trimmed.split('/');
    if (segments.isEmpty || segments.length > 2) {
      return false;
    }

    final address = InternetAddress.tryParse(segments.first);
    if (address == null) {
      return false;
    }

    if (segments.length == 2) {
      final prefix = int.tryParse(segments[1]);
      final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
      if (prefix == null || prefix < 0 || prefix > maxPrefix) {
        return false;
      }
    }
    return true;
  }
}

class _FirewallObservedPortCard extends StatelessWidget {
  const _FirewallObservedPortCard(this.entry);

  final FirewallObservedPortView entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: Key('firewall-open-port-${entry.protocol}-${entry.port}'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${entry.port}/${entry.protocol.toUpperCase()}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              AppStatusBadge(label: entry.risk),
            ],
          ),
          const SizedBox(height: 8),
          _LabeledValue(label: 'Address', value: entry.bindAddress),
          _LabeledValue(label: 'Source', value: entry.source),
          _LabeledValue(label: 'Owner', value: entry.owner),
          if (entry.observationCount > 1)
            Text(
              '${entry.observationCount} equivalent listeners grouped',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _LabeledValue extends StatelessWidget {
  const _LabeledValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value'),
    );
  }
}

class _FirewallStagedState {
  const _FirewallStagedState({required this.token, this.expiresAt});

  final String token;
  final DateTime? expiresAt;
}
