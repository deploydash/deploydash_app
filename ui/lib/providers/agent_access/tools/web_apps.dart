part of '../../agent_access_service.dart';

/// Read-only tools answering about projects and their deployed web apps:
/// saved configuration, deploy history, and deploy and runtime logs.
extension _AgentAccessWebAppTools on AgentAccessService {
  // coverage-gate: agent_web_app_read_replies
  Future<AgentAccessReply> _replyListProjects() async {
    final projects = await ref.read(projectRepositoryProvider).listProjects();
    await _audit(
      toolName: 'list_projects',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Listed saved projects for agent access.',
      details: <String, dynamic>{'count': projects.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'projects': projects
          .map(
            (project) => <String, dynamic>{
              'id': project.id,
              'server_id': project.serverId,
              'name': project.name,
              'type': project.type,
              'primary_hostname': project.primaryDomain,
              'repository_full_name': project.repositoryFullName,
              'branch': project.deployBranch,
            },
          )
          .toList(growable: false),
    });
  }

  Future<AgentAccessReply> _replyListWebApps() async {
    final projects = await ref.read(projectRepositoryProvider).listProjects();
    final webApps = projects
        .where((project) => project.type.trim().toLowerCase() == 'web app')
        .map(_projectConfig)
        .toList(growable: false);
    await _audit(
      toolName: 'list_web_apps',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Listed web app deployment targets for agent access.',
      details: <String, dynamic>{'count': webApps.length},
    );
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'web_apps': webApps,
    });
  }

  Future<AgentAccessReply> _replyWebAppDetails(String projectId) async {
    try {
      final project = await _requireProject(projectId);
      await _audit(
        toolName: 'get_web_app_details',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'Read saved web app deployment settings.',
        details: <String, dynamic>{'project_id': project.id},
      );
      return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
        'web_app': _projectConfig(project),
        'runtime_options': railpackRuntimeOptions
            .map(
              (option) => <String, dynamic>{
                'id': option.id,
                'label': option.label,
                'provider': option.provider,
                'suggested_port': option.suggestedPort,
              },
            )
            .toList(growable: false),
        'hostname_behavior_options': deployDashHostnameBehaviorOptions,
      });
    } on StateError {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'unknown_web_app',
        'message': 'web_app_id does not match a saved web app.',
      });
    }
  }

  Future<AgentAccessReply> _replyWebAppSource(String projectId) async {
    final detailsReply = await _replyWebAppDetails(projectId);
    if (!detailsReply.isSuccess) {
      return detailsReply;
    }
    final webApp = detailsReply.body['web_app'] as Map<String, dynamic>;
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'source': <String, dynamic>{
        'web_app_id': webApp['id'],
        'repository_full_name': webApp['repository_full_name'],
        'branch': webApp['branch'],
        'primary_hostname': webApp['primary_hostname'],
        'hostname_behavior': webApp['hostname_behavior'],
        'runtime': webApp['runtime'],
        'build_command': webApp['build_command'],
        'run_command': webApp['run_command'],
        'port': webApp['port'],
        'app_subdirectory': webApp['app_subdirectory'],
        'runtime_options': detailsReply.body['runtime_options'],
        'hostname_behavior_options':
            detailsReply.body['hostname_behavior_options'],
      },
    });
  }

  Future<AgentAccessReply> _replyDeployHistory(
    String projectId, {
    int limit = 10,
  }) async {
    try {
      final project = await _requireProject(projectId);
      final history = await ref
          .read(appDeploymentHistoryRepositoryProvider)
          .listForProject(project.id, limit: limit);
      await _audit(
        toolName: 'get_deploy_history',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'Read web app deployment history.',
        details: <String, dynamic>{
          'project_id': project.id,
          'count': history.length,
        },
      );
      return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
        'deploy_history': history
            .map(
              (entry) => <String, dynamic>{
                'id': entry.id,
                'status': entry.status,
                'deployed_at': entry.deployedAt.toIso8601String(),
                'duration_seconds': entry.durationSeconds,
                'actor': entry.actor,
                'branch': entry.branch,
                'commit': entry.commit,
              },
            )
            .toList(growable: false),
      });
    } on StateError {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'unknown_web_app',
        'message': 'web_app_id does not match a saved web app.',
      });
    }
  }

  Future<AgentAccessReply> _replyWebAppStatus(String projectId) async {
    final detailsReply = await _replyWebAppDetails(projectId);
    if (!detailsReply.isSuccess) {
      return detailsReply;
    }
    final historyReply = await _replyDeployHistory(projectId);
    if (!historyReply.isSuccess) {
      return historyReply;
    }
    final webApp = detailsReply.body['web_app'] as Map<String, dynamic>;
    final deployHistory =
        (historyReply.body['deploy_history'] as List?) ?? const <dynamic>[];
    final latest = deployHistory.isNotEmpty ? deployHistory.first : null;
    return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
      'status': <String, dynamic>{
        'web_app_id': webApp['id'],
        'name': webApp['name'],
        'repository_full_name': webApp['repository_full_name'],
        'branch': webApp['branch'],
        'primary_hostname': webApp['primary_hostname'],
        'runtime': webApp['runtime'],
        'last_deployed_at': webApp['last_deployed_at'],
        'latest_deploy': latest,
        'recent_deploys': deployHistory,
      },
    });
  }

  // coverage-gate: reply_deploy_logs
  Future<AgentAccessReply> _replyDeployLogs(
    String projectId, {
    int limit = 200,
  }) async {
    try {
      final project = await _requireProject(projectId);
      final records = await ref
          .read(terminalLogRepositoryProvider)
          .listRecentLogsForTaskType(
            taskType: 'app_deploy',
            // Without this the query returns every project's deploy logs and
            // the response labels them with the requested web_app_id -- one
            // project's timeline shown under another's name.
            projectId: project.id,
            limit: limit,
          );
      await _audit(
        toolName: 'get_deploy_logs',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'Read recent deploy timeline logs.',
        details: <String, dynamic>{
          'project_id': project.id,
          'count': records.length,
        },
      );
      return AgentAccessReply(HttpStatus.ok, <String, dynamic>{
        'web_app_id': project.id,
        'deploy_logs': records
            .map(
              (record) => <String, dynamic>{
                'id': record.id,
                'server_label': record.serverLabel,
                'message': record.message,
                'rendered_line': record.renderedLine,
                'source': record.source,
                'task_type': record.taskType,
                'created_at': record.createdAt.toIso8601String(),
              },
            )
            .toList(growable: false),
      });
    } on StateError {
      return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
        'error': 'unknown_web_app',
        'message': 'web_app_id does not match a saved web app.',
      });
    }
  }
  // end coverage-gate

  Future<AgentAccessReply> _replyRuntimeLogs(
    String projectId, {
    required String serverId,
    int tailLines = 200,
  }) async {
    // Resolved through the null-returning lookups rather than `_require*`
    // inside a `try`. This used to catch `StateError` and work out which of
    // the two had failed by testing the message for 'Unknown server id', so
    // rewording a string in `agent_access_service.dart` would have silently
    // started reporting a missing server as a missing web app -- with no test
    // failure, because both answers are a 404. The order of the three checks
    // is unchanged.
    {
      final project = await _findProject(projectId);
      if (project == null) {
        return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
          'error': 'unknown_web_app',
          'message': 'web_app_id does not match a saved web app.',
        });
      }
      if (serverId.trim().isEmpty) {
        return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
          'error': 'invalid_server',
          'message': 'server_id is required.',
        });
      }
      final server = await _findServer(serverId);
      if (server == null) {
        return const AgentAccessReply(HttpStatus.notFound, <String, dynamic>{
          'error': 'invalid_server',
          'message': 'server_id does not match a saved server.',
        });
      }
      if (project.serverId != null && project.serverId != server.id) {
        return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
          'error': 'project_server_mismatch',
          'message': 'server_id does not match this web app.',
        });
      }
      final connection = await _buildConnectionPayload(server);
      if (connection == null) {
        return const AgentAccessReply(HttpStatus.badRequest, <String, dynamic>{
          'error': 'invalid_connection',
          'message': 'Selected server credentials are incomplete.',
        });
      }
      final logLines = <String>[];
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
                      'settings': buildRuntimeLogSettings(project),
                    },
                    onEvent: (event) {
                      final message = event['message']?.toString().trim();
                      if (message == null || message.isEmpty) {
                        return;
                      }
                      logLines.add(message);
                    },
                  ))
              .diagnosticPayload;
      final ok = response['status'] == 'success';
      await _audit(
        toolName: 'get_runtime_logs',
        accessLevel: 'read_only',
        status: ok ? 'success' : 'failed',
        summary: ok
            ? 'Fetched runtime logs for web app.'
            : 'Runtime log fetch failed.',
        details: <String, dynamic>{
          'project_id': project.id,
          'server_id': server.id,
          'tail_lines': tailLines,
        },
      );
      return AgentAccessReply(
        ok ? HttpStatus.ok : HttpStatus.badGateway,
        <String, dynamic>{
          'status': response['status'],
          'message': response['msg'],
          'log_tail_lines': response['log_tail_lines'],
          'events': logLines,
        },
      );
    }
  }

  // end coverage-gate
}
