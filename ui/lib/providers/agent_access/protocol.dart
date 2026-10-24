import 'dart:convert';

import 'authorization.dart';

/// The Model Context Protocol surface Agent Access speaks, with no knowledge
/// of HTTP.
///
/// Everything here is about *what* is said — the tool and resource catalogs,
/// the JSON-RPC envelopes, session negotiation — never about the socket that
/// carries it. `transport.dart` owns the socket and calls into this; the tool
/// handlers own the answers. Splitting it out this way (T-3.5.3) is what lets
/// the catalog and the codec be exercised as values rather than by issuing
/// requests against a running listener.
///
/// The published surface this describes is frozen by
/// `test/services/agent_access_surface_test.dart`.

/// Version of the Agent Access tool surface: the tool names and the shapes
/// they answer with.
///
/// Deliberately three things at once that it is **not**. It is not the
/// release version in `serverInfo.version`, which moves on every build. It is
/// not the MCP protocol date, which belongs to the specification. And it is
/// not derived from either, because the tool names change on their own
/// schedule — an agent pinning a release version learns nothing about whether
/// the tool it calls still exists.
///
/// Bump it whenever a tool is added, renamed, removed, or changes the shape
/// of what it returns.
/// `test/services/agent_access_surface_test.dart` freezes the names against
/// this number, so the two cannot move apart.
const int agentAccessSurfaceVersion = 2;

/// The `capabilities.experimental` block returned by MCP `initialize`.
///
/// `experimental` is the MCP specification's slot for vendor extensions, so
/// declaring the surface version here cannot collide with a future standard
/// capability key.
const Map<String, dynamic> agentAccessExperimentalCapabilities =
    <String, dynamic>{
      'deploydash': <String, dynamic>{
        'surfaceVersion': agentAccessSurfaceVersion,
      },
    };

/// Header naming the MCP session on every request and response.
const String mcpSessionIdHeader = 'Mcp-Session-Id';

/// Header echoing the negotiated MCP protocol date.
const String mcpProtocolVersionHeader = 'MCP-Protocol-Version';

/// The only JSON-RPC version this endpoint accepts.
const String mcpJsonRpcVersion = '2.0';

/// Protocol date used when a client asks for one this build does not know.
const String mcpDefaultProtocolVersion = '2025-11-25';

/// MCP specification dates this endpoint can negotiate.
const Set<String> mcpSupportedProtocolVersions = <String>{
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  '2025-11-25',
  '2026-07-28',
};

/// Encoder for the human-readable text mirror of every structured result.
const JsonEncoder mcpPrettyJsonEncoder = JsonEncoder.withIndent('  ');

/// Server name reported by MCP `initialize`.
const String mcpServerName = 'deploydash-agent-access';

/// Server version reported by MCP `initialize`.
///
/// The release version, which moves on every build. It is not a usable pin for
/// an agent — [agentAccessSurfaceVersion] is.
const String mcpServerVersion = String.fromEnvironment(
  'DEPLOYDASH_RELEASE_VERSION',
  defaultValue: '0',
);

/// Guidance returned by MCP `initialize`.
const String mcpInitializeInstructions =
    'Deploy Dash Agent Access exposes local project, server, deploy, '
    'task, audit, and managed PostgreSQL inspection tools over MCP. '
    'Use MCP tools/list as the source of truth for callable tools in '
    'the current session. The deploydash_list_workflows tool is a '
    'descriptive catalog, not proof that a tool is attached in the '
    'client session.';

/// Tool names an agent can call without the redeploy permission mode.
Set<String> get agentAccessReadOnlyToolNames => mcpToolDefinitions(
  includeActionTools: false,
).map((tool) => tool.name).toSet();

/// Tool names reachable only once the user grants redeploy permission.
Set<String> get agentAccessActionToolNames => mcpToolDefinitions(
  includeActionTools: true,
).map((tool) => tool.name).toSet().difference(agentAccessReadOnlyToolNames);

