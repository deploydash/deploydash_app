part of '../../agent_access_service.dart';

/// Read-only tools answering about saved servers and about Agent Access
/// itself — status, session state, and the audit trail.
extension _AgentAccessServerTools on AgentAccessService {
  Future<AgentAccessReply> _replyStatus() async {
    final status = await readStatus();
    return AgentAccessReply(HttpStatus.ok, status.toApiJson());
  }

  // coverage-gate: reply_list_servers
  Future<AgentAccessReply> _replyListServers() async {
    final servers = await ref.read(serverRepositoryProvider).listServers();
    await _audit(
      toolName: 'list_servers',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Listed saved servers for agent access.',
      details: <String, dynamic>{'count': servers.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'servers': servers
          .map(
            (server) => <String, dynamic>{
              'id': server.id,
              'name': server.name,
              'host': server.host,
              'port': server.port,
              'ssh_user': server.sshUser,
              'services': <String, dynamic>{
                'postgres_enabled': server.serviceDatabaseEnabled,
                'email_enabled': server.serviceEmailEnabled,
                'domains_enabled': server.serviceDomainEnabled,
              },
            },
          )
          .toList(growable: false),
    });
  }
  // end coverage-gate

  Future<AgentAccessReply> _replyServerOverview(String serverId) async {
    final server = await _findServer(serverId);
    if (server == null) {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'invalid_server',
        'message': 'server_id does not match a saved server.',
      });
    }
    final connection = await _buildConnectionPayload(server);
    if (connection == null) {
      return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid_connection',
        'message': 'Selected server credentials are incomplete.',
      });
    }
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
      final ok = response['status'] == 'success';
      await _audit(
        toolName: 'get_server_overview',
        accessLevel: 'read_only',
        status: ok ? 'success' : 'failed',
        summary: ok
            ? 'Fetched live server overview metrics.'
            : 'Server overview metric fetch failed.',
        details: <String, dynamic>{'server_id': server.id},
      );
      return AgentAccessReply(
        ok ? HttpStatus.ok : HttpStatus.badGateway,
        <String, dynamic>{
          'server': <String, dynamic>{
            'id': server.id,
            'name': server.name,
            'host': server.host,
            'port': server.port,
            'ssh_user': server.sshUser,
          },
          'metrics': response['metrics'],
          'status': response['status'],
          'message': response['msg'],
        },
      );
    } on Object catch (error, stackTrace) {
      // Same rule as the transport catch-all: a fixed sentence on the wire.
      // What an exception stringifies to is not a contract, and an engine
      // failure wrapping a connection carries host, user and path detail into
      // it. The stack goes to stderr for local debugging.
      stderr.writeln(
        'Agent Access server overview failed: $error\n$stackTrace',
      );
      return const AgentAccessReply(
        HttpStatus.internalServerError,
        <String, dynamic>{
          'error': 'internal_error',
          'message': 'Deploy Dash could not read this server\'s overview.',
        },
      );
    }
  }

  Future<AgentAccessReply> _replyAudit({int limit = 20}) async {
    final recent = await ref
        .read(agentAuditRepositoryProvider)
        .listRecent(limit: limit);
    // Recorded after the read, so this call does not appear in its own
    // result. The audit trail exists to show what an agent did, and reading
    // the trail was the one agent action it did not show -- which is exactly
    // the action worth seeing, since it is how an agent learns what the user
    // can see about it.
    await _audit(
      toolName: 'read_audit',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Read the Agent Access audit trail.',
      details: <String, dynamic>{'count': recent.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'audit_entries': recent
          .map(
            (entry) => <String, dynamic>{
              'id': entry.id,
              'tool_name': entry.toolName,
              'access_level': entry.accessLevel,
              'status': entry.status,
              'summary': entry.summary,
              'details': sanitizeSensitiveData(entry.details),
              'created_at': entry.createdAt.toIso8601String(),
            },
          )
          .toList(growable: false),
    });
  }

  Future<AgentAccessReply> _replyAgentSessionStatus() async {
    final status = await readStatus();
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'session_status': <String, dynamic>{
        'enabled': status.enabled,
        'permission_mode': status.permissionMode,
        'server_running': status.serverRunning,
        'port': status.port,
        'has_active_session': status.hasActiveSession,
        'session_expires_at': status.sessionExpiresAt?.toIso8601String(),
        'server_error': status.serverError,
      },
    });
  }

  Future<AgentAccessReply> _replyResourceTaskHistory() async {
    final status = await readStatus();
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'task_history': status.recentTaskResults
          .map(_taskHistoryEntryToJson)
          .toList(growable: false),
    });
  }
}
