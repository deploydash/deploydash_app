part of '../server_management_view.dart';

class _SystemTab extends ConsumerStatefulWidget {
  const _SystemTab(
    this.server, {
    this.onTerminalLine,
    this.onRemoveServer,
    this.pickSshKeyFile,
    this.importSshKeyFile,
  });

  final Server? server;
  final ServerTerminalLineWriter? onTerminalLine;
  final Future<void> Function()? onRemoveServer;
  final ServerSshKeyPicker? pickSshKeyFile;
  final ServerSshKeyImporter? importSshKeyFile;

  @override
  ConsumerState<_SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends ConsumerState<_SystemTab> {
  static const List<String> _fallbackTimezones = <String>[
    'UTC',
    'Europe/London',
    'America/New_York',
    'America/Los_Angeles',
    'Asia/Kolkata',
  ];
  static const List<String> _maintenanceTimes = <String>[
    '00:00',
    '01:00',
    '02:00',
    '03:00',
    '04:00',
    '05:00',
    '06:00',
  ];

  late ServerSystemConfig _baselineConfig;
  late ServerSystemConfig _stagedConfig;
  late final TextEditingController _serverHostController;
  late final TextEditingController _sshPortController;
  bool _isSavingConnectionHost = false;
  bool _isRefreshing = false;
  bool _isApplying = false;
  bool _isRestarting = false;
  bool _isReplacingSshKey = false;
  bool _isRemovingServer = false;
  String? _connectionHostError;
  String? _connectionHostMessage;
  String? _statusMessage;
  String? _statusError;
  String? _sshKeyStatusMessage;
  String? _sshKeyDisplayName;
  ServerRebootStatus _rebootStatus = ServerRebootStatus.none;

  @override
  void initState() {
    super.initState();
    _serverHostController = TextEditingController();
    _sshPortController = TextEditingController();
    _hydrateFromServer();
    unawaited(_refreshSystemSettings());
  }

  @override
  void didUpdateWidget(covariant _SystemTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server?.id != widget.server?.id ||
        oldWidget.server?.host != widget.server?.host) {
      _hydrateFromServer();
      unawaited(_refreshSystemSettings());
    }
  }

  @override
  void dispose() {
    _serverHostController.dispose();
    _sshPortController.dispose();
    super.dispose();
  }

  void _hydrateFromServer() {
    final config = widget.server?.systemConfig ?? ServerSystemConfig.defaults;
    _baselineConfig = config;
    _stagedConfig = config;
    _serverHostController.text = widget.server?.host ?? '';
    _sshPortController.text = config.sshPort.toString();
    _connectionHostError = null;
    _connectionHostMessage = null;
    _statusMessage = null;
    _statusError = null;
    _sshKeyStatusMessage = null;
    _sshKeyDisplayName = _defaultSshKeyLabel(widget.server);
    _rebootStatus = ServerRebootStatus.none;
  }