/// One handler answer, before it is framed as either HTTP or MCP.
///
/// Carries an HTTP status because both framings expose it: the transport uses
/// it as the response code, and `tools/call` reports it as `_meta.httpStatus`
/// so an MCP client can tell a refusal from a failure.
class AgentAccessReply {
  /// Creates a reply carrying [statusCode] and [body].
  const AgentAccessReply(this.statusCode, this.body);

  /// HTTP status this answer corresponds to.
  final int statusCode;

  /// The structured answer itself.
  final Map<String, dynamic> body;

  /// Whether [statusCode] is a 2xx.
  bool get isSuccess => statusCode >= 200 && statusCode < 300;
}

/// One negotiated MCP session.
class McpSessionState {
  /// Creates a session record.
  const McpSessionState({
    required this.id,
    required this.protocolVersion,
    required this.createdAt,
    required this.lastSeenAt,
  });

  /// Opaque session id, echoed in [mcpSessionIdHeader].
  final String id;

  /// Protocol date agreed with the client at `initialize`.
  final String protocolVersion;

  /// When the session was negotiated.
  final DateTime createdAt;

  /// When the session was last used.
  final DateTime lastSeenAt;

  /// Returns a copy with [lastSeenAt] moved to now.
  McpSessionState touch() {
    return McpSessionState(
      id: id,
      protocolVersion: protocolVersion,
      createdAt: createdAt,
      lastSeenAt: DateTime.now().toUtc(),
    );
  }
}

/// One MCP resource as `resources/list` publishes it.
class McpResourceDefinition {
  /// Creates a resource description.
  const McpResourceDefinition({
    required this.uri,
    required this.name,
    required this.description,
  });

  /// The `deploydash://` uri a client reads.
  final String uri;

  /// Human-readable name.
  final String name;

  /// What the resource contains.
  final String description;

  /// The `resources/list` entry for this resource.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'uri': uri,
      'name': name,
      'description': description,
      'mimeType': 'application/json',
    };
  }
}

/// One MCP tool as `tools/list` publishes it.
///
/// Lives beside the surface version rather than in the service, because it is
/// the description of the frozen surface rather than part of serving it.
class McpToolDefinition {
  /// Creates a tool description.
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.accessLevel,
    this.destructive = false,
  });

  /// The frozen, contract-published tool name.
  final String name;

  /// What the tool does, in one sentence for the calling agent.
  final String description;

  /// JSON Schema for the tool's arguments.
  final Map<String, dynamic> inputSchema;

  /// `read_only`, or the permission mode the tool requires.
  final String accessLevel;

  /// Whether calling the tool changes server state.
  final bool destructive;

  /// The `tools/list` entry for this tool.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'inputSchema': inputSchema,
      'annotations': <String, dynamic>{
        'title': name,
        'readOnlyHint': accessLevel == 'read_only',
        'destructiveHint': destructive,
        'idempotentHint': !destructive,
        'openWorldHint': false,
      },
    };
  }
}

/// Negotiates a new session from an `initialize` [message].
///
/// A protocol version this build does not know falls back to
/// [mcpDefaultProtocolVersion] rather than failing: the specification expects
/// the server to answer with a version it can actually speak.
McpSessionState negotiateMcpSession(Map<String, dynamic> message) {
  final params = mcpMapOrNull(message['params']) ?? const <String, dynamic>{};
  final requestedVersion =
      params['protocolVersion']?.toString().trim() ?? mcpDefaultProtocolVersion;
  final protocolVersion =
      mcpSupportedProtocolVersions.contains(requestedVersion)
      ? requestedVersion
      : mcpDefaultProtocolVersion;
  final now = DateTime.now().toUtc();
  return McpSessionState(
    id: AgentAccessAuthorization.generateToken(),
    protocolVersion: protocolVersion,
    createdAt: now,
    lastSeenAt: now,
  );
}

