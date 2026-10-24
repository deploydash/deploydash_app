part of '../server_management_view.dart';

/// Decodes the public CA returned by the engine without trusting malformed data.
String? _decodePostgresCaCertificate(dynamic raw) {
  final encoded = raw?.toString().trim() ?? '';
  if (encoded.isEmpty) {
    return null;
  }
  try {
    return utf8.decode(base64Decode(encoded));
  } on FormatException {
    return null;
  }
}

extension _ServicesTabStatusOperations on _ServicesTabState {
  Future<void> _refreshWebServerStatus() async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final run = captureServerRun(
      server: server,
      kind: _ServicesTabState._webStatusRunKind,
    );
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }

    _patchService('proxy', (service) => service.copyWith(isBusy: true));
    final sshService = ref.read(sshServiceProvider);
    final response = await sshService.runWorkflow(
      workflowId: 'http',
      operationId: 'service_status',
      connection: connection,
      params: const <String, dynamic>{'dry_run': false},
    );

    if (!isCurrentServerRun(run)) {
      return;
    }
    switch (response) {
      case Ok<Map<String, dynamic>>(:final value):
        final serviceStatus = value['service_status'];
        final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(
          serviceStatus,
        );
        _patchService(
          'proxy',
          (service) => service.copyWith(status: runtimeStatus, isBusy: false),
        );
      case Err<Map<String, dynamic>>():
        _patchService('proxy', (service) => service.copyWith(isBusy: false));
    }
  }

  Future<void> _refreshDatabaseStatus() async {
    final server = widget.server;
    if (server == null) {
      return;
    }
    final run = captureServerRun(
      server: server,
      kind: _ServicesTabState._databaseStatusRunKind,
    );
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return;
    }

    _patchService('database', (service) => service.copyWith(isBusy: true));
    try {
      final sshService = ref.read(sshServiceProvider);
      final response = await sshService.runWorkflow(
        workflowId: 'postgres',
        operationId: 'service_status',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': {
            ...buildPostgresServiceSettings(_postgresConfig),
            'expected_databases': await _postgresExpectedDatabases(server),
          },
        },
      );

      if (!isCurrentServerRun(run)) {
        return;
      }
      switch (response) {
        case Ok<Map<String, dynamic>>(:final value):
          final serviceStatus = value['service_status'];
          final runtimeStatus = ContainerRuntimeStatus.fromServiceStatus(
            serviceStatus,
          );
          final configured =
              serviceStatus is Map && serviceStatus['configured'] == true;
          await _syncDatabaseServiceEnabled(configured);
          if (!isCurrentServerRun(run)) {
            return;
          }
          _patchService(
            'database',
            (service) => service.copyWith(
              isProvisioned: configured,
              status: runtimeStatus,
            ),
          );
          // coverage-gate: postgres_storage_status_refresh
          _applyState(() {
            _postgresStorageStatus = PostgresStorageStatus.fromServiceStatus(
              serviceStatus,
            );
          });
          // end coverage-gate
          // coverage-gate: postgres_remote_access_tls_status
          final tlsEnabled =
              serviceStatus is Map && serviceStatus['tls_enabled'] == true;
          final tlsCaFingerprint = serviceStatus is Map
              ? serviceStatus['tls_ca_fingerprint']?.toString().trim()
              : null;
          final tlsCaCertificate = serviceStatus is Map
              ? _decodePostgresCaCertificate(
                  serviceStatus['tls_ca_certificate_base64'],
                )
              : null;
          _applyState(() {
            _postgresTlsEnabled = tlsEnabled;
            _postgresTlsCaFingerprint = tlsCaFingerprint?.isEmpty == true
                ? null
                : tlsCaFingerprint;
            _postgresTlsCaCertificate = tlsCaCertificate;
          });
        // end coverage-gate
        case Err<Map<String, dynamic>>():
          return;
      }
    } finally {
      if (isCurrentServerRun(run)) {
        _patchService('database', (service) => service.copyWith(isBusy: false));
      }
    }
  }

  Future<void> _refreshPostgresRemoteAccessStatus({bool quiet = false}) async {
    final server = widget.server;
    if (server == null) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _postgresRemoteAccessStagedState = null;
        _postgresRemoteAccessAllowsPostgres = false;
        _postgresRemoteAccessSourceCidrs = const <String>[];
        _postgresRemoteAccessDetectedAddress = null;
        _isRefreshingPostgresRemoteAccess = false;
        _postgresRemoteAccessError = quiet ? null : 'No server selected.';
      });
      return;
    }

    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      if (!mounted) {
        return;
      }
      _applyState(() {
        _postgresRemoteAccessStagedState = null;
        _postgresRemoteAccessAllowsPostgres = false;
        _postgresRemoteAccessSourceCidrs = const <String>[];
        _postgresRemoteAccessDetectedAddress = null;
        _isRefreshingPostgresRemoteAccess = false;
        _postgresRemoteAccessError = quiet
            ? null
            : servicesCredentialsRequiredMessage();
      });
      return;
    }

    final run = captureServerRun(
      server: server,
      kind: _ServicesTabState._postgresRemoteAccessRunKind,
    );
    if (mounted) {
      _applyState(() {
        _isRefreshingPostgresRemoteAccess = true;
        if (!quiet) {
          _postgresRemoteAccessError = null;
        }
      });
    }

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'status',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': _buildFirewallSettingsForServices(server.firewallConfig),
        },
        onEvent: _appendServiceLogEvent,
      )).diagnosticPayload;
      if (!isCurrentServerRun(run)) {
        return;
      }

      if (result['status'] != 'success') {
        _applyState(() {
          _postgresRemoteAccessStagedState = null;
          _postgresRemoteAccessAllowsPostgres = false;
          _postgresRemoteAccessSourceCidrs = const <String>[];
          _postgresRemoteAccessDetectedAddress = null;
          _isRefreshingPostgresRemoteAccess = false;
          _postgresRemoteAccessError =
              result['msg']?.toString() ?? 'Unable to read firewall status.';
        });
        return;
      }

      final stagedState = _parseStagedFirewallState(result['staged_state']);
      _applyState(() {
        _postgresRemoteAccessStagedState = stagedState;
        _postgresRemoteAccessAllowsPostgres =
            _readAllowPostgresFromStagedState(result['staged_state']) &&
            stagedState != null;
        _postgresRemoteAccessSourceCidrs =
            _readPostgresSourceCidrsFromStagedState(result['staged_state']);
        _postgresRemoteAccessDetectedAddress =
            result['connection_source_address']?.toString().trim();
        _isRefreshingPostgresRemoteAccess = false;
        if (!quiet) {
          _postgresRemoteAccessError = null;
        }
      });
    } catch (error) {
      if (!isCurrentServerRun(run)) {
        return;
      }
      _applyState(() {
        _postgresRemoteAccessStagedState = null;
        _postgresRemoteAccessAllowsPostgres = false;
        _postgresRemoteAccessSourceCidrs = const <String>[];
        _postgresRemoteAccessDetectedAddress = null;
        _isRefreshingPostgresRemoteAccess = false;
        _postgresRemoteAccessError =
            'Unable to refresh PostgreSQL remote access state: $error';
      });
    }
  }

  Future<void> _enableTemporaryPostgresRemoteAccess(
    List<String> sourceCidrs,
  ) async {
    final server = widget.server;
    if (server == null) {
      _showServiceMessage('Select a server before managing services.');
      return;
    }
    final databaseService = _serviceById('database');
    if (databaseService == null || !databaseService.isProvisioned) {
      _showServiceMessage('Enable the database service first.');
      return;
    }
    if (!databaseService.status.isReady) {
      _showServiceMessage(
        'Start the database service before opening remote access.',
      );
      return;
    }
    if (!_postgresTlsEnabled) {
      _showServiceMessage(
        'Configure the database service once to enable TLS before opening '
        'remote access.',
      );
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      _showServiceMessage(servicesCredentialsRequiredMessage());
      return;
    }

    _applyState(() {
      _isMutatingPostgresRemoteAccess = true;
      _postgresRemoteAccessError = null;
    });

    try {
      final sshService = ref.read(sshServiceProvider);
      final result = (await sshService.runWorkflow(
        workflowId: 'firewall',
        operationId: 'apply_staged',
        connection: connection,
        params: <String, dynamic>{
          'dry_run': false,
          'settings': _buildTemporaryPostgresFirewallSettings(
            server.firewallConfig,
            sourceCidrs,
          ),
        },
        onEvent: _appendServiceLogEvent,
      )).diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        _applyState(() {
          _postgresRemoteAccessStagedState = _parseStagedFirewallState(
            result['staged_state'],
          );
          _postgresRemoteAccessAllowsPostgres =
              _readAllowPostgresFromStagedState(result['staged_state']);
          _postgresRemoteAccessSourceCidrs =
              _readPostgresSourceCidrsFromStagedState(result['staged_state']);
        });
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Database • Temporary remote access',
            details: 'Completed',
            message:
                'Temporary database access opened for one hour on port 5432.',
            level: _ServiceActivityLevel.warning,
          ),
        );
        _showServiceMessage(
          'Temporary database access is open for 1 hour on port 5432.',
        );
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.apply,
              outcome: DataOperationOutcome.success,
            );
      } else {
        final failureMessage =
            result['msg']?.toString().trim().isNotEmpty == true
            ? result['msg'].toString().trim()
            : 'Couldn’t open temporary database access.';
        final failureDetails =
            result['details']?.toString().trim().isNotEmpty == true
            ? result['details'].toString().trim()
            : null;
        _applyState(() {
          _postgresRemoteAccessError = failureDetails == null
              ? failureMessage
              : '$failureMessage\n$failureDetails';
        });
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Database • Temporary remote access',
            details: 'Failed',
            message: failureMessage,
            level: _ServiceActivityLevel.error,
          ),
        );
        _showServiceMessage(failureMessage);
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
      final message = 'Couldn’t open temporary database access. $error';
      _applyState(() {
        _postgresRemoteAccessError = message;
      });
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Database • Temporary remote access',
          details: 'Failed',
          message: message,
          level: _ServiceActivityLevel.error,
        ),
      );
      _showServiceMessage(message);
      ref
          .read(appAnalyticsServiceProvider)
          .trackFirewallEvent(
            action: FirewallAction.apply,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (mounted) {
        _applyState(() {
          _isMutatingPostgresRemoteAccess = false;
        });
      }
      await _refreshPostgresRemoteAccessStatus(quiet: true);
    }
  }

  Future<void> _closeTemporaryPostgresRemoteAccess() async {
    final server = widget.server;
    if (server == null) {
      _showServiceMessage('Select a server before managing services.');
      return;
    }
    final stagedState = _postgresRemoteAccessStagedState;
    if (stagedState == null) {
      await _refreshPostgresRemoteAccessStatus();
      return;
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      _showServiceMessage(servicesCredentialsRequiredMessage());
      return;
    }

    _applyState(() {
      _isMutatingPostgresRemoteAccess = true;
      _postgresRemoteAccessError = null;
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
            ..._buildFirewallSettingsForServices(server.firewallConfig),
            'stage_token': stagedState.token,
          },
        },
        onEvent: _appendServiceLogEvent,
      )).diagnosticPayload;
      if (!mounted) {
        return;
      }
      if (result['status'] == 'success') {
        _applyState(() {
          _postgresRemoteAccessStagedState = null;
          _postgresRemoteAccessAllowsPostgres = false;
          _postgresRemoteAccessSourceCidrs = const <String>[];
        });
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Database • Temporary remote access',
            details: 'Completed',
            message: 'Temporary database access closed.',
            level: _ServiceActivityLevel.success,
          ),
        );
        _showServiceMessage('Temporary database access closed.');
        ref
            .read(appAnalyticsServiceProvider)
            .trackFirewallEvent(
              action: FirewallAction.rollback,
              outcome: DataOperationOutcome.success,
            );
      } else {
        final failureMessage =
            result['msg']?.toString().trim().isNotEmpty == true
            ? result['msg'].toString().trim()
            : 'Couldn’t close temporary database access.';
        _applyState(() {
          _postgresRemoteAccessError = failureMessage;
        });
        _recordServiceActivity(
          _ServiceActivityEntry(
            headline: 'Database • Temporary remote access',
            details: 'Failed',
            message: failureMessage,
            level: _ServiceActivityLevel.error,
          ),
        );
        _showServiceMessage(failureMessage);
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
      final message = 'Couldn’t close temporary database access. $error';
      _applyState(() {
        _postgresRemoteAccessError = message;
      });
      _recordServiceActivity(
        _ServiceActivityEntry(
          headline: 'Database • Temporary remote access',
          details: 'Failed',
          message: message,
          level: _ServiceActivityLevel.error,
        ),
      );
      _showServiceMessage(message);
      ref
          .read(appAnalyticsServiceProvider)
          .trackFirewallEvent(
            action: FirewallAction.rollback,
            outcome: DataOperationOutcome.failure,
          );
    } finally {
      if (mounted) {
        _applyState(() {
          _isMutatingPostgresRemoteAccess = false;
        });
      }
      await _refreshPostgresRemoteAccessStatus(quiet: true);
    }
  }
}