  String? _defaultSshKeyLabel(Server? server) {
    if (server?.authMethod != ServerAuthMethod.sshKey) {
      return null;
    }
    return 'Imported key stored in Deploy Dash';
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  ServerSystemConfig _configFromPayload(Map<String, dynamic> payload) {
    final settings = payload['settings'];
    if (settings is Map) {
      return ServerSystemConfig.fromJsonMap(mapFrom(settings));
    }
    return ServerSystemConfig.defaults;
  }

  void _appendSystemLogEvent(Map<String, dynamic> event) {
    final writer = widget.onTerminalLine;
    if (writer == null) {
      return;
    }
    final message = event['message']?.toString().trim();
    if (message == null || message.isEmpty) {
      return;
    }
    final eventType = event['type']?.toString().trim();
    final detail = event['level']?.toString().toLowerCase() == 'debug';
    writer(
      message,
      detail: detail,
      source: eventType == null || eventType.isEmpty
          ? 'system'
          : 'system:$eventType',
      taskType: 'system',
    );
  }

  bool get _isDirty {
    // coverage-gate: system_root_login_dirty
    final rootLoginChanged =
        _baselineConfig.rootLoginMode != _stagedConfig.rootLoginMode;
    // end coverage-gate
    return rootLoginChanged ||
        _baselineConfig.passwordAuthEnabled !=
            _stagedConfig.passwordAuthEnabled ||
        _baselineConfig.sshPort != _stagedConfig.sshPort ||
        _baselineConfig.timezone != _stagedConfig.timezone ||
        (_baselineConfig.swapGb - _stagedConfig.swapGb).abs() > 0.01 ||
        _baselineConfig.automaticSecurityUpdatesEnabled !=
            _stagedConfig.automaticSecurityUpdatesEnabled ||
        _baselineConfig.autoRebootEnabled != _stagedConfig.autoRebootEnabled ||
        _baselineConfig.maintenanceTime != _stagedConfig.maintenanceTime;
  }

  Future<void> _refreshSystemSettings() async {
    final server = widget.server;
    if (server == null) {
      setState(() {
        _statusError = 'No server selected.';
      });
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (!mounted) {
      return;
    }
    if (connection == null) {
      setState(() {
        _statusError = 'Server credentials are incomplete.';
      });
      return;
    }

    setState(() {
      _isRefreshing = true;
      _statusError = null;
      _statusMessage = null;
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'system_status',
                    connection: connection,
                    params: const <String, dynamic>{'dry_run': false},
                    onEvent: _appendSystemLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        final config = _configFromPayload(result);
        final rebootStatus = serverRebootStatusFromPayload(result);
        await ref
            .read(serverCatalogProvider.notifier)
            .updateSelectedServerSystemConfig(config);
        if (!mounted) {
          return;
        }
        setState(() {
          _baselineConfig = config;
          _stagedConfig = config;
          _sshPortController.text = config.sshPort.toString();
          _rebootStatus = rebootStatus;
          _statusMessage =
              result['msg']?.toString() ?? 'System settings refreshed.';
          _statusError = null;
          _isRefreshing = false;
        });
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ?? 'Failed to refresh system settings.';
          _isRefreshing = false;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Failed to refresh system settings: $error';
        _isRefreshing = false;
      });
    }
  }

  Future<bool> _confirmApplyIfRisky() async {
    final enablingRootPassword =
        _stagedConfig.rootLoginMode == ServerRootLoginMode.passwordAllowed &&
        _baselineConfig.rootLoginMode != ServerRootLoginMode.passwordAllowed;
    final risky =
        _baselineConfig.sshPort != _stagedConfig.sshPort ||
        _baselineConfig.rootLoginMode != _stagedConfig.rootLoginMode ||
        _baselineConfig.passwordAuthEnabled !=
            _stagedConfig.passwordAuthEnabled;
    if (!risky) {
      return true;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AppConfirmDialog(
          title: enablingRootPassword
              ? 'Allow password login as root?'
              : 'Apply risky SSH changes?',
          description: enablingRootPassword
              ? 'This allows the root account to authenticate with a password '
                    'when password authentication is enabled. Deploy Dash will '
                    'verify connectivity and restore the exact SSH backup on failure.'
              : 'You changed SSH authentication or port settings. '
                    'Deploy Dash will verify connectivity and restore the exact '
                    'SSH backup on failure.',
          confirmLabel: 'Apply',
          cancelLabel: 'Cancel',
          // Empty callback: the caller acts on the popped bool (D-70).
          onConfirm: () {},
        );
      },
    );
    return result == true;
  }

  /// Restarts only after the user accepts downtime and the backend proves recovery.
  Future<void> _restartServer() async {
    final server = widget.server;
    if (server == null) {
      setState(() {
        _statusError = 'No server selected.';
      });
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (!mounted) {
      return;
    }
    if (connection == null) {
      setState(() {
        _statusError = 'Server credentials are incomplete.';
      });
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restart server now?'),
        content: const Text(
          'The server and its applications will have brief downtime. '
          'Deploy Dash will wait for SSH to return, then verify Docker, '
          'managed containers, firewall rules, swap, and SSH.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restart server'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() {
      _isRestarting = true;
      _statusError = null;
      _statusMessage = null;
    });
    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'system_restart',
                    connection: connection,
                    params: const <String, dynamic>{'dry_run': false},
                    onEvent: _appendSystemLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }
      final message = result['msg']?.toString();
      if (result['status'] == 'success') {
        setState(() {
          _rebootStatus = ServerRebootStatus.none;
          _statusMessage =
              message ?? 'Server restarted and health checks passed.';
        });
      } else {
        final details = result['details']?.toString().trim();
        setState(() {
          _statusError = details == null || details.isEmpty
              ? message ?? 'Failed to restart the server.'
              : '${message ?? 'Failed to restart the server.'} $details';
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Failed to restart the server: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRestarting = false;
        });
      }
    }
  }