/// Decodes [body] as a JSON-RPC request.
///
/// Returns the decoded message on success, or an [AgentAccessReply] describing
/// the refusal. Returning rather than throwing keeps the caller's error
/// handling in one place instead of split across a try block.
Object parseJsonRpcRequest(String body) {
  if (body.trim().isEmpty) {
    return const AgentAccessReply(400, <String, dynamic>{
      'error': 'invalid_request',
      'message': 'MCP requests must include a JSON-RPC message body.',
    });
  }
  final decoded = jsonDecode(body);
  if (decoded is! Map) {
    return const AgentAccessReply(400, <String, dynamic>{
      'error': 'invalid_request',
      'message': 'MCP requests must be a single JSON-RPC object.',
    });
  }
  final message = decoded.map((key, value) => MapEntry(key.toString(), value));
  if (message['jsonrpc']?.toString() != mcpJsonRpcVersion) {
    return const AgentAccessReply(400, <String, dynamic>{
      'error': 'invalid_request',
      'message': 'Unsupported JSON-RPC version.',
    });
  }
  if ((message['method']?.toString().trim() ?? '').isEmpty) {
    return const AgentAccessReply(400, <String, dynamic>{
      'error': 'invalid_request',
      'message': 'JSON-RPC method is required.',
    });
  }
  return message;
}

/// The `initialize` result for [session].
Map<String, dynamic> buildInitializeResult(McpSessionState session) {
  return <String, dynamic>{
    'protocolVersion': session.protocolVersion,
    'capabilities': <String, dynamic>{
      'tools': <String, dynamic>{'listChanged': false},
      'resources': <String, dynamic>{'subscribe': false, 'listChanged': false},
      'experimental': agentAccessExperimentalCapabilities,
    },
    'serverInfo': <String, dynamic>{
      'name': mcpServerName,
      'version': mcpServerVersion,
    },
    'instructions': mcpInitializeInstructions,
  };
}

/// Frames [reply] as a `tools/call` result.
///
/// Both a text mirror and `structuredContent` are sent: clients that cannot
/// read structured output still get something legible.
Map<String, dynamic> buildToolCallResult(AgentAccessReply reply) {
  return <String, dynamic>{
    '_meta': <String, dynamic>{'httpStatus': reply.statusCode},
    'content': <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'text',
        'text': mcpPrettyJsonEncoder.convert(reply.body),
      },
    ],
    'structuredContent': reply.body,
    'isError': !reply.isSuccess,
  };
}

/// Frames [reply] as the `resources/read` contents of [uri].
Map<String, dynamic> buildResourceContents(String uri, AgentAccessReply reply) {
  return <String, dynamic>{
    'contents': <Map<String, dynamic>>[
      <String, dynamic>{
        'uri': uri,
        'mimeType': 'application/json',
        'text': mcpPrettyJsonEncoder.convert(reply.body),
      },
    ],
  };
}

/// The JSON-RPC success envelope carrying [result] for [id].
Map<String, dynamic> jsonRpcResultEnvelope({
  required Object? id,
  required Map<String, dynamic> result,
}) {
  return <String, dynamic>{
    'jsonrpc': mcpJsonRpcVersion,
    'id': id,
    'result': result,
  };
}

/// The JSON-RPC error envelope for [id].
Map<String, dynamic> jsonRpcErrorEnvelope({
  required Object? id,
  required int code,
  required String message,
}) {
  return <String, dynamic>{
    'jsonrpc': mcpJsonRpcVersion,
    'id': id,
    'error': <String, dynamic>{'code': code, 'message': message},
  };
}

/// Returns [value] as a string-keyed map, or `null` when it is not a map.
///
/// JSON-RPC params arrive as `Map<dynamic, dynamic>`; every reader wants
/// string keys, so the coercion has one owner rather than one per call site.
Map<String, dynamic>? mcpMapOrNull(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return null;
}

