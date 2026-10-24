part of '../../agent_access_service.dart';

/// Read-only tools inspecting a project's managed PostgreSQL databases, and
/// the precondition checks every one of them runs first.
extension _AgentAccessPostgresTools on AgentAccessService {
  Future<AgentAccessReply> _replyListPostgresDatabases(String projectId) async {
    final context = await _resolveProjectPostgresContextReply(projectId);
    if (context case final AgentAccessReply reply) {
      return reply;
    }
    final resolved =
        context
            as ({
              Project project,
              Server server,
              Map<String, dynamic> connection,
              Map<String, dynamic> settings,
            });
    final response = await _runPostgresAgentWorkflow(
      context: resolved,
      operationId: 'project_list',
    );
    if (response['status'] != 'success') {
      await _audit(
        toolName: 'deploydash_list_postgres_databases',
        accessLevel: 'read_only',
        status: 'failed',
        summary: 'Project PostgreSQL database listing failed.',
        details: <String, dynamic>{
          'project_id': resolved.project.id,
          'server_id': resolved.server.id,
          'message': response['msg'],
        },
      );
      return AgentAccessReply(
        _workflowHttpStatus(response),
        _errorPayloadFromWorkflowResponse(response),
      );
    }
    final databases = ((response['databases'] as List?) ?? const <dynamic>[])
        .whereType<String>()
        .map(
          (remoteName) => <String, dynamic>{
            'name': logicalManagedPostgresName(
              projectName: resolved.project.name,
              remoteName: remoteName,
            ),
            'remote_name': remoteName,
          },
        )
        .toList(growable: false);
    await _audit(
      toolName: 'deploydash_list_postgres_databases',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Listed managed PostgreSQL databases for a project.',
      details: <String, dynamic>{
        'project_id': resolved.project.id,
        'server_id': resolved.server.id,
        'count': databases.length,
      },
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'project_id': resolved.project.id,
      'server_id': resolved.server.id,
      'engine_version': response['engine_version'],
      'service_status': response['service_status'],
      'databases': databases,
    });
  }

  Future<AgentAccessReply> _replyPostgresWorkflow(
    String projectId, {
    required String operationId,
    required String toolName,
    required String successSummary,
    required String failureSummary,
    required Map<String, dynamic> auditDetails,
    Map<String, dynamic>? settingsOverrides,
  }) async {
    final context = await _resolveProjectPostgresContextReply(projectId);
    if (context case final AgentAccessReply reply) {
      return reply;
    }
    final resolved =
        context
            as ({
              Project project,
              Server server,
              Map<String, dynamic> connection,
              Map<String, dynamic> settings,
            });
    final requestedDatabase = settingsOverrides?['database_name'];
    final forwardedOverrides = <String, dynamic>{
      ...?settingsOverrides,
      if (requestedDatabase is String)
        'database_name': logicalManagedPostgresName(
          projectName: resolved.project.name,
          remoteName: requestedDatabase,
        ),
    };
    final response = await _runPostgresAgentWorkflow(
      context: resolved,
      operationId: operationId,
      settingsOverrides: forwardedOverrides,
    );
    final ok = response['status'] == 'success';
    final details = <String, dynamic>{
      ...auditDetails,
      if (response['remote_database_name'] != null)
        'remote_database_name': response['remote_database_name'],
      if (response['row_count_returned'] != null)
        'row_count_returned': response['row_count_returned'],
      if (response['truncated'] != null) 'truncated': response['truncated'],
      if (response['duration_ms'] != null)
        'duration_ms': response['duration_ms'],
    };
    await _audit(
      toolName: toolName,
      accessLevel: 'read_only',
      status: ok ? 'success' : 'failed',
      summary: ok ? successSummary : failureSummary,
      details: details,
    );
    return AgentAccessReply(
      ok ? HttpStatus.ok : _workflowHttpStatus(response),
      ok ? response : _errorPayloadFromWorkflowResponse(response),
    );
  }

  // coverage-gate: resolve_project_postgres_context_reply
  Future<Object> _resolveProjectPostgresContextReply(String projectId) async {
    final project = await _findProject(projectId);
    if (project == null) {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'invalid_project',
        'message': 'project_id does not match a saved project.',
      });
    }
    final serverId = project.serverId?.trim();
    if (serverId == null || serverId.isEmpty) {
      return const AgentAccessReply(
        HttpStatus.preconditionFailed,
        <String, dynamic>{
          'error': 'project_server_missing',
          'message': 'The selected project is not linked to a server.',
        },
      );
    }
    final server = await _findServer(serverId);
    if (server == null) {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'invalid_server',
        'message': 'The selected project server is not saved locally.',
      });
    }
    if (server.serviceDatabaseEnabled != true) {
      return const AgentAccessReply(
        HttpStatus.preconditionFailed,
        <String, dynamic>{
          'error': 'postgres_disabled',
          'message': 'Managed PostgreSQL is not enabled for this server.',
        },
      );
    }
    final superuserPassword = server.postgresConfig.superuserPassword?.trim();
    if (superuserPassword == null || superuserPassword.isEmpty) {
      return const AgentAccessReply(
        HttpStatus.preconditionFailed,
        <String, dynamic>{
          'error': 'postgres_credentials_missing',
          'message':
              'Managed PostgreSQL credentials are missing in local settings.',
        },
      );
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid_connection',
        'message': 'Selected server credentials are incomplete.',
      });
    }
    final settings = buildManagedPostgresProjectSettings(
      projectName: project.name,
      config: server.postgresConfig,
    );
    return (
      project: project,
      server: server,
      connection: connection,
      settings: settings,
    );
  }
  // end coverage-gate

  Future<Map<String, dynamic>> _runPostgresAgentWorkflow({
    required ({
      Project project,
      Server server,
      Map<String, dynamic> connection,
      Map<String, dynamic> settings,
    })
    context,
    required String operationId,
    Map<String, dynamic>? settingsOverrides,
  }) async {
    final settings = <String, dynamic>{
      ...context.settings,
      ...?settingsOverrides,
    };
    return (await ref
            .read(sshServiceProvider)
            .runWorkflow(
              workflowId: 'postgres',
              operationId: operationId,
              connection: context.connection,
              params: <String, dynamic>{'dry_run': false, 'settings': settings},
            ))
        .diagnosticPayload;
  }

  int _workflowHttpStatus(Map<String, dynamic> response) {
    final code = response['code']?.toString().trim();
    return switch (code) {
      'ENGINE_VALIDATION_ERROR' => HttpStatus.badRequest,
      'ENGINE_TASK_CANCELLED' => HttpStatus.conflict,
      _ => HttpStatus.badGateway,
    };
  }

  Map<String, dynamic> _errorPayloadFromWorkflowResponse(
    Map<String, dynamic> response,
  ) {
    return <String, dynamic>{
      'error':
          response['code']?.toString().trim().toLowerCase() ?? 'workflow_error',
      'message':
          response['msg']?.toString().trim() ?? 'Workflow request failed.',
      // toString-first: trimOrNull takes String? (D-87).
      if (trimOrNull(response['details']?.toString()) != null)
        'details': response['details'],
      if (response['service_status'] is Map)
        'service_status': response['service_status'],
      if (response['engine_version'] != null)
        'engine_version': response['engine_version'],
      if (response['host'] != null) 'host': response['host'],
      if (response['port'] != null) 'port': response['port'],
      if (response['operation_id'] != null)
        'operation_id': response['operation_id'],
    };
  }

  Future<Map<String, dynamic>> _sqlAuditDetails(String sql) async {
    final normalized = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = normalized.length <= 240
        ? normalized
        : normalized.substring(0, 240);
    final digest = await Sha256().hash(utf8.encode(sql));
    final hash = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return <String, dynamic>{'sql_preview': preview, 'sql_sha256': hash};
  }
}