  Future<void> _saveServerHost() async {
    final server = widget.server;
    if (server == null) {
      setState(() {
        _connectionHostError = 'No server selected.';
        _connectionHostMessage = null;
      });
      return;
    }

    final normalizedHost = normalizeHostInput(_serverHostController.text);
    final validationError = validateHostOrAddress(normalizedHost);
    if (validationError != null) {
      setState(() {
        _connectionHostError = validationError;
        _connectionHostMessage = null;
      });
      return;
    }

    if (normalizedHost == server.host) {
      setState(() {
        _connectionHostError = null;
        _connectionHostMessage = 'This server already uses that address.';
      });
      return;
    }

    setState(() {
      _isSavingConnectionHost = true;
      _connectionHostError = null;
      _connectionHostMessage = null;
    });

    try {
      await ref
          .read(serverCatalogProvider.notifier)
          .updateSelectedServerConnectionHost(normalizedHost);
      if (!mounted) {
        return;
      }
      setState(() {
        _serverHostController.text = normalizedHost;
        _connectionHostMessage =
            'Server address saved. Future actions will connect to '
            '$normalizedHost.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _connectionHostError = 'Couldn’t save server address: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSavingConnectionHost = false;
        });
      }
    }
  }

  Future<void> _applySystemSettings() async {
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
        _statusError = 'Server credentials are incomplete.';
      });
      return;
    }
    if (!_isDirty) {
      setState(() {
        _statusMessage = 'No changes to apply.';
        _statusError = null;
      });
      return;
    }

    final confirmed = await _confirmApplyIfRisky();
    if (!confirmed) {
      return;
    }

    setState(() {
      _isApplying = true;
      _statusError = null;
      _statusMessage = null;
    });

    try {
      final result =
          (await ref
                  .read(sshServiceProvider)
                  .runWorkflow(
                    workflowId: 'server',
                    operationId: 'system_apply',
                    connection: connection,
                    params: <String, dynamic>{
                      'dry_run': false,
                      'settings': stagedSystemSettingsPayload(_stagedConfig),
                    },
                    onEvent: _appendSystemLogEvent,
                  ))
              .diagnosticPayload;
      if (!mounted) {
        return;
      }

      if (result['status'] == 'success') {
        final appliedSettings = result['applied_settings'];
        final appliedConfig = appliedSettings is Map
            ? ServerSystemConfig.fromJsonMap(mapFrom(appliedSettings))
            : _stagedConfig;
        await ref
            .read(serverCatalogProvider.notifier)
            .updateSelectedServerSystemConfig(appliedConfig);

        final connectionUpdate = result['connection_update'];
        if (connectionUpdate is Map) {
          final portRaw = connectionUpdate['port'];
          int? port;
          if (portRaw is int) {
            port = portRaw;
          } else if (portRaw is String) {
            port = int.tryParse(portRaw.trim());
          }
          if (port != null && port >= 1 && port <= 65535) {
            await ref
                .read(serverCatalogProvider.notifier)
                .updateSelectedServerConnectionPort(port);
          }
        }

        if (!mounted) {
          return;
        }
        final appliedMessage =
            result['msg']?.toString() ?? 'System settings applied.';
        setState(() {
          _baselineConfig = appliedConfig;
          _stagedConfig = appliedConfig;
          _sshPortController.text = appliedConfig.sshPort.toString();
          _statusMessage = appliedMessage;
          _statusError = null;
          _isApplying = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(appliedMessage)));
      } else {
        setState(() {
          _statusError =
              result['msg']?.toString() ?? 'Failed to apply system settings.';
          _isApplying = false;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Failed to apply system settings: $error';
        _isApplying = false;
      });
    }
  }

  void _setSshPortFromText(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 1 || parsed > 65535) {
      return;
    }
    setState(() {
      _stagedConfig = copySystemConfig(_stagedConfig, sshPort: parsed);
    });
  }

  Future<void> _showSshKeyImportError(Object error) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AppDialogScaffold(
          title: 'Couldn\'t import SSH key',
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
          child: Text(
            'Deploy Dash could not read the selected private key file.\n\n$error',
          ),
        );
      },
    );
  }

  Future<void> _showSshKeyImportSuccess(String fileName) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AppDialogScaffold(
          title: 'SSH key updated',
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
          child: Text(
            'Deploy Dash imported $fileName and saved it in the encrypted '
            'local database. Future SSH connections will use this key.',
          ),
        );
      },
    );
  }

  Future<void> _replaceStoredSshKey() async {
    final server = widget.server;
    if (server == null || server.authMethod != ServerAuthMethod.sshKey) {
      return;
    }

    setState(() {
      _isReplacingSshKey = true;
      _sshKeyStatusMessage = null;
    });

    final result = await replaceStoredSshKeyWithDependencies(
      pickFile:
          widget.pickSshKeyFile ??
          () => openFile(confirmButtonText: 'Select key'),
      importFile: widget.importSshKeyFile ?? readImportedSshKeyFile,
      saveImportedKey: ({required privateKey, publicKey}) {
        return ref
            .read(serverCatalogProvider.notifier)
            .updateSelectedServerImportedSshKey(
              privateKey: privateKey,
              publicKey: publicKey,
            );
      },
    );

    if (!mounted) {
      return;
    }

    if (result.cancelled) {
      setState(() {
        _isReplacingSshKey = false;
      });
      return;
    }

    final importedKey = result.importedKey;
    if (importedKey != null) {
      final fileName = importedKey.fileName;
      setState(() {
        _sshKeyDisplayName = fileName;
        _sshKeyStatusMessage =
            'SSH key updated. Future connections will use the new key.';
        _isReplacingSshKey = false;
      });
      await _showSshKeyImportSuccess(fileName);
      return;
    }

    setState(() {
      _isReplacingSshKey = false;
    });
    // Kept: `SshKeyReplacementResult` encodes its three states in named
    // constructors but declares all three fields nullable, so the type cannot
    // say that a result which is neither cancelled nor successful carries an
    // error. Making it sealed is recorded under Discovered work.
    await _showSshKeyImportError(result.error!);
  }

  Future<void> _removeServer() async {
    final handler = widget.onRemoveServer;
    if (handler == null || _isRemovingServer) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const AppDestructiveConfirmDialog(
        title: 'Remove this server?',
        description:
            'This removes the saved server from Deploy Dash so you can '
            'reconnect it from scratch. It does not erase anything on the '
            'server itself.',
        confirmLabel: 'Remove server',
        confirmButtonKey: Key('system-remove-server-confirm-button'),
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    setState(() {
      _isRemovingServer = true;
      _statusError = null;
    });

    try {
      await handler();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusError = 'Couldn’t remove this server: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isRemovingServer = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Hoisted so the `!= null` checks promote them; neither a widget field nor
    // a State field is ever promoted.
    final server = widget.server;
    final sshKeyStatusMessage = _sshKeyStatusMessage;
    final timezoneOptions = <String>{
      ..._fallbackTimezones,
      _stagedConfig.timezone,
    }.toList(growable: false)..sort();
    final maintenanceOptions = <String>{
      ..._maintenanceTimes,
      _stagedConfig.maintenanceTime,
    }.toList(growable: false)..sort();
    final statusLine = _statusError ?? _statusMessage;
    final rebootPackageSummary = _rebootStatus.packages.isNotEmpty
        ? 'Packages: ${_rebootStatus.packages.join(', ')}'
        : _rebootStatus.packagesReadable
        ? 'Ubuntu did not name the packages that require the restart.'
        : 'The package list could not be read from the server.';
    final connectionHostLine = _connectionHostError ?? _connectionHostMessage;
    final normalizedConnectionHost = normalizeHostInput(
      _serverHostController.text,
    );
    final canSaveConnectionHost =
        !_isSavingConnectionHost &&
        server != null &&
        normalizedConnectionHost.isNotEmpty &&
        normalizedConnectionHost != server.host;

    final showSystemToolbar = _isDirty || _isApplying;
    final systemToolbar = AppWorkspaceToolbar(
      children: [
        FilledButton.icon(
          key: const Key('system-apply-button'),
          onPressed: (_isApplying || _isRefreshing || !_isDirty)
              ? null
              : _applySystemSettings,
          icon: _isApplying
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_rounded, size: 16),
          label: const Text('Apply changes'),
        ),
        if (_isDirty)
          Text(
            'Unsaved changes',
            style: theme.textTheme.bodySmall?.copyWith(
              color: YaruColors.orange,
            ),
          ),
      ],
    );

    return Column(
      key: const Key('server-management-system-tab'),
      children: [
        Expanded(
          child: ListView(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  key: const Key('system-refresh-button'),
                  tooltip: 'Refresh system settings',
                  onPressed: _isRefreshing ? null : _refreshSystemSettings,
                  icon: _isRefreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(YaruIcons.refresh),
                ),
              ),
              if (statusLine != null)
                Text(
                  statusLine,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _statusError != null ? YaruColors.red : null,
                  ),
                ),
              if (_rebootStatus.required) ...[
                Card(
                  key: const Key('system-reboot-required-card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Security updates need a server restart',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Updates are installed on disk but will not fully '
                          'protect this server until it restarts.',
                        ),
                        const SizedBox(height: 6),
                        Text(rebootPackageSummary),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              key: const Key('system-restart-server-button'),
                              onPressed: _isRestarting ? null : _restartServer,
                              icon: _isRestarting
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.restart_alt, size: 16),
                              label: Text(
                                _isRestarting ? 'Restarting' : 'Restart now',
                              ),
                            ),
                            TextButton(
                              key: const Key(
                                'system-enable-auto-restarts-button',
                              ),
                              onPressed: _stagedConfig.autoRebootEnabled
                                  ? null
                                  : () {
                                      setState(() {
                                        _stagedConfig = copySystemConfig(
                                          _stagedConfig,
                                          autoRebootEnabled: true,
                                        );
                                      });
                                    },
                              child: const Text('Turn on automatic restarts'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              AppDetailPane(
                title: 'Connection details',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Change the hostname or IP address Deploy Dash uses for SSH. '
                      'This keeps the same saved server and linked projects.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('system-server-host-input'),
                      controller: _serverHostController,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        helperText:
                            'Use a direct DNS-only hostname or the server IP address.',
                      ),
                      onChanged: (_) {
                        setState(() {
                          _connectionHostError = null;
                          _connectionHostMessage = null;
                        });
                      },
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          key: const Key('system-save-server-host-button'),
                          onPressed: canSaveConnectionHost
                              ? _saveServerHost
                              : null,
                          icon: _isSavingConnectionHost
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_rounded, size: 16),
                          label: Text(
                            _isSavingConnectionHost
                                ? 'Saving address'
                                : 'Save address',
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            server == null
                                ? 'No server selected.'
                                : 'Current: ${server.host}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                    if (connectionHostLine != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        connectionHostLine,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _connectionHostError != null
                              ? YaruColors.red
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppWorkspaceSection(
                title: 'SSH Configuration',
                child: Column(
                  children: [
                    // coverage-gate: system_root_login_control
                    if (_stagedConfig.rootLoginMode ==
                        ServerRootLoginMode.restricted)
                      InputDecorator(
                        key: const Key('system-root-login-mode-readonly'),
                        decoration: const InputDecoration(
                          labelText: 'Root login',
                          helperText:
                              'This sshd policy is preserved as read-only. Change it '
                              'manually before choosing another mode here.',
                        ),
                        child: Text(
                          ServerRootLoginMode.restricted.displayLabel,
                        ),
                      )
                    else
                      DropdownButtonFormField<ServerRootLoginMode>(
                        key: const Key('system-root-login-mode-dropdown'),
                        initialValue: _stagedConfig.rootLoginMode,
                        decoration: const InputDecoration(
                          labelText: 'Root login',
                          helperText:
                              'Key only blocks root passwords. Password allowed is '
                              'the least secure option.',
                        ),
                        items:
                            const <ServerRootLoginMode>[
                                  ServerRootLoginMode.disabled,
                                  ServerRootLoginMode.keyOnly,
                                  ServerRootLoginMode.passwordAllowed,
                                ]
                                .map(
                                  (mode) =>
                                      DropdownMenuItem<ServerRootLoginMode>(
                                        value: mode,
                                        child: Text(mode.displayLabel),
                                      ),
                                )
                                .toList(growable: false),
                        onChanged: (value) {
                          setState(() {
                            _stagedConfig = copySystemConfig(
                              _stagedConfig,
                              rootLoginMode: value,
                            );
                          });
                        },
                      ),
                    // end coverage-gate
                    SwitchListTile(
                      key: const Key('system-password-auth-switch'),
                      value: _stagedConfig.passwordAuthEnabled,
                      onChanged: (value) {
                        setState(() {
                          _stagedConfig = copySystemConfig(
                            _stagedConfig,
                            passwordAuthEnabled: value,
                          );
                        });
                      },
                      title: const Text('Password Authentication'),
                      subtitle: Text(
                        _stagedConfig.passwordAuthEnabled
                            ? 'Enabled'
                            : 'Disabled',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('system-ssh-port-input'),
                      controller: _sshPortController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'SSH Port',
                        hintText: '22',
                      ),
                      onChanged: _setSshPortFromText,
                    ),
                    if (server?.authMethod == ServerAuthMethod.sshKey) ...[
                      const SizedBox(height: 12),
                      InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'SSH key',
                          helperText:
                              'Pick a private key file to replace the encrypted key '
                              'stored in Deploy Dash.',
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _sshKeyDisplayName ??
                                    'Imported key stored in Deploy Dash',
                                key: const Key('system-ssh-key-summary'),
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              key: const Key('system-replace-ssh-key-button'),
                              onPressed: _isReplacingSshKey
                                  ? null
                                  : _replaceStoredSshKey,
                              icon: _isReplacingSshKey
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.upload_file_rounded,
                                      size: 16,
                                    ),
                              label: Text(
                                _isReplacingSshKey
                                    ? 'Importing'
                                    : 'Replace key',
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (sshKeyStatusMessage != null) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            sshKeyStatusMessage,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppWorkspaceSection(
                title: 'Timezone',
                child: DropdownButtonFormField<String>(
                  key: const Key('system-timezone-dropdown'),
                  initialValue: _stagedConfig.timezone,
                  decoration: const InputDecoration(labelText: 'Timezone'),
                  items: timezoneOptions
                      .map(
                        (zone) => DropdownMenuItem<String>(
                          value: zone,
                          child: Text(zone),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _stagedConfig = copySystemConfig(
                        _stagedConfig,
                        timezone: value,
                      );
                    });
                  },
                ),
              ),
              const SizedBox(height: 16),
              AppWorkspaceSection(
                title: 'Swap file',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_stagedConfig.swapGb.toStringAsFixed(1)} GB selected',
                      key: const Key('system-swap-value'),
                      style: theme.textTheme.titleSmall,
                    ),
                    Slider(
                      key: const Key('system-swap-slider'),
                      value: _stagedConfig.swapGb.clamp(0, 8),
                      min: 0,
                      max: 8,
                      divisions: 16,
                      label: '${_stagedConfig.swapGb.toStringAsFixed(1)}GB',
                      semanticFormatterCallback: (value) =>
                          '${value.toStringAsFixed(1)} gigabytes of swap',
                      onChanged: (value) {
                        setState(() {
                          _stagedConfig = copySystemConfig(
                            _stagedConfig,
                            swapGb: value,
                          );
                        });
                      },
                    ),
                    Text(
                      'Recommended: 2GB for low-RAM servers to reduce OOM crashes.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AppWorkspaceSection(
                title: 'Maintenance Window',
                child: Column(
                  children: [
                    SwitchListTile(
                      value: _stagedConfig.automaticSecurityUpdatesEnabled,
                      onChanged: (value) {
                        setState(() {
                          _stagedConfig = copySystemConfig(
                            _stagedConfig,
                            automaticSecurityUpdatesEnabled: value,
                          );
                        });
                      },
                      title: const Text('Automatic Security Updates'),
                    ),
                    SwitchListTile(
                      value: _stagedConfig.autoRebootEnabled,
                      onChanged: (value) {
                        setState(() {
                          _stagedConfig = copySystemConfig(
                            _stagedConfig,
                            autoRebootEnabled: value,
                          );
                        });
                      },
                      title: const Text('Auto-Reboot for Security Updates'),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      key: const Key('system-maintenance-time-dropdown'),
                      initialValue: _stagedConfig.maintenanceTime,
                      items: maintenanceOptions
                          .map(
                            (time) => DropdownMenuItem<String>(
                              value: time,
                              child: Text(time),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _stagedConfig = copySystemConfig(
                            _stagedConfig,
                            maintenanceTime: value,
                          );
                        });
                      },
                      decoration: const InputDecoration(
                        labelText: 'Time (24-hour)',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _DockerStorageSection(
                server,
                key: ValueKey<String>(
                  'docker-storage-${server?.id ?? 'none'}-'
                  '${server?.host ?? 'none'}-'
                  '${server?.port ?? 0}',
                ),
                onTerminalLine: widget.onTerminalLine,
              ),
              const SizedBox(height: 16),
              AppWorkspaceSection(
                title: 'Remove server',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Remove this saved server from Deploy Dash if you need to '
                      'connect it again from scratch after rebuilding or '
                      'reinstalling it.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This does not erase anything on the server itself.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('system-remove-server-button'),
                      onPressed:
                          (_isRemovingServer || widget.onRemoveServer == null)
                          ? null
                          : _removeServer,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      icon: _isRemovingServer
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline_rounded, size: 16),
                      label: Text(
                        _isRemovingServer
                            ? 'Removing server'
                            : 'Remove this server',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (showSystemToolbar) systemToolbar,
      ],
    );
  }
}