/// The tool catalog `tools/list` publishes.
///
/// [includeActionTools] is the permission gate: the three redeploy-capable
/// tools are appended only once the user has granted that mode, so a read-only
/// session cannot even see their names.
List<McpToolDefinition> mcpToolDefinitions({required bool includeActionTools}) {
  final tools = <McpToolDefinition>[
    const McpToolDefinition(
      name: 'deploydash_status',
      description: 'Read Agent Access server and session status.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_servers',
      description: 'List saved Deploy Dash servers.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_server_overview',
      description: 'Read one live server overview by server id.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'server_id': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['server_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_projects',
      description: 'List saved Deploy Dash projects.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_web_apps',
      description: 'List saved Deploy Dash web apps.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_web_app_details',
      description: 'Read one saved web app deployment configuration.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['web_app_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_web_app_source',
      description:
          'Read the saved GitHub source and build settings for a web app.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['web_app_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_web_app_status',
      description: 'Read a web app summary with recent deploy history.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['web_app_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_deploy_history',
      description: 'Read recent deploy history for a web app.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
          'limit': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['web_app_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_deploy_logs',
      description: 'Read recent deploy timeline logs for a web app.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
          'limit': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['web_app_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_runtime_logs',
      description:
          'Fetch recent runtime logs for a web app from a selected server.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'web_app_id': <String, dynamic>{'type': 'string'},
          'server_id': <String, dynamic>{'type': 'string'},
          'tail_lines': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['web_app_id', 'server_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_task_history',
      description: 'Read recent app workflow task history.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'limit': <String, dynamic>{'type': 'integer'},
        },
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_task',
      description: 'Read one recent app workflow task status by task id.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'task_id': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['task_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_task_events',
      description: 'Poll recent events for an app workflow task.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'task_id': <String, dynamic>{'type': 'integer'},
          'max_events': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['task_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_get_task_result',
      description: 'Read the final result envelope for an app workflow task.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'task_id': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['task_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_evaluate_conflict',
      description:
          'Preview queue or conflict state for a Deploy Dash workflow operation.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'workflow_id': <String, dynamic>{'type': 'string'},
          'operation_id': <String, dynamic>{'type': 'string'},
          'connection': <String, dynamic>{'type': 'object'},
          'params': <String, dynamic>{'type': 'object'},
          'serialize_per_host': <String, dynamic>{'type': 'boolean'},
        },
        'required': <String>['workflow_id', 'operation_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_github_repositories',
      description:
          'List GitHub repositories visible to the connected Deploy Dash GitHub account.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_repository_branches',
      description: 'List Git branches for a visible GitHub repository.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'repository_full_name': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['repository_full_name'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_workflows',
      description:
          'Describe the Deploy Dash Agent Access catalog for guidance only. '
          'Use MCP tools/list as the source of truth for callable tools in '
          'the current session.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_read_audit',
      description: 'Read the recent agent-access audit trail.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'limit': <String, dynamic>{'type': 'integer'},
        },
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_postgres_databases',
      description:
          'List managed PostgreSQL databases for one project. Use this first '
          'before schema, table, or query tools.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['project_id'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_postgres_schemas',
      description:
          'List PostgreSQL schemas for one project database after choosing a '
          'project database.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
          'database_name': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['project_id', 'database_name'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_list_postgres_tables',
      description:
          'List PostgreSQL tables for one project database after choosing a '
          'schema or database.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
          'database_name': <String, dynamic>{'type': 'string'},
          'schema_name': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['project_id', 'database_name'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_describe_postgres_table',
      description:
          'Describe one PostgreSQL table for a project database before '
          'writing a read-only query.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
          'database_name': <String, dynamic>{'type': 'string'},
          'table_name': <String, dynamic>{'type': 'string'},
          'schema_name': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['project_id', 'database_name', 'table_name'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_explain_postgres_query',
      description:
          'Explain one read-only PostgreSQL query for a project database '
          'before execution.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
          'database_name': <String, dynamic>{'type': 'string'},
          'sql': <String, dynamic>{'type': 'string'},
        },
        'required': <String>['project_id', 'database_name', 'sql'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
    const McpToolDefinition(
      name: 'deploydash_execute_postgres_readonly_query',
      description:
          'Execute one bounded read-only PostgreSQL query for a project '
          'database and return row data.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'project_id': <String, dynamic>{'type': 'string'},
          'database_name': <String, dynamic>{'type': 'string'},
          'sql': <String, dynamic>{'type': 'string'},
          'max_rows': <String, dynamic>{'type': 'integer'},
        },
        'required': <String>['project_id', 'database_name', 'sql'],
        'additionalProperties': false,
      },
      accessLevel: 'read_only',
    ),
  ];
  if (includeActionTools) {
    tools.addAll(const <McpToolDefinition>[
      McpToolDefinition(
        name: 'deploydash_prepare_web_app_redeploy',
        description:
            'Preview a web app redeploy using saved Deploy Dash state plus any supplied overrides.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'web_app_id': <String, dynamic>{'type': 'string'},
            'server_id': <String, dynamic>{'type': 'string'},
            'project_id': <String, dynamic>{'type': 'string'},
            'repository_full_name': <String, dynamic>{'type': 'string'},
            'primary_hostname': <String, dynamic>{'type': 'string'},
            'hostname_behavior': <String, dynamic>{'type': 'string'},
            'branch': <String, dynamic>{'type': 'string'},
            'port': <String, dynamic>{'type': 'integer'},
            'runtime': <String, dynamic>{'type': 'string'},
            'build_command': <String, dynamic>{'type': 'string'},
            'run_command': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['web_app_id', 'server_id', 'project_id'],
          'additionalProperties': false,
        },
        accessLevel: 'redeploy',
      ),
      McpToolDefinition(
        name: 'deploydash_redeploy_web_app',
        description:
            'Update saved web app deploy settings if needed, then trigger a Deploy Dash redeploy.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'web_app_id': <String, dynamic>{'type': 'string'},
            'server_id': <String, dynamic>{'type': 'string'},
            'project_id': <String, dynamic>{'type': 'string'},
            'repository_full_name': <String, dynamic>{'type': 'string'},
            'primary_hostname': <String, dynamic>{'type': 'string'},
            'hostname_behavior': <String, dynamic>{'type': 'string'},
            'branch': <String, dynamic>{'type': 'string'},
            'port': <String, dynamic>{'type': 'integer'},
            'runtime': <String, dynamic>{'type': 'string'},
            'build_command': <String, dynamic>{'type': 'string'},
            'run_command': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['web_app_id', 'server_id', 'project_id'],
          'additionalProperties': false,
        },
        accessLevel: 'redeploy',
        destructive: true,
      ),
      McpToolDefinition(
        name: 'deploydash_cancel_task',
        description:
            'Cancel a running Deploy Dash task using the active redeploy session.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'task_id': <String, dynamic>{'type': 'integer'},
          },
          'required': <String>['task_id'],
          'additionalProperties': false,
        },
        accessLevel: 'redeploy',
        destructive: true,
      ),
    ]);
  }
  return tools;
}

