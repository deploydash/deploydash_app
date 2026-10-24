part of '../../agent_access_service.dart';

/// Routing from an MCP method or tool name to the handler that answers it.
///
/// The seam between `protocol.dart`, which says what may be called, and the
/// per-domain handlers in this directory, which do the calling.
extension _AgentAccessToolDispatch on AgentAccessService {
  Future<AgentAccessReply> _replyListWorkflows({
    required bool includeActionTools,
  }) async {
    final tools = mcpToolDefinitions(includeActionTools: includeActionTools);
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'tools': tools
          .where((tool) => tool.accessLevel == 'read_only')
          .map(
            (tool) => <String, dynamic>{
              'name': tool.name,
              'access': tool.accessLevel,
              'description': tool.description,
            },
          )
          .toList(growable: false),
      'action_tools': tools
          .where((tool) => tool.accessLevel != 'read_only')
          .map((tool) => tool.name)
          .toList(growable: false),
      'resources': mcpResourceDefinitions()
          .map((resource) => resource.uri)
          .toList(growable: false),
    });
  }

  // coverage-gate: agent_mcp_tool_dispatch
  Future<AgentAccessReply> _callMcpTool({
    required String toolName,
    required Map<String, dynamic> arguments,
    required AppPreferencesRecord preferences,
    required String? authorization,
  }) async {
    switch (toolName) {
      case 'deploydash_status':
        return _replyStatus();
      case 'deploydash_list_servers':
        return _replyListServers();
      case 'deploydash_get_server_overview':
        return _replyServerOverview((arguments['server_id'] ?? '').toString());
      case 'deploydash_list_projects':
        return _replyListProjects();
      case 'deploydash_list_web_apps':
        return _replyListWebApps();
      case 'deploydash_get_web_app_details':
        return _replyWebAppDetails((arguments['web_app_id'] ?? '').toString());
      case 'deploydash_get_web_app_source':
        return _replyWebAppSource((arguments['web_app_id'] ?? '').toString());
      case 'deploydash_get_web_app_status':
        return _replyWebAppStatus((arguments['web_app_id'] ?? '').toString());
      case 'deploydash_get_deploy_history':
        return _replyDeployHistory(
          (arguments['web_app_id'] ?? '').toString(),
          limit: _intOrNull(arguments['limit']) ?? 10,
        );
      case 'deploydash_get_deploy_logs':
        return _replyDeployLogs(
          (arguments['web_app_id'] ?? '').toString(),
          limit: _intOrNull(arguments['limit']) ?? 200,
        );
      case 'deploydash_get_runtime_logs':
        return _replyRuntimeLogs(
          (arguments['web_app_id'] ?? '').toString(),
          serverId: (arguments['server_id'] ?? '').toString(),
          tailLines: _intOrNull(arguments['tail_lines']) ?? 200,
        );
      case 'deploydash_get_task_history':
        return _replyTaskHistory(
          preferences,
          authorization,
          limit: _intOrNull(arguments['limit']) ?? 20,
        );
      case 'deploydash_get_task':
        return _replyTaskStatus(
          preferences,
          authorization,
          arguments['task_id'],
        );
      case 'deploydash_get_task_events':
        return _replyTaskEvents(
          preferences,
          authorization,
          arguments['task_id'],
          maxEvents: _intOrNull(arguments['max_events']) ?? 100,
        );
      case 'deploydash_get_task_result':
        return _replyTaskResult(
          preferences,
          authorization,
          arguments['task_id'],
        );
      case 'deploydash_evaluate_conflict':
        return _replyEvaluateConflict(arguments);
      case 'deploydash_list_github_repositories':
        return _replyListGitHubRepositories();
      case 'deploydash_list_repository_branches':
        return _replyListRepositoryBranches(
          (arguments['repository_full_name'] ?? '').toString(),
        );
      case 'deploydash_list_workflows':
        return _replyListWorkflows(
          includeActionTools:
              preferences.agentAccessPermissionMode ==
              agentAccessPermissionRedeploy,
        );
      case 'deploydash_read_audit':
        return _replyAudit(limit: _intOrNull(arguments['limit']) ?? 20);
      case 'deploydash_list_postgres_databases':
        return _replyListPostgresDatabases(
          (arguments['project_id'] ?? '').toString(),
        );
      case 'deploydash_list_postgres_schemas':
        // toString-first: trimOrNull takes String? (D-87).
        final schemasDatabaseName = trimOrNull(
          arguments['database_name']?.toString(),
        );
        if (schemasDatabaseName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_database',
              'message': 'database_name is required.',
            },
          );
        }
        return _replyPostgresWorkflow(
          (arguments['project_id'] ?? '').toString(),
          operationId: 'project_list_schemas',
          toolName: 'deploydash_list_postgres_schemas',
          successSummary: 'Listed PostgreSQL schemas for a project database.',
          failureSummary: 'Project PostgreSQL schema listing failed.',
          auditDetails: <String, dynamic>{
            'project_id': arguments['project_id'],
            'database_name': arguments['database_name'],
          },
          settingsOverrides: <String, dynamic>{
            'database_name': schemasDatabaseName,
          },
        );
      case 'deploydash_list_postgres_tables':
        final tablesDatabaseName = trimOrNull(
          arguments['database_name']?.toString(),
        );
        if (tablesDatabaseName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_database',
              'message': 'database_name is required.',
            },
          );
        }
        return _replyPostgresWorkflow(
          (arguments['project_id'] ?? '').toString(),
          operationId: 'project_list_tables',
          toolName: 'deploydash_list_postgres_tables',
          successSummary: 'Listed PostgreSQL tables for a project database.',
          failureSummary: 'Project PostgreSQL table listing failed.',
          auditDetails: <String, dynamic>{
            'project_id': arguments['project_id'],
            'database_name': arguments['database_name'],
            if (trimOrNull(arguments['schema_name']?.toString()) != null)
              'schema_name': arguments['schema_name'],
          },
          settingsOverrides: <String, dynamic>{
            'database_name': tablesDatabaseName,
            if (trimOrNull(arguments['schema_name']?.toString()) != null)
              'schema_name': trimOrNull(arguments['schema_name']?.toString()),
          },
        );
      case 'deploydash_describe_postgres_table':
        final describeDatabaseName = trimOrNull(
          arguments['database_name']?.toString(),
        );
        if (describeDatabaseName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_database',
              'message': 'database_name is required.',
            },
          );
        }
        final tableName = trimOrNull(arguments['table_name']?.toString());
        if (tableName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_table',
              'message': 'table_name is required.',
            },
          );
        }
        return _replyPostgresWorkflow(
          (arguments['project_id'] ?? '').toString(),
          operationId: 'project_describe_table',
          toolName: 'deploydash_describe_postgres_table',
          successSummary:
              'Described a PostgreSQL table for a project database.',
          failureSummary: 'PostgreSQL table description failed.',
          auditDetails: <String, dynamic>{
            'project_id': arguments['project_id'],
            'database_name': arguments['database_name'],
            'schema_name':
                trimOrNull(arguments['schema_name']?.toString()) ?? 'public',
            'table_name': arguments['table_name'],
          },
          settingsOverrides: <String, dynamic>{
            'database_name': describeDatabaseName,
            'schema_name':
                trimOrNull(arguments['schema_name']?.toString()) ?? 'public',
            'table_name': tableName,
          },
        );
      case 'deploydash_explain_postgres_query':
        final explainDatabaseName = trimOrNull(
          arguments['database_name']?.toString(),
        );
        if (explainDatabaseName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_database',
              'message': 'database_name is required.',
            },
          );
        }
        final sql = (arguments['sql'] ?? '').toString();
        if (sql.trim().isEmpty) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_sql',
              'message': 'sql is required.',
            },
          );
        }
        return _replyPostgresWorkflow(
          (arguments['project_id'] ?? '').toString(),
          operationId: 'project_explain_readonly_query',
          toolName: 'deploydash_explain_postgres_query',
          successSummary: 'Explained a PostgreSQL read-only query.',
          failureSummary: 'PostgreSQL query explain failed.',
          auditDetails: <String, dynamic>{
            'project_id': arguments['project_id'],
            'database_name': arguments['database_name'],
            ...await _sqlAuditDetails(sql),
          },
          settingsOverrides: <String, dynamic>{
            'database_name': explainDatabaseName,
            'sql': sql,
          },
        );
      case 'deploydash_execute_postgres_readonly_query':
        final queryDatabaseName = trimOrNull(
          arguments['database_name']?.toString(),
        );
        if (queryDatabaseName == null) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_database',
              'message': 'database_name is required.',
            },
          );
        }
        final sql = (arguments['sql'] ?? '').toString();
        if (sql.trim().isEmpty) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_sql',
              'message': 'sql is required.',
            },
          );
        }
        return _replyPostgresWorkflow(
          (arguments['project_id'] ?? '').toString(),
          operationId: 'project_execute_readonly_query',
          toolName: 'deploydash_execute_postgres_readonly_query',
          successSummary: 'Executed a PostgreSQL read-only query.',
          failureSummary: 'PostgreSQL read-only query failed.',
          auditDetails: <String, dynamic>{
            'project_id': arguments['project_id'],
            'database_name': arguments['database_name'],
            if (_intOrNull(arguments['max_rows']) != null)
              'max_rows': _intOrNull(arguments['max_rows']),
            ...await _sqlAuditDetails(sql),
          },
          settingsOverrides: <String, dynamic>{
            'database_name': queryDatabaseName,
            'sql': sql,
            if (_intOrNull(arguments['max_rows']) != null)
              'max_rows': _intOrNull(arguments['max_rows']),
          },
        );
      case 'deploydash_prepare_web_app_redeploy':
        return _replyPrepareRedeploy(
          (arguments['web_app_id'] ?? '').toString(),
          arguments,
        );
      case 'deploydash_redeploy_web_app':
        return _replyRedeploy(
          (arguments['web_app_id'] ?? '').toString(),
          arguments,
          preferences,
          authorization,
        );
      case 'deploydash_cancel_task':
        return _replyCancelTask(
          arguments['task_id'],
          preferences,
          authorization,
        );
    }
    return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
      'error': 'tool_not_found',
      'message': 'Unknown MCP tool name.',
    });
  }

  McpSessionState _initializeMcpSession(Map<String, dynamic> message) {
    final session = negotiateMcpSession(message);
    _mcpSessions[session.id] = session;
    return session;
  }

  // end coverage-gate
  Future<Object?> _dispatchMcpMethod({
    required String method,
    required Map<String, dynamic> params,
    required Object? id,
    required bool hasId,
    required AppPreferencesRecord preferences,
    required String? authorization,
    required McpSessionState session,
  }) async {
    switch (method) {
      case 'initialize':
        return buildInitializeResult(session);
      case 'ping':
        return <String, dynamic>{};
      case 'tools/list':
        return <String, dynamic>{
          'tools': mcpToolDefinitions(
            includeActionTools:
                preferences.agentAccessPermissionMode ==
                agentAccessPermissionRedeploy,
          ).map((tool) => tool.toJson()).toList(growable: false),
        };
      case 'tools/call':
        final toolName = params['name']?.toString().trim();
        if (toolName == null || toolName.isEmpty) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_tool',
              'message': 'Tool name is required.',
            },
          );
        }
        final arguments =
            mcpMapOrNull(params['arguments']) ?? const <String, dynamic>{};
        final reply = await _callMcpTool(
          toolName: toolName,
          arguments: arguments,
          preferences: preferences,
          authorization: authorization,
        );
        // Only frozen catalog names report: unknown tool names stay silent so
        // the analytics vocabulary can never gain a client-invented value.
        final trackedTool = agentAnalyticsToolNameOrNull(toolName);
        if (trackedTool != null) {
          ref
              .read(appAnalyticsServiceProvider)
              .trackAgentTool(
                tool: trackedTool,
                outcome: reply.isSuccess
                    ? DataOperationOutcome.success
                    : DataOperationOutcome.failure,
              );
        }
        return buildToolCallResult(reply);
      case 'resources/list':
        return <String, dynamic>{
          'resources': mcpResourceDefinitions()
              .map((resource) => resource.toJson())
              .toList(growable: false),
        };
      case 'resources/read':
        final uri = params['uri']?.toString().trim();
        if (uri == null || uri.isEmpty) {
          return const AgentAccessReply(
            HttpStatus.badRequest,
            <String, dynamic>{
              'error': 'invalid_resource',
              'message': 'Resource uri is required.',
            },
          );
        }
        return await _readMcpResource(uri, preferences: preferences);
    }
    return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
      'error': 'method_not_found',
      'message': 'Unknown MCP method.',
    });
  }

  /// Answers `resources/read` for [uri].
  ///
  /// [preferences] is threaded in for one reason: the workflow catalog is a
  /// second rendering of the tool list, and it must answer the same question
  /// about what this session may see. It used to pass `includeActionTools:
  /// true` unconditionally, so a read-only session that could not call
  /// `tools/list` into naming the redeploy tools could read the catalog
  /// resource and get them anyway — the same concept gated at two sites and
  /// ungated at the third.
  Future<Object> _readMcpResource(
    String uri, {
    required AppPreferencesRecord preferences,
  }) async {
    late final AgentAccessReply reply;
    switch (uri) {
      case 'deploydash://status':
        reply = await _replyStatus();
        break;
      case 'deploydash://servers':
        reply = await _replyListServers();
        break;
      case 'deploydash://projects':
        reply = await _replyListProjects();
        break;
      case 'deploydash://web-apps':
        reply = await _replyListWebApps();
        break;
      case 'deploydash://workflow-catalog':
        reply = await _replyListWorkflows(
          includeActionTools:
              preferences.agentAccessPermissionMode ==
              agentAccessPermissionRedeploy,
        );
        break;
      case 'deploydash://recent-task-history':
        reply = await _replyResourceTaskHistory();
        break;
      case 'deploydash://agent-session-status':
        reply = await _replyAgentSessionStatus();
        break;
      default:
        return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
          'error': 'resource_not_found',
          'message': 'Unknown MCP resource uri.',
        });
    }
    if (!reply.isSuccess) {
      return reply;
    }
    return buildResourceContents(uri, reply);
  }
}
