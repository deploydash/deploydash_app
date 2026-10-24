part of '../../agent_access_service.dart';

/// Runtime ids a redeploy request may name.
///
/// Derived from the shared Railpack option list rather than restated, so a new
/// runtime becomes selectable here the moment it is added there. It lives in
/// this file because the redeploy preview is its only reader.
final Set<String> _validRuntimeIds = <String>{
  for (final option in railpackRuntimeOptions) option.id,
};

/// Overrides how long a redeploy waits for its task id, for tests only.
///
/// The shipped window is 30 seconds, which no test can wait for. Same shape
/// as `deployDashAgentEventStreamHeartbeatOverrideForTests`.
@visibleForTesting
Duration? deployDashAgentRedeployTaskIdTimeoutOverrideForTests;

/// How long a started redeploy has to report the task id of its `app/run`.
///
/// Exceeding it is not a failure — see the `TimeoutException` branch in
/// [_AgentAccessRedeployTools._replyRedeploy].
Duration get _redeployTaskIdTimeout =>
    deployDashAgentRedeployTaskIdTimeoutOverrideForTests ??
    const Duration(seconds: 30);

/// Reduces typed failure evidence to the three non-text audit dimensions.
// coverage-gate: deploy_failure_audit_metadata
Map<String, dynamic> _deployFailureAuditMetadata(
  DeployFailureEvidence? evidence,
) => evidence == null
    ? const <String, dynamic>{}
    : <String, dynamic>{
        'failure_phase': evidence.phase.storageKey,
        'failure_source': evidence.source.storageKey,
        'failure_completeness': evidence.completeness.storageKey,
      };
// end coverage-gate

/// The two redeploy-gated tools and the preview both share.
///
/// The only handlers here that change a customer's server, and the only ones
/// behind `AgentAccessAuthorization.errorForBearerToken`.
extension _AgentAccessRedeployTools on AgentAccessService {
  Future<AgentAccessReply> _replyPrepareRedeploy(
    String projectId,
    Map<String, dynamic> body,
  ) async {
    final preview = (await _buildRedeployPreview(projectId, body)).preview;
    await _audit(
      toolName: 'prepare_web_app_redeploy',
      accessLevel: 'read_only',
      status: preview['can_redeploy'] == true ? 'success' : 'failed',
      summary: 'Prepared web app redeploy preview.',
      details: <String, dynamic>{'project_id': projectId},
    );
    return AgentAccessReply(HttpStatus.ok, preview);
  }

