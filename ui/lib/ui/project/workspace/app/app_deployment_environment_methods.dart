// ignore_for_file: invalid_use_of_protected_member

part of '../../project_workspace.dart';

extension _AppDeploymentEnvironmentMethods on _AppDeploymentSummaryState {
  List<_EnvVarRowState> _envRows(String projectId) {
    return _envVarsByProject[projectId] ?? const <_EnvVarRowState>[];
  }

  void _syncOneOffCommandDraftFromProject(Project project) {
    final projectId = project.id;
    _oneOffCommandController.text =
        _oneOffCommandDraftByProject[projectId] ?? '';
    _oneOffCommandTimeoutController.text =
        _oneOffCommandTimeoutByProject[projectId] ?? '600';
  }

  Future<void> _appendOneOffCommandLine({
    required String projectId,
    required String message,
  }) async {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        final lines = List<String>.from(
          _oneOffCommandOutputByProject[projectId] ?? const <String>[],
        );
        lines.add(trimmed);
        _oneOffCommandOutputByProject[projectId] = lines;
      });
    }
    final selectedServer = ref.read(selectedServerProvider);
    await ref
        .read(terminalLogRepositoryProvider)
        .appendLog(
          message: trimmed,
          renderedLine: trimmed,
          projectId: projectId,
          serverId: selectedServer?.id,
          serverLabel: selectedServer?.name,
          source: 'app_exec',
          taskType: 'app_exec',
        );
  }

  Future<void> _appendOneOffCommandResponseOutput({
    required String projectId,
    required Map<String, dynamic> response,
  }) async {
    final stdoutLines = response['stdout_lines'];
    if (stdoutLines is Iterable) {
      for (final rawLine in stdoutLines) {
        final line = rawLine?.toString().trim() ?? '';
        if (line.isEmpty) {
          continue;
        }
        await _appendOneOffCommandLine(projectId: projectId, message: line);
      }
    }

    final stderrLines = response['stderr_lines'];
    if (stderrLines is Iterable) {
      for (final rawLine in stderrLines) {
        final line = rawLine?.toString().trim() ?? '';
        if (line.isEmpty) {
          continue;
        }
        await _appendOneOffCommandLine(
          projectId: projectId,
          message: 'stderr: $line',
        );
      }
    }
  }

  void _recordOneOffCommandHistory({
    required String projectId,
    required String command,
    required DateTime startedAt,
    required String status,
    DateTime? completedAt,
    int? exitCode,
  }) {
    if (!mounted) {
      return;
    }
    setState(() {
      final entries = List<_OneOffCommandHistoryEntry>.from(
        _oneOffCommandHistoryByProject[projectId] ??
            const <_OneOffCommandHistoryEntry>[],
      );
      entries.insert(
        0,
        _OneOffCommandHistoryEntry(
          command: command,
          startedAt: startedAt,
          status: status,
          completedAt: completedAt,
          exitCode: exitCode,
        ),
      );
      _oneOffCommandHistoryByProject[projectId] = entries;
    });
  }

  String _formatOneOffCommandTimestamp(
    BuildContext context,
    DateTime timestamp,
  ) {
    final local = timestamp.toLocal();
    final date = MaterialLocalizations.of(context).formatShortDate(local);
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(local));
    return '$date $time';
  }

  String? _railpackProviderFor(String projectId) {
    return normalizeRailpackProvider(_railpackProviderByProject[projectId]);
  }

  String _runtimeSelectionFor(String projectId) {
    final buildCommand =
        _buildCommandByProject[projectId] ?? _defaultBuildCommand;
    final runCommand = _runCommandByProject[projectId] ?? _defaultRunCommand;
    return railpackRuntimeSelectionId(
      railpackProvider: _railpackProviderFor(projectId),
      railpackBuildCommand: buildCommand,
      railpackRunCommand: runCommand,
    );
  }

  String _buildCommandFor(String projectId) {
    return appDeploymentResolvedBuildCommand(
      railpackProvider: _railpackProviderFor(projectId),
      configuredBuildCommand: _buildCommandByProject[projectId],
    );
  }

  String _runCommandFor(String projectId) {
    return appDeploymentResolvedRunCommand(
      railpackProvider: _railpackProviderFor(projectId),
      configuredRunCommand: _runCommandByProject[projectId],
    );
  }

  ProjectSqliteDatabase? _primarySqliteDatabaseForProject(String projectId) {
    final sqliteByProject = ref.read(projectSqliteDatabasesProvider);
    final records =
        sqliteByProject[projectId] ?? const <ProjectSqliteDatabase>[];
    for (final record in records) {
      if (record.isPrimary) {
        return record;
      }
    }
    return null;
  }

  bool _sqliteStorageEnabledFor(String? projectId) {
    if (projectId == null) {
      return false;
    }
    return _sqliteStorageEnabledByProject[projectId] ?? false;
  }

  String _sqliteVolumeNameFor(String? projectId, String projectName) {
    if (projectId == null) {
      return _defaultSqliteVolumeName(projectName);
    }
    final configured = _normalizedSqliteVolumeName(
      _sqliteVolumeNameByProject[projectId] ?? '',
    );
    if (configured == null) {
      return _defaultSqliteVolumeName(projectName);
    }
    return configured;
  }

  String _sqliteMountPathFor(String? projectId) {
    if (projectId == null) {
      return _defaultSqliteMountPath;
    }
    final configured = _normalizedSqliteMountPath(
      _sqliteMountPathByProject[projectId] ?? '',
    );
    if (configured == null) {
      return _defaultSqliteMountPath;
    }
    return configured;
  }

  String _sqliteFileNameFor(String? projectId) {
    if (projectId == null) {
      return _defaultSqliteFileName;
    }
    final configured = _normalizedSqliteFileName(
      _sqliteFileNameByProject[projectId] ?? '',
    );
    if (configured == null) {
      return _defaultSqliteFileName;
    }
    return configured;
  }

  String _appSubdirectoryFor(String? projectId) {
    if (projectId == null) {
      return _defaultAppSubdirectory;
    }
    return _appSubdirectoryByProject[projectId] ?? _defaultAppSubdirectory;
  }

  String? _normalizedAppSubdirectory(String value) {
    final normalized = value
        .trim()
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) {
      return null;
    }
    final segments = normalized.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (trimmed.isEmpty || trimmed == '.' || trimmed == '..') {
        return _invalidAppSubdirectory;
      }
      cleaned.add(trimmed);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return cleaned.join('/');
  }

  String _tlsChallengeModeFor(String projectId) {
    final normalized = _tlsChallengeModeByProject[projectId]
        ?.trim()
        .toLowerCase();
    return normalized == 'dns' ? 'dns' : 'http';
  }

  String _domainRoutingModeFor(String projectId) {
    return _normalizedDomainRoutingModeForWorkspace(
      _domainRoutingModeByProject[projectId] ?? _domainRoutingModeSingleHost,
    );
  }

  String _defaultSqliteVolumeName(String projectName) {
    final slug = slugifyProjectName(projectName, fallback: 'project-app');
    return 'deploydash_sqlite_$slug';
  }

  String? _normalizedSqliteVolumeName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  String? _normalizedSqliteMountPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('/')) {
      return null;
    }
    final segments = trimmed.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      final normalized = segment.trim();
      if (normalized.isEmpty) {
        continue;
      }
      if (normalized == '.' || normalized == '..') {
        return null;
      }
      cleaned.add(normalized);
    }
    if (cleaned.isEmpty) {
      return null;
    }
    return '/${cleaned.join('/')}';
  }

  String? _normalizedSqliteFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.contains('/')) {
      return null;
    }
    if (trimmed == '.' || trimmed == '..') {
      return null;
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  String? _tlsDnsProviderFor(String projectId) {
    final normalized = _tlsDnsProviderByProject[projectId]
        ?.trim()
        .toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    if (!_dnsProviderSpecs.containsKey(normalized)) {
      return null;
    }
    return normalized;
  }

  Map<String, String> _tlsDnsCredentialsFor(String projectId) {
    final raw = _tlsDnsCredentialsByProject[projectId];
    if (raw == null || raw.isEmpty) {
      return const <String, String>{};
    }
    final normalized = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key.trim().toLowerCase();
      final value = entry.value.trim();
      if (key.isEmpty || value.isEmpty) {
        continue;
      }
      normalized[key] = value;
    }
    return normalized;
  }

  List<AppDeploymentDnsProviderSpec> _enabledDnsProviderSpecs(
    Set<String> enabledProviderIds,
  ) {
    return _dnsProviderSpecs.values
        .where((spec) => enabledProviderIds.contains(spec.id))
        .toList(growable: false);
  }

  String? _tlsSettingsValidationError(
    String? projectId,
    Set<String> enabledProviderIds,
  ) {
    if (projectId == null) {
      return null;
    }
    if (_tlsChallengeModeFor(projectId) != 'dns') {
      return null;
    }
    if (enabledProviderIds.isEmpty) {
      return null;
    }

    final providerId = _tlsDnsProviderFor(projectId);
    if (providerId == null) {
      return 'Choose a DNS provider for DNS challenge certificates.';
    }
    if (!enabledProviderIds.contains(providerId)) {
      return 'Selected DNS provider is not enabled on this server.';
    }
    final spec = _dnsProviderSpecs[providerId];
    if (spec == null) {
      return 'Selected DNS provider is not supported.';
    }
    final credentials = _tlsDnsCredentialsFor(projectId);
    for (final field in spec.fields) {
      if (!field.required) {
        continue;
      }
      final value = credentials[field.key];
      if (value == null || value.trim().isEmpty) {
        return '${spec.label}: ${field.label} is required.';
      }
    }
    if (providerId == 'cloudns') {
      final hasAuthId = (credentials['auth_id'] ?? '').trim().isNotEmpty;
      final hasSubAuthId = (credentials['sub_auth_id'] ?? '').trim().isNotEmpty;
      if (!hasAuthId && !hasSubAuthId) {
        return 'ClouDNS requires Auth ID or Sub-auth ID.';
      }
    }
    return null;
  }

  Map<String, String> _currentEnvMap(String projectId) {
    final map = <String, String>{};
    for (final row in _envRows(projectId)) {
      final key = row.key.trim();
      if (key.isEmpty) {
        continue;
      }
      map[key] = row.value.trim();
    }
    return map;
  }

  void _recomputeEnvChangeState(String projectId) {
    final snapshot =
        _lastDeployedEnvByProject[projectId] ?? const <String, String>{};
    final rows = _envRows(projectId);
    final nextRows = rows
        .map((row) {
          final key = row.key.trim();
          if (key.isEmpty) {
            return row.copyWith(changedSinceLastDeploy: false);
          }
          final currentValue = row.value.trim();
          final previousValue = snapshot[key];
          return row.copyWith(
            changedSinceLastDeploy: previousValue != currentValue,
          );
        })
        .toList(growable: false);
    _envVarsByProject[projectId] = nextRows;
  }

  Future<Map<String, dynamic>> _buildWorkflowSettings({
    required Project project,
    required String branch,
    required int appPort,
    required String? selectedRepository,
    required String domain,
  }) async {
    final normalizedBranch = branch.trim().isEmpty ? 'main' : branch.trim();
    final normalizedPort = appPort >= 1 && appPort <= 65535 ? appPort : 3000;
    final normalizedRepository =
        trimOrNull(selectedRepository) ??
        trimOrNull(project.repositoryFullName) ??
        'deploydash/local-app';
    final normalizedDomain = _isValidDomain(domain.trim())
        ? domain.trim().toLowerCase()
        : null;
    final normalizedDomainConfig = normalizedDomain == null
        ? null
        : _normalizedDomainRoutingConfigForWorkspace(
            primaryDomain: normalizedDomain,
            domainRoutingMode: _domainRoutingModeFor(project.id),
          );
    final normalizedAppSubdirectory = _normalizedAppSubdirectory(
      _appSubdirectoryFor(project.id),
    );
    final selectedServer = ref.read(selectedServerProvider);
    final enabledDnsProviders =
        (selectedServer?.webServerConfig.enabledDnsProviders ??
                const <String>[])
            .toSet();
    var tlsMode = _tlsChallengeModeFor(project.id);
    var tlsProvider = _tlsDnsProviderFor(project.id);
    var tlsCredentials = _tlsDnsCredentialsFor(project.id);
    if (tlsMode == 'dns') {
      final providerEnabled =
          tlsProvider != null && enabledDnsProviders.contains(tlsProvider);
      if (enabledDnsProviders.isEmpty || !providerEnabled) {
        tlsMode = 'http';
        tlsProvider = null;
        tlsCredentials = const <String, String>{};
      }
    }
    final workerSettings = buildWorkersWorkflowPayload(
      workers: ref.read(projectWorkerInstancesProvider)[project.id] ?? const [],
    );
    final primarySqliteDatabase = _primarySqliteDatabaseForProject(project.id);
    final sqliteStorageEnabled =
        primarySqliteDatabase != null || _sqliteStorageEnabledFor(project.id);
    final sqliteVolumeName =
        primarySqliteDatabase?.volumeName ??
        _sqliteVolumeNameFor(project.id, project.name);
    final sqliteMountPath =
        primarySqliteDatabase?.mountPath ?? _sqliteMountPathFor(project.id);
    final sqliteFileName =
        primarySqliteDatabase?.fileName ?? _sqliteFileNameFor(project.id);
    final runtimeEnv = buildRuntimeEnvFromRows(
      rows: _envRows(project.id).map((row) => MapEntry(row.key, row.value)),
      injectPostgresEnv: project.injectPostgresEnv,
    );
    final trustNetworkNames = await ref
        .read(projectNetworkTrustRepositoryProvider)
        .listTrustNetworkNamesForProject(project.id);
    final sqliteSnapshotMounts = await ref
        .read(projectSqliteSnapshotRepositoryProvider)
        .buildSnapshotMountPayloadsForConsumer(project.id);

    return <String, dynamic>{
      'project_slug': slugifyProjectName(project.name, fallback: 'project-app'),
      'repository_full_name': normalizedRepository,
      'branch': normalizedBranch,
      'primary_domain': normalizedDomainConfig?.primaryDomain,
      'domain_routing_mode':
          normalizedDomainConfig?.domainRoutingMode ??
          _domainRoutingModeSingleHost,
      'app_port': normalizedPort,
      'public_health_check_enabled': project.publicHealthCheckEnabled,
      'public_health_check_path': project.publicHealthCheckPath,
      'railpack_node_mode': 'auto',
      'railpack_build_cmd': _buildCommandFor(project.id),
      'railpack_start_cmd': _runCommandFor(project.id),
      if (normalizedAppSubdirectory != null &&
          normalizedAppSubdirectory != _invalidAppSubdirectory)
        'app_subdirectory': normalizedAppSubdirectory,
      'tls_challenge_mode': tlsMode,
      if (tlsMode == 'dns' && tlsProvider != null)
        'tls_dns_provider': tlsProvider,
      if (tlsMode == 'dns' && tlsCredentials.isNotEmpty)
        'tls_dns_credentials': tlsCredentials,
      if (runtimeEnv.isNotEmpty) 'runtime_env': runtimeEnv,
      if (trustNetworkNames.isNotEmpty)
        'trust_network_names': trustNetworkNames,
      if (sqliteSnapshotMounts.isNotEmpty)
        'sqlite_snapshot_mounts': sqliteSnapshotMounts,
      if (sqliteStorageEnabled)
        'sqlite_storage': <String, dynamic>{
          'enabled': true,
          'volume_name': sqliteVolumeName,
          'mount_path': sqliteMountPath,
          'file_name': sqliteFileName,
        },
      if (workerSettings.isNotEmpty) 'workers': workerSettings,
    };
  }

  // coverage-gate: persist_environment_rows
  Future<void> _persistEnvRows(
    String projectId,
    List<_EnvVarRowState> rows,
  ) async {
    final repository = ref.read(appEnvironmentVariableRepositoryProvider);
    await repository.replaceForProject(
      projectId: projectId,
      rows: rows
          .asMap()
          .entries
          .map(
            (entry) => AppEnvironmentVariableRecord(
              projectId: projectId,
              key: entry.value.key,
              value: entry.value.value,
              secret: entry.value.secret,
              sortOrder: entry.key,
            ),
          )
          .toList(growable: false),
    );
    ref
        .read(appEnvironmentVariableRevisionProvider.notifier)
        .markProjectUpdated(projectId);
  }

  // end coverage-gate
}
