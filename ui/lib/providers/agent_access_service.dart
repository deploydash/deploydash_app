// ignore_for_file: use_null_aware_elements

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/agent_audit_repository.dart';
import '../data/local/app_deployment_history_repository.dart';
import '../data/local/app_preferences_repository.dart';
import '../data/local/terminal_log_repository.dart';
import '../data/local/github_secret_repository.dart';
import '../data/local/project_repository.dart';
import '../models/deploy_failure_evidence.dart';
import '../models/result.dart';
import '../models/railpack_runtime.dart';
import '../services/app_analytics_service.dart';
import '../services/project_database_settings.dart';
import '../services/runtime_log_settings.dart';
import '../services/sensitive_data_sanitizer.dart';
import '../services/ssh_service.dart';
import '../utils/project_slug.dart';
import '../utils/trim_or_null.dart';
import 'agent_access/authorization.dart';
import 'agent_access/protocol.dart';

import 'github_integration_provider.dart';
import 'server_provider.dart';

// The listener, the MCP routing, and the tool handlers, split out by T-3.5.3.
// They stay `part` files rather than separate libraries because every one of
// them works through this class's `ref` and its shared lookup helpers, and a
// Dart class body cannot span libraries. `authorization.dart` and
// `protocol.dart` are real libraries precisely because they do NOT need those
// -- which is what makes them testable without a socket.
part 'agent_access/transport.dart';
part 'agent_access/tools/dispatch.dart';
part 'agent_access/tools/servers.dart';
part 'agent_access/tools/web_apps.dart';
part 'agent_access/tools/tasks.dart';
part 'agent_access/tools/postgres.dart';
part 'agent_access/tools/redeploy.dart';
part 'agent_access/tools/github.dart';

// coverage-gate: agent_access_endpoint_constants
const int deployDashAgentControlPort = 46337;
int? deployDashAgentControlPortOverrideForTests;
const String deployDashAgentMcpPath = '/mcp';
// end coverage-gate

String _agentFailureMessage(AppFailure failure) => switch (failure) {
  EngineFailure(:final msg) when msg.trim().isNotEmpty => msg.trim(),
  _ => failure.toString(),
};
int get resolvedDeployDashAgentControlPort =>
    deployDashAgentControlPortOverrideForTests ?? deployDashAgentControlPort;

const List<String> deployDashHostnameBehaviorOptions = <String>[
  'single_host',
  'redirect_www_to_apex',
  'redirect_apex_to_www',
];

class AgentAccessStatusSnapshot {
  const AgentAccessStatusSnapshot({
    required this.enabled,
    required this.permissionMode,
    required this.serverRunning,
    required this.port,
    this.sessionToken,
    this.sessionExpiresAt,
    this.serverError,
    this.recentActions = const <AgentAuditEntryRecord>[],
    this.runningTasks = const <EngineTaskHistoryEntry>[],
    this.recentTaskResults = const <EngineTaskHistoryEntry>[],
  });

  final bool enabled;
  final String permissionMode;
  final bool serverRunning;
  final int port;
  final String? sessionToken;
  final DateTime? sessionExpiresAt;
  final String? serverError;
  final List<AgentAuditEntryRecord> recentActions;
  final List<EngineTaskHistoryEntry> runningTasks;
  final List<EngineTaskHistoryEntry> recentTaskResults;

  bool get hasActiveSession {
    final token = sessionToken?.trim();
    final expiresAt = sessionExpiresAt;
    if (token == null || token.isEmpty || expiresAt == null) {
      return false;
    }
    return expiresAt.isAfter(DateTime.now());
  }

  Map<String, dynamic> toJson() {
    return toApiJson();
  }

  Map<String, dynamic> toApiJson() {
    // Hoisted so the emptiness check promotes it; a public final field is
    // never promoted.
    final serverError = this.serverError;
    return <String, dynamic>{
      'enabled': enabled,
      'permission_mode': permissionMode,
      'server_running': serverRunning,
      'port': port,
      'has_active_session': hasActiveSession,
      'session_expires_at': sessionExpiresAt?.toIso8601String(),
      if (serverError != null && serverError.trim().isNotEmpty)
        'server_error': serverError,
      'recent_actions': recentActions
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
      'running_tasks': runningTasks
          .map(_taskHistoryEntryToJson)
          .toList(growable: false),
      'recent_task_results': recentTaskResults
          .map(_taskHistoryEntryToJson)
          .toList(growable: false),
    };
  }
}