/// The analytics-safe tool name for [toolName], or null when it is not one of
/// the frozen catalog names above. Unknown tool names report nothing: the
/// analytics vocabulary is the frozen catalog, not whatever a client sent.
String? agentAnalyticsToolNameOrNull(String toolName) {
  if (toolName.isEmpty) {
    return null;
  }
  final known = mcpToolDefinitions(
    includeActionTools: true,
  ).any((tool) => tool.name == toolName);
  return known ? toolName : null;
}

/// The resource catalog `resources/list` publishes.
List<McpResourceDefinition> mcpResourceDefinitions() {
  return const <McpResourceDefinition>[
    McpResourceDefinition(
      uri: 'deploydash://status',
      name: 'Deploy Dash status',
      description: 'Agent Access server and session status.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://servers',
      name: 'Deploy Dash servers',
      description: 'Saved Deploy Dash servers.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://projects',
      name: 'Deploy Dash projects',
      description: 'Saved Deploy Dash projects.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://web-apps',
      name: 'Deploy Dash web apps',
      description: 'Saved Deploy Dash web apps.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://workflow-catalog',
      name: 'Deploy Dash workflow catalog',
      description: 'Current MCP tool catalog and related resources.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://recent-task-history',
      name: 'Deploy Dash recent task history',
      description: 'Recent task history from the desktop app.',
    ),
    McpResourceDefinition(
      uri: 'deploydash://agent-session-status',
      name: 'Deploy Dash agent session status',
      description: 'Current read-only and redeploy session state.',
    ),
  ];
}