  // coverage-gate: reply_redeploy
  Future<AgentAccessReply> _replyRedeploy(
    String projectId,
    Map<String, dynamic> body,
    AppPreferencesRecord preferences,
    String? authorization,
  ) async {
    // The handoff latency the agent waited for. Auth and validation rejects
    // return before any report: they are not redeploy attempts.
    final handoffStartedAt = DateTime.now();
    final authError = AgentAccessAuthorization.errorForBearerToken(
      authorization,
      preferences,
    );
    if (authError != null) {
      return AgentAccessReply(HttpStatus.forbidden, authError);
    }
    final previewResult = await _buildRedeployPreview(projectId, body);
    final preview = previewResult.preview;
    final errors = (preview['validation_errors'] as List<dynamic>)
        .cast<String>();
    final githubReconnectRequired =
        preview['github_reconnect_required'] == true;
    if (errors.isNotEmpty) {
      await _audit(
        toolName: 'redeploy_web_app',
        accessLevel: agentAccessPermissionRedeploy,
        status: 'failed',
        summary: 'Redeploy request was rejected during validation.',
        details: <String, dynamic>{'project_id': projectId},
      );
      return AgentAccessReply(
        githubReconnectRequired
            ? HttpStatus.preconditionFailed
            : HttpStatus.badRequest,
        <String, dynamic>{
          'error': githubReconnectRequired
              ? 'github_reconnect_required'
              : 'validation_failed',
          'validation_errors': errors,
          'preview': preview,
        },
      );
    }

    final project = await _requireProject(projectId);
    // Non-null because `errors` was empty above, which is exactly the
    // condition under which the preview resolved a server.
    final server = previewResult.server!;
    final nextConfig = preview['resolved_next_config'] as Map<String, dynamic>;
    final taskIdCompleter = Completer<int>();
    int? runTaskId;

    unawaited(() async {
      try {
        await ref
            .read(gitHubIntegrationProvider.notifier)
            .deploySelectedRepository(
              repositoryFullName: nextConfig['repository_full_name']
                  ?.toString(),
              primaryDomain: nextConfig['primary_hostname']?.toString() ?? '',
              domainRoutingMode: nextConfig['hostname_behavior']?.toString(),
              branch: nextConfig['branch']?.toString() ?? 'main',
              appPort: (nextConfig['port'] as num?)?.toInt() ?? project.appPort,
              railpackProvider: _runtimeIdToProvider(
                nextConfig['runtime']?.toString(),
              ),
              railpackBuildCommand: nextConfig['build_command']?.toString(),
              railpackRunCommand: nextConfig['run_command']?.toString(),
              selectedServerOverride: server,
              selectedProjectOverride: project,
              actorLabel: 'agent-mcp',
              onTaskStarted: (taskId, phase) {
                if (phase != 'run') {
                  return;
                }
                runTaskId = taskId;
                if (!taskIdCompleter.isCompleted) {
                  taskIdCompleter.complete(taskId);
                }
              },
            );
        // coverage-gate: redeploy_failure_audit_selection
        final gitState = ref.read(gitHubIntegrationProvider);
        final failureEvidence =
            gitState.failureEvidenceForProject(project.id) ??
            gitState.failureEvidence;
        if (!taskIdCompleter.isCompleted) {
          taskIdCompleter.completeError(StateError(gitState.statusMessage));
          await _audit(
            toolName: 'redeploy_web_app',
            accessLevel: agentAccessPermissionRedeploy,
            status: 'failed',
            summary: 'Web app redeploy failed before app/run started.',
            details: <String, dynamic>{
              'project_id': project.id,
              'server_id': server.id,
              'deploy_status': gitState.deployStatus.name,
              ..._deployFailureAuditMetadata(failureEvidence),
            },
          );
          return;
        }
        await _audit(
          toolName: 'redeploy_web_app',
          accessLevel: agentAccessPermissionRedeploy,
          status: gitState.deployStatus == GitHubDeployStatus.success
              ? 'success'
              : 'failed',
          summary: gitState.deployStatus == GitHubDeployStatus.success
              ? 'Web app redeploy completed.'
              : 'Web app redeploy finished with an error.',
          details: <String, dynamic>{
            'project_id': project.id,
            'server_id': server.id,
            'task_id': runTaskId,
            'deploy_status': gitState.deployStatus.name,
            ..._deployFailureAuditMetadata(failureEvidence),
          },
        );
        // end coverage-gate
      } catch (error) {
        if (!taskIdCompleter.isCompleted) {
          taskIdCompleter.completeError(error);
        }
        await _audit(
          toolName: 'redeploy_web_app',
          accessLevel: agentAccessPermissionRedeploy,
          status: 'failed',
          summary: 'Web app redeploy crashed before completion.',
          details: <String, dynamic>{
            'project_id': project.id,
            'server_id': server.id,
            'task_id': runTaskId,
          },
        );
      }
    }());

    int startedTaskId;
    try {
      startedTaskId = await taskIdCompleter.future.timeout(
        _redeployTaskIdTimeout,
      );
    } on TimeoutException {
      // Not a failure. The deploy above is unawaited and still running; it
      // has simply not reported a task id within the window. This used to
      // answer `502 redeploy_start_failed`, which tells an agent the deploy
      // did not start -- and the obvious response to that is to retry, which
      // starts a SECOND deploy of a customer's app while the first is
      // mid-flight. Owner decision, 2026-09-04: report it as still running.
      // 202 with a null task_id says "accepted, ask again", and
      // `deploydash_get_task_history` is where the id turns up.
      await _audit(
        toolName: 'redeploy_web_app',
        accessLevel: agentAccessPermissionRedeploy,
        status: 'started',
        summary: 'Started web app redeploy; task id not confirmed yet.',
        details: <String, dynamic>{
          'project_id': project.id,
          'server_id': server.id,
          'task_id': runTaskId,
        },
      );
      _reportAgentRedeploy(DataOperationOutcome.success, handoffStartedAt);
      return AgentAccessReply(HttpStatus.accepted, <String, dynamic>{
        'status': 'pending_confirmation',
        'task_id': null,
        'message':
            'The redeploy is running but has not reported a task id yet. '
            'Do not send it again; call deploydash_get_task_history to find '
            'the task.',
        'workflow_id': 'app',
        'operation_id': 'run',
        'resolved_config': nextConfig,
        'session_expires_at': preferences.agentSessionExpiresAt
            ?.toIso8601String(),
        'streamable': true,
      });
    } on Object catch (error) {
      // A real start failure: the deploy reported an error instead of a task
      // id, so nothing is running and a retry is the right advice.
      _reportAgentRedeploy(DataOperationOutcome.failure, handoffStartedAt);
      return AgentAccessReply(HttpStatus.badGateway, <String, dynamic>{
        'error': 'redeploy_start_failed',
        'message': sanitizeSensitiveText(
          'Web app redeploy did not reach the app/run task: $error',
        ),
        'preview': preview,
      });
    }

    final historyEntry = await _waitForTaskHistoryEntry(startedTaskId);
    await _audit(
      toolName: 'redeploy_web_app',
      accessLevel: agentAccessPermissionRedeploy,
      status: 'started',
      summary: 'Started web app redeploy through Deploy Dash.',
      details: <String, dynamic>{
        'project_id': project.id,
        'server_id': server.id,
        'task_id': startedTaskId,
        'operation_instance_id': historyEntry?.clientOperationId,
      },
    );
    _reportAgentRedeploy(DataOperationOutcome.success, handoffStartedAt);
    return AgentAccessReply(HttpStatus.accepted, <String, dynamic>{
      'task_id': startedTaskId,
      'operation_instance_id': historyEntry?.clientOperationId,
      'workflow_id': 'app',
      'operation_id': 'run',
      'resolved_config': nextConfig,
      'session_expires_at': preferences.agentSessionExpiresAt
          ?.toIso8601String(),
      'streamable': true,
    });
  }