Map<String, dynamic> _taskHistoryEntryToJson(EngineTaskHistoryEntry entry) {
  return <String, dynamic>{
    'task_id': entry.taskId,
    'status': entry.status,
    'code': entry.code,
    'message': sanitizeSensitiveText(entry.message),
    'cancelled': entry.cancelled,
    'cooperative_cancel': entry.cooperativeCancel,
    'started_at': entry.startedAt?.toIso8601String(),
    'completed_at': entry.completedAt?.toIso8601String(),
    'action': entry.action,
    'workflow_id': entry.workflowId,
    'operation_id': entry.operationId,
    'client_operation_id': entry.clientOperationId,
    'idempotency_key': entry.idempotencyKey,
  };
}

class AgentAccessService {
  AgentAccessService(this.ref);

  final Ref ref;

  /// Every allow/deny decision, plus session and audit state. Extracted by
  /// T-3.5.3 so the security boundary can be tested without binding a socket.
  late final AgentAccessAuthorization authorization = ref.read(
    agentAccessAuthorizationProvider,
  );
  HttpServer? _server;
  String? _serverError;
  bool _initialized = false;
  final Map<String, McpSessionState> _mcpSessions = <String, McpSessionState>{};

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await _syncServerState();
  }

  Future<void> dispose() async {
    final server = _server;
    _server = null;
    _mcpSessions.clear();
    await server?.close(force: true);
  }

  Future<AgentAccessStatusSnapshot> readStatus() async {
    final preferences = await ref.read(appPreferencesRepositoryProvider).read();
    final recentActions = await ref
        .read(agentAuditRepositoryProvider)
        .listRecent(limit: 12);
    List<EngineTaskHistoryEntry> runningTasks =
        const <EngineTaskHistoryEntry>[];
    List<EngineTaskHistoryEntry> recentTaskResults =
        const <EngineTaskHistoryEntry>[];
    final historyResult = await ref
        .read(sshServiceProvider)
        .getRecentTaskHistory(limit: 25);
    final history = switch (historyResult) {
      Ok<List<EngineTaskHistoryEntry>>(:final value) => value,
      Err<List<EngineTaskHistoryEntry>>() => const <EngineTaskHistoryEntry>[],
    };
    final appHistory = history
        .where((entry) => entry.workflowId == 'app')
        .toList(growable: false);
    runningTasks = appHistory
        .where(
          (entry) =>
              entry.completedAt == null &&
              entry.status != 'success' &&
              entry.status != 'error',
        )
        .take(8)
        .toList(growable: false);
    recentTaskResults = appHistory
        .where((entry) => entry.completedAt != null)
        .take(8)
        .toList(growable: false);
    return AgentAccessStatusSnapshot(
      enabled: preferences.agentAccessEnabled,
      permissionMode: preferences.agentAccessPermissionMode,
      serverRunning: _server != null,
      port: resolvedDeployDashAgentControlPort,
      sessionToken: preferences.agentSessionToken,
      sessionExpiresAt: preferences.agentSessionExpiresAt,
      serverError: _serverError,
      recentActions: recentActions,
      runningTasks: runningTasks,
      recentTaskResults: recentTaskResults,
    );
  }

  Future<void> setEnabled(bool enabled) async {
    await authorization.setEnabled(enabled);
    await _syncServerState();
    await _audit(
      toolName: 'agent_access.set_enabled',
      accessLevel: 'local-ui',
      status: 'success',
      summary: enabled
          ? 'Enabled Agent Access local control server.'
          : 'Disabled Agent Access local control server.',
      details: <String, dynamic>{'enabled': enabled},
    );
  }

  Future<void> setPermissionMode(String mode) async {
    final normalized = await authorization.setPermissionMode(mode);
    await _syncServerState();
    await _audit(
      toolName: 'agent_access.set_permission_mode',
      accessLevel: 'local-ui',
      status: 'success',
      summary: 'Set Agent Access permission mode to $normalized.',
      details: <String, dynamic>{'permission_mode': normalized},
    );
  }

  // coverage-gate: agent_session_lifecycle
  Future<String> issueSession({
    Duration duration = const Duration(hours: 1),
  }) async {
    final issued = await authorization.issueSession(duration: duration);
    final token = issued.token;
    final expiresAt = issued.expiresAt;
    await _syncServerState();
    await _audit(
      toolName: 'agent_access.issue_session',
      accessLevel: 'local-ui',
      status: 'success',
      summary: 'Issued redeploy-capable agent session.',
      details: <String, dynamic>{'expires_at': expiresAt.toIso8601String()},
    );
    return token;
  }

  Future<void> revokeSession() async {
    await authorization.revokeSession();
    await _syncServerState();
    await _audit(
      toolName: 'agent_access.revoke_session',
      accessLevel: 'local-ui',
      status: 'success',
      summary: 'Revoked active agent session.',
    );
  }

  Future<void> _syncServerState() async {
    await authorization.clearEnabledOnFirstLaunch();
    final preferences = await authorization.readPreferences();
    if (!preferences.agentAccessEnabled) {
      final server = _server;
      _server = null;
      _serverError = null;
      _mcpSessions.clear();
      await server?.close(force: true);
      return;
    }
    if (_server != null) {
      return;
    }
    try {
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        resolvedDeployDashAgentControlPort,
        shared: true,
      );
      _server = server;
      _serverError = null;
      unawaited(_serveRequests(server));
    } catch (error) {
      _serverError = 'Could not bind Agent Access server: $error';
    }
  }

  // end coverage-gate

  Future<Project> _requireProject(String projectId) async {
    final project = await _findProject(projectId);
    if (project == null) {
      throw StateError('Unknown web app/project id: $projectId');
    }
    return project;
  }

  Future<Project?> _findProject(String projectId) async {
    final projects = await ref.read(projectRepositoryProvider).listProjects();
    for (final project in projects) {
      if (project.id == projectId) {
        return project;
      }
    }
    return null;
  }

  Future<Server?> _findServer(String serverId) async {
    final servers = await ref.read(serverRepositoryProvider).listServers();
    for (final server in servers) {
      if (server.id == serverId) {
        return server;
      }
    }
    return null;
  }

  Future<void> _audit({
    required String toolName,
    required String accessLevel,
    required String status,
    required String summary,
    Map<String, dynamic>? details,
  }) {
    return authorization.record(
      toolName: toolName,
      accessLevel: accessLevel,
      status: status,
      summary: summary,
      details: details,
    );
  }

  int? _intOrNull(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString().trim());
  }

  Future<Map<String, dynamic>?> _buildConnectionPayload(Server server) {
    return ref.read(serverConnectionPayloadResolverProvider)(server);
  }

  Map<String, dynamic> _projectConfig(Project project) {
    return <String, dynamic>{
      'project_id': project.id,
      'web_app_id': project.id,
      'server_id': project.serverId,
      'name': project.name,
      'primary_hostname': project.primaryDomain,
      'hostname_behavior': project.domainRoutingMode,
      'repository_full_name': project.repositoryFullName,
      'branch': project.deployBranch,
      'port': project.appPort,
      'runtime': railpackRuntimeSelectionId(
        railpackProvider: project.railpackProvider,
        railpackBuildCommand: project.railpackBuildCommand,
        railpackRunCommand: project.railpackRunCommand,
      ),
      'build_command': project.railpackBuildCommand,
      'run_command': project.railpackRunCommand,
      'app_subdirectory': project.appSubdirectory,
      'active': project.isActive,
    };
  }

  static final RegExp _branchPattern = RegExp(r'^[A-Za-z0-9._/-]+$');

  bool _isValidDomain(String value) {
    final candidate = value.trim().toLowerCase();
    if (candidate.isEmpty || candidate == 'not configured') {
      return false;
    }
    final fqdn = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])$',
    );
    return fqdn.hasMatch(candidate);
  }

  bool _isValidBranch(String value) {
    final candidate = value.trim();
    if (candidate.isEmpty) {
      return false;
    }
    return _branchPattern.hasMatch(candidate);
  }

  String? _runtimeIdToProvider(String? runtimeId) {
    final normalized = runtimeId?.trim().toLowerCase();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized == railpackAutoDetectRuntimeId) {
      return null;
    }
    return normalizeRailpackProvider(normalized);
  }
}

final agentAccessServiceProvider = Provider<AgentAccessService>((ref) {
  final service = AgentAccessService(ref);
  ref.onDispose(service.dispose);
  return service;
});