  /// Reports one redeploy handoff with its latency. One owner for the report
  /// shape: the three resolve points above differ only in outcome.
  void _reportAgentRedeploy(
    DataOperationOutcome outcome,
    DateTime handoffStartedAt,
  ) {
    final durationSeconds = DateTime.now()
        .difference(handoffStartedAt)
        .inSeconds;
    ref
        .read(appAnalyticsServiceProvider)
        .trackAgentRedeploy(outcome: outcome, durationSeconds: durationSeconds);
  }
  // end coverage-gate

  // coverage-gate: agent_redeploy_preview
  /// Builds the redeploy preview, and hands back the server it resolved.
  ///
  /// The `server` is part of the return rather than looked up again by
  /// [_replyRedeploy] because a second lookup needed a second null case, and
  /// that case could not happen: the preview has already added
  /// 'server_id does not match a saved server.' to `validation_errors`, and
  /// [_replyRedeploy] returns before reaching it. It was reached through
  /// `_requireServer`, whose `throw` was therefore unreachable — dead code
  /// that had been carrying a covering test until the runtime-log handler
  /// stopped being its other caller.
  Future<({Map<String, dynamic> preview, Server? server})>
  _buildRedeployPreview(String projectId, Map<String, dynamic> body) async {
    final preferences = await ref.read(appPreferencesRepositoryProvider).read();
    final serverId = (body['server_id'] ?? '').toString().trim();
    final requestedProjectId = (body['project_id'] ?? '').toString().trim();
    final requestedWebAppId = (body['web_app_id'] ?? '').toString().trim();
    // MCP carries both identifiers. Prefer its independently supplied
    // project_id when it resolves, so web_app_id remains an actual identity
    // assertion rather than merely selecting the record being checked. The
    // legacy path still supplies its selected id through projectId, which is
    // the fallback for a missing or unknown project_id.
    final project =
        await _findProject(requestedProjectId) ??
        await _requireProject(projectId);
    // toString-first: trimOrNull takes String? (D-87).
    final repositoryFullName = trimOrNull(
      body['repository_full_name']?.toString(),
    );
    final primaryHostname = trimOrNull(body['primary_hostname']?.toString());
    final hostnameBehavior = trimOrNull(body['hostname_behavior']?.toString());
    final branch = trimOrNull(body['branch']?.toString());
    final runtime = trimOrNull(body['runtime']?.toString());
    final buildCommand = body.containsKey('build_command')
        ? trimOrNull(body['build_command']?.toString())
        : null;
    final runCommand = body.containsKey('run_command')
        ? trimOrNull(body['run_command']?.toString())
        : null;
    final port = body.containsKey('port') ? _intOrNull(body['port']) : null;
    final validationErrors = <String>[];

    Server? server;
    if (serverId.isEmpty) {
      validationErrors.add('server_id is required.');
    } else {
      server = await _findServer(serverId);
      if (server == null) {
        validationErrors.add('server_id does not match a saved server.');
      }
    }
    if (requestedProjectId.isNotEmpty && requestedProjectId != project.id) {
      validationErrors.add('project_id does not match the selected web app.');
    }
    if (requestedWebAppId.isNotEmpty && requestedWebAppId != project.id) {
      validationErrors.add('web_app_id does not match the selected web app.');
    }
    if (serverId.isNotEmpty &&
        project.serverId != null &&
        project.serverId != serverId) {
      validationErrors.add(
        'server_id does not match the selected web app server.',
      );
    }

    final repositorySnapshot = await _readGitHubRepositorySnapshot();
    final repositories = repositorySnapshot.repositories;
    final repositoryNames = repositories
        .map((repository) => repository.fullName)
        .toSet();

    final resolvedRepository = repositoryFullName ?? project.repositoryFullName;
    final resolvedHostname = primaryHostname ?? project.primaryDomain;
    final resolvedHostnameBehavior =
        hostnameBehavior ?? project.domainRoutingMode;
    final resolvedBranch = branch ?? project.deployBranch;
    final resolvedPort = port ?? project.appPort;
    final resolvedRuntime =
        runtime ??
        railpackRuntimeSelectionId(
          railpackProvider: project.railpackProvider,
          railpackBuildCommand: project.railpackBuildCommand,
          railpackRunCommand: project.railpackRunCommand,
        );
    final resolvedBuildCommand = body.containsKey('build_command')
        ? (buildCommand ?? '')
        : project.railpackBuildCommand;
    final resolvedRunCommand = body.containsKey('run_command')
        ? (runCommand ?? '')
        : project.railpackRunCommand;

    if (!repositorySnapshot.connected) {
      validationErrors.add(
        repositorySnapshot.message ??
            'GitHub is not connected. Reconnect GitHub first.',
      );
    } else if (resolvedRepository == null ||
        resolvedRepository.trim().isEmpty) {
      validationErrors.add('repository_full_name is required.');
    } else if (repositoryNames.isNotEmpty &&
        !repositoryNames.contains(resolvedRepository)) {
      validationErrors.add(
        'repository_full_name must come from list_github_repositories.',
      );
    }
    if (!_isValidDomain(resolvedHostname)) {
      validationErrors.add('primary_hostname must be a valid FQDN.');
    }
    if (!deployDashHostnameBehaviorOptions.contains(resolvedHostnameBehavior)) {
      validationErrors.add(
        'hostname_behavior must be one of: '
        '${deployDashHostnameBehaviorOptions.join(', ')}.',
      );
    }
    if (!_isValidBranch(resolvedBranch)) {
      validationErrors.add('branch contains invalid characters.');
    }
    if (resolvedPort < 1 || resolvedPort > 65535) {
      validationErrors.add('port must be between 1 and 65535.');
    }
    if (!_validRuntimeIds.contains(resolvedRuntime)) {
      validationErrors.add('runtime must be one of the supported runtime ids.');
    }

    Map<String, dynamic>? queueConflict;
    if (server != null && validationErrors.isEmpty) {
      final connection = await _buildConnectionPayload(server);
      if (connection == null) {
        validationErrors.add('Selected server credentials are incomplete.');
      } else {
        final settings = <String, dynamic>{
          'project_slug': slugifyProjectName(project.name),
          'repository_full_name': resolvedRepository,
          'branch': resolvedBranch,
          'primary_domain': resolvedHostname,
          'domain_routing_mode': resolvedHostnameBehavior,
          'app_port': resolvedPort,
          'public_health_check_enabled': project.publicHealthCheckEnabled,
          'public_health_check_path': project.publicHealthCheckPath,
          if (_runtimeIdToProvider(resolvedRuntime) != null)
            'railpack_provider': _runtimeIdToProvider(resolvedRuntime),
          if (resolvedBuildCommand.trim().isNotEmpty)
            'railpack_build_cmd': resolvedBuildCommand,
          if (resolvedRunCommand.trim().isNotEmpty)
            'railpack_start_cmd': resolvedRunCommand,
        };
        final conflict = ref
            .read(sshServiceProvider)
            .evaluateWorkflowConflict(
              workflowId: 'app',
              operationId: 'run',
              connection: connection,
              params: <String, dynamic>{'dry_run': false, 'settings': settings},
            );
        queueConflict = conflict.toMap();
      }
    }

    final currentConfig = _projectConfig(project);
    final nextConfig = <String, dynamic>{
      ...currentConfig,
      'repository_full_name': resolvedRepository,
      'primary_hostname': resolvedHostname,
      'hostname_behavior': resolvedHostnameBehavior,
      'branch': resolvedBranch,
      'port': resolvedPort,
      'runtime': resolvedRuntime,
      'build_command': resolvedBuildCommand,
      'run_command': resolvedRunCommand,
    };
    final changedFields = <String>[
      if (currentConfig['repository_full_name'] !=
          nextConfig['repository_full_name'])
        'repository_full_name',
      if (currentConfig['primary_hostname'] != nextConfig['primary_hostname'])
        'primary_hostname',
      if (currentConfig['hostname_behavior'] != nextConfig['hostname_behavior'])
        'hostname_behavior',
      if (currentConfig['branch'] != nextConfig['branch']) 'branch',
      if (currentConfig['port'] != nextConfig['port']) 'port',
      if (currentConfig['runtime'] != nextConfig['runtime']) 'runtime',
      if (currentConfig['build_command'] != nextConfig['build_command'])
        'build_command',
      if (currentConfig['run_command'] != nextConfig['run_command'])
        'run_command',
    ];

    return (
      server: server,
      preview: <String, dynamic>{
        'current_config': currentConfig,
        'resolved_next_config': nextConfig,
        'changed_fields': changedFields,
        'can_redeploy': validationErrors.isEmpty,
        'validation_errors': validationErrors,
        'queue_conflict': queueConflict,
        'approval_required':
            preferences.agentAccessPermissionMode !=
                agentAccessPermissionRedeploy ||
            !preferences.hasActiveAgentSession,
        'session_status': <String, dynamic>{
          'permission_mode': preferences.agentAccessPermissionMode,
          'has_active_session': preferences.hasActiveAgentSession,
          'expires_at': preferences.agentSessionExpiresAt?.toIso8601String(),
        },
        'github_reconnect_required': !repositorySnapshot.connected,
        'github_session_status': <String, dynamic>{
          'connected': repositorySnapshot.connected,
          'message': repositorySnapshot.message,
        },
        'allowed_repository_full_names': repositories
            .map((repository) => repository.fullName)
            .toList(growable: false),
        'allowed_hostname_behaviors': deployDashHostnameBehaviorOptions,
        'allowed_runtime_ids': _validRuntimeIds.toList(growable: false),
      },
    );
  }

  // end coverage-gate
}
