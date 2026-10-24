/// Harness for the Agent Access MCP endpoint tests.
///
/// Extracted by T-3.6.2 from `agent_access_service_test.dart` (3,909 lines).
/// T-3.5.3 split the production service into transport, protocol,
/// authorization and the tool handlers; this splits its tests the same way,
/// which is what the task asks for and the reason it had to come second.
///
/// Everything the original imported is re-exported, so each test file needs
/// one import. `dart:async` is exported `hide AsyncError`, which Riverpod
/// also defines.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ui/data/local/agent_audit_repository.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_deployment_history_repository.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/data/local/github_secret_repository.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/server_repository.dart';
import 'package:ui/data/local/terminal_log_repository.dart';
import 'package:ui/models/result.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/server_provider.dart' show sshServiceProvider;
import 'package:ui/providers/agent_access/authorization.dart';
import 'package:ui/providers/agent_access_service.dart';
import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/services/sensitive_data_sanitizer.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'dart:async' hide AsyncError;
export 'dart:convert';
export 'dart:io';
export 'package:ui/data/local/agent_audit_repository.dart';
export 'package:ui/data/local/app_database.dart';
export 'package:ui/data/local/app_deployment_history_repository.dart';
export 'package:ui/data/local/app_preferences_repository.dart';
export 'package:ui/data/local/github_secret_repository.dart';
export 'package:ui/data/local/project_repository.dart';
export 'package:ui/data/local/server_repository.dart';
export 'package:ui/data/local/terminal_log_repository.dart';
export 'package:ui/models/result.dart';
export 'package:ui/models/deploy_failure_evidence.dart';
export 'package:ui/providers/github_integration_provider.dart';
export 'package:ui/providers/server_provider.dart' show sshServiceProvider;
export 'package:ui/providers/agent_access/authorization.dart';
export 'package:ui/providers/agent_access/protocol.dart';
export 'package:ui/providers/agent_access_service.dart';
export 'package:ui/services/concurrency_engine.dart';
export 'package:ui/services/sensitive_data_sanitizer.dart';
export 'package:ui/services/ssh_service.dart';
export 'package:drift/native.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';
export '../../../_support/sqlite_test_harness.dart';

class FakeGitHubSecretRepository implements GitHubSecretRepository {
  FakeGitHubSecretRepository({this.authToken});

  String? authToken;

  @override
  Future<void> clearAuthToken() async {
    authToken = null;
  }

  @override
  Future<void> deleteDeployKey(String repositoryFullName) async {}

  @override
  Future<String?> readAuthToken() async => authToken;

  @override
  Future<GitHubDeployKeyRecord?> readDeployKey(
    String repositoryFullName,
  ) async {
    return null;
  }

  @override
  Future<void> saveAuthToken(String accessToken) async {
    authToken = accessToken;
  }

  @override
  Future<void> saveDeployKey({
    required String repositoryFullName,
    required String publicKey,
    required String privateKey,
  }) async {}
}

class FakeGitHubAuthGateway implements GitHubAuthGateway {
  FakeGitHubAuthGateway({this.fetchRepositoriesError});

  final Object? fetchRepositoriesError;

  @override
  Stream<Uri> get callbackLinks => const Stream<Uri>.empty();

  @override
  Future<String> exchangeCodeForToken({
    required String code,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) {
    throw UnsupportedError('Not used in tests.');
  }

  @override
  Future<List<String>> fetchBranches({
    required String accessToken,
    required String repositoryFullName,
  }) {
    throw UnsupportedError('Not used directly in tests.');
  }

  @override
  Future<List<GitHubRepository>> fetchRepositories({
    required String accessToken,
  }) async {
    if (fetchRepositoriesError != null) {
      throw fetchRepositoriesError!;
    }
    return const <GitHubRepository>[
      GitHubRepository(name: 'blog', fullName: 'me/blog', isPrivate: false),
      GitHubRepository(name: 'api', fullName: 'me/api', isPrivate: true),
    ];
  }

  @override
  Future<Uri?> getInitialCallbackLink() async => null;

  @override
  Future<bool> openAuthorizationUrl(Uri authorizeUrl) async => true;

  @override
  Future<void> registerDeployKey({
    required String accessToken,
    required String repositoryFullName,
    required String publicKey,
  }) async {}
}

class NoopTaskClient implements EngineTaskClient {
  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) =>
      '{"status":"success","result":{"status":"success"}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","done":true,"events":[]}';

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';
}

class RunWorkflowCall {
  const RunWorkflowCall({
    required this.workflowId,
    required this.operationId,
    this.connection,
    this.params,
  });

  final String workflowId;
  final String operationId;
  final Map<String, dynamic>? connection;
  final Map<String, dynamic>? params;
}

class FakeSSHService extends SSHService {
  FakeSSHService() : super(taskClient: NoopTaskClient());

  final List<RunWorkflowCall> runWorkflowCalls = <RunWorkflowCall>[];
  Map<String, Map<String, dynamic>> postgresResponses =
      <String, Map<String, dynamic>>{};
  List<EngineTaskHistoryEntry> recentHistory = <EngineTaskHistoryEntry>[];
  Map<int, Map<String, dynamic>> eventPayloads = <int, Map<String, dynamic>>{};
  Map<int, Map<String, dynamic>> resultPayloads = <int, Map<String, dynamic>>{};
  OperationConflictEvaluation conflictEvaluation =
      const OperationConflictEvaluation(
        isBlocked: false,
        message: 'No conflict.',
      );
  Map<String, dynamic>? lastConflictParams;
  Object? historyError;
  Object? taskEventsError;
  Object? taskResultError;
  bool cancelReturnValue = true;
  // Typed failures, not wrapped Objects: `_agentFailureMessage` reads an
  // EngineFailure's `msg` and falls back to toString() for anything else, and
  // only a real EngineFailure exercises the first branch.
  AppFailure? historyFailure;
  AppFailure? historyEntryFailure;
  AppFailure? cancelFailure;
  Object? overviewThrows;
  Map<String, dynamic> overviewResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Overview ready.',
    'metrics': <String, dynamic>{'cpu_percent': 12},
  };
  Object? overviewError;
  Map<String, dynamic> runtimeResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Runtime logs ready.',
    'log_tail_lines': 2,
  };
  Object? runtimeError;
  List<Map<String, dynamic>> runtimeEvents = const <Map<String, dynamic>>[
    <String, dynamic>{'message': 'line one'},
    <String, dynamic>{'message': 'line two'},
  ];

  @override
  Future<Result<bool>> cancelTask(int taskId) async {
    if (cancelFailure != null) {
      return Err<bool>(cancelFailure!);
    }
    return Ok<bool>(cancelReturnValue);
  }

  @override
  OperationConflictEvaluation evaluateWorkflowConflict({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    bool serializePerHost = true,
  }) {
    lastConflictParams = params;
    return conflictEvaluation;
  }

  @override
  Future<Result<EngineTaskHistoryEntry?>> getTaskHistoryEntry(
    int taskId, {
    int searchLimit = 200,
  }) async {
    if (historyEntryFailure != null) {
      return Err<EngineTaskHistoryEntry?>(historyEntryFailure!);
    }
    for (final entry in recentHistory) {
      if (entry.taskId == taskId) {
        return Ok<EngineTaskHistoryEntry?>(entry);
      }
    }
    return const Ok<EngineTaskHistoryEntry?>(null);
  }

  @override
  Future<Result<Map<String, dynamic>>> getTaskResultEnvelope(
    int taskId, {
    bool sanitizeForExposure = false,
  }) async {
    if (taskResultError != null) {
      return Err<Map<String, dynamic>>(UnexpectedFailure(taskResultError!));
    }
    final payload =
        resultPayloads[taskId] ??
        <String, dynamic>{'status': 'success', 'result': <String, dynamic>{}};
    if (!sanitizeForExposure) {
      return Ok<Map<String, dynamic>>(payload);
    }
    return Ok<Map<String, dynamic>>(sanitizeSensitivePayloadMap(payload));
  }

  @override
  Future<Result<Map<String, dynamic>>> pollTaskEventsEnvelope(
    int taskId, {
    int maxEvents = 100,
    bool sanitizeForExposure = false,
  }) async {
    if (taskEventsError != null) {
      return Err<Map<String, dynamic>>(UnexpectedFailure(taskEventsError!));
    }
    final payload =
        eventPayloads[taskId] ??
        <String, dynamic>{
          'status': 'success',
          'done': true,
          'events': <dynamic>[],
        };
    if (!sanitizeForExposure) {
      return Ok<Map<String, dynamic>>(payload);
    }
    return Ok<Map<String, dynamic>>(sanitizeSensitivePayloadMap(payload));
  }

  @override
  Future<Result<List<EngineTaskHistoryEntry>>> getRecentTaskHistory({
    int limit = 50,
  }) async {
    if (historyFailure != null) {
      return Err<List<EngineTaskHistoryEntry>>(historyFailure!);
    }
    if (historyError != null) {
      return Err<List<EngineTaskHistoryEntry>>(
        UnexpectedFailure(historyError!),
      );
    }
    return Ok<List<EngineTaskHistoryEntry>>(
      recentHistory.take(limit).toList(growable: false),
    );
  }

  @override
  Future<Result<Map<String, dynamic>>> runWorkflow({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    runWorkflowCalls.add(
      RunWorkflowCall(
        workflowId: workflowId,
        operationId: operationId,
        connection: connection,
        params: params,
      ),
    );
    if (workflowId == 'server' && operationId == 'overview_metrics') {
      if (overviewThrows != null) {
        throw overviewThrows!;
      }
      if (overviewError != null) {
        return Err<Map<String, dynamic>>(UnexpectedFailure(overviewError!));
      }
      return Ok<Map<String, dynamic>>(overviewResponse);
    }
    if (workflowId == 'app' && operationId == 'runtime_logs') {
      if (runtimeError != null) {
        return Err<Map<String, dynamic>>(UnexpectedFailure(runtimeError!));
      }
      for (final event in runtimeEvents) {
        onEvent?.call(event);
      }
      return Ok<Map<String, dynamic>>(runtimeResponse);
    }
    if (workflowId == 'postgres') {
      return Ok<Map<String, dynamic>>(
        postgresResponses[operationId] ??
            <String, dynamic>{'status': 'success', 'operation_id': operationId},
      );
    }
    return const Ok<Map<String, dynamic>>(<String, dynamic>{
      'status': 'success',
    });
  }
}

class FakeGitHubIntegrationNotifier extends GitHubIntegrationNotifier {
  FakeGitHubIntegrationNotifier({
    this.branchError,
    this.deployTaskId = 701,
    this.callOnTaskStarted = true,
    this.deployThrows,
    this.throwAfterTaskStarted = false,
    this.finalDeployStatus = GitHubDeployStatus.success,
    this.finalStatusMessage = 'Deploy complete.',
    this.finalFailureEvidence,
    this.hangsForever = false,
  });

  final Object? branchError;
  final int deployTaskId;
  final bool callOnTaskStarted;
  final Object? deployThrows;
  final bool throwAfterTaskStarted;
  final GitHubDeployStatus finalDeployStatus;
  final String finalStatusMessage;
  final DeployFailureEvidence? finalFailureEvidence;

  /// Never returns and never reports a task id.
  ///
  /// A real deploy that is merely slow, rather than one that failed. A
  /// Completer rather than a Timer so the pending future does not leave the
  /// test binding complaining about an outstanding timer.
  final bool hangsForever;

  String? lastRepositoryFullName;
  String? lastPrimaryDomain;
  String? lastDomainRoutingMode;
  String? lastBranch;
  int? lastPort;
  String? lastRailpackBuildCommand;
  String? lastRailpackRunCommand;
  String? lastRailpackProvider;
  String? lastAppSubdirectory;
  Server? lastSelectedServerOverride;
  Project? lastSelectedProjectOverride;
  String? lastActorLabel;

  @override
  GitHubIntegrationState build() => const GitHubIntegrationState(
    connectStatus: GitHubConnectStatus.connected,
    deployStatus: GitHubDeployStatus.idle,
    statusMessage: 'Ready.',
    repositories: <GitHubRepository>[
      GitHubRepository(name: 'blog', fullName: 'me/blog', isPrivate: false),
    ],
    authToken: 'token-123',
  );

  @override
  Future<void> deploySelectedRepository({
    required String primaryDomain,
    required String branch,
    required int appPort,
    String? repositoryFullName,
    String? domainRoutingMode,
    String? railpackBuildCommand,
    String? railpackRunCommand,
    String? railpackProvider,
    String? appSubdirectory,
    String? repositoryHostKeyPolicy,
    String? acceptedRepositoryHostKeyFingerprint,
    Server? selectedServerOverride,
    Project? selectedProjectOverride,
    String? actorLabel,
    void Function(int taskId, String phase)? onTaskStarted,
  }) async {
    lastRepositoryFullName = repositoryFullName;
    lastPrimaryDomain = primaryDomain;
    lastDomainRoutingMode = domainRoutingMode;
    lastBranch = branch;
    lastPort = appPort;
    lastRailpackBuildCommand = railpackBuildCommand;
    lastRailpackRunCommand = railpackRunCommand;
    lastRailpackProvider = railpackProvider;
    lastAppSubdirectory = appSubdirectory;
    lastSelectedServerOverride = selectedServerOverride;
    lastSelectedProjectOverride = selectedProjectOverride;
    lastActorLabel = actorLabel;
    if (deployThrows != null) {
      throw deployThrows!;
    }
    if (hangsForever) {
      await Completer<void>().future;
    }
    if (callOnTaskStarted) {
      onTaskStarted?.call(deployTaskId, 'prepare_key');
      onTaskStarted?.call(deployTaskId, 'run');
    }
    if (throwAfterTaskStarted) {
      throw StateError('deploy crashed after task start');
    }
    final scopedProjectId = selectedProjectOverride?.id;
    final scopedState = scopedProjectId == null
        ? null
        : state
              .deployStateForProject(scopedProjectId)
              .copyWith(
                deployStatus: finalDeployStatus,
                statusMessage: finalStatusMessage,
                deployTimeline: const <String>['queued', 'running', 'done'],
                failureEvidence: finalFailureEvidence,
                clearFailureEvidence: finalFailureEvidence == null,
              );
    state = state.copyWith(
      deployStatus: finalDeployStatus,
      statusMessage: finalStatusMessage,
      deployTimeline: const <String>['queued', 'running', 'done'],
      failureEvidence: finalFailureEvidence,
      clearFailureEvidence: finalFailureEvidence == null,
      projectDeployStates: scopedProjectId == null
          ? null
          : <String, GitHubProjectDeployState>{
              ...state.projectDeployStates,
              scopedProjectId: scopedState!,
            },
    );
  }

  @override
  Future<List<String>> listRepositoryBranches(String repositoryFullName) async {
    if (branchError != null) {
      throw branchError!;
    }
    return const <String>['main', 'staging'];
  }
}

class RealHttpOverrides extends HttpOverrides {
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

class JsonResponse {
  const JsonResponse(this.statusCode, this.body, {this.headers = const {}});

  final int statusCode;
  final Map<String, dynamic> body;
  final Map<String, String> headers;
}

const testMcpSessionIdHeader = 'mcp-session-id';

class EventStreamProbe {
  const EventStreamProbe(
    this.statusCode,
    this.firstChunk, {
    this.headers = const {},
  });

  final int statusCode;
  final String firstChunk;
  final Map<String, String> headers;
}

class AgentAccessHarness {
  AgentAccessHarness({
    required this.port,
    required this.database,
    required this.container,
    required this.service,
    required this.preferencesRepository,
    required this.serverRepository,
    required this.projectRepository,
    required this.auditRepository,
    required this.deploymentHistoryRepository,
    required this.terminalLogRepository,
    required this.sshService,
    required this.secretRepository,
    required this.notifier,
  });

  final int port;
  final AppDatabase database;
  final ProviderContainer container;
  final AgentAccessService service;
  final AppPreferencesRepository preferencesRepository;
  final ServerRepository serverRepository;
  final ProjectRepository projectRepository;
  final AgentAuditRepository auditRepository;
  final AppDeploymentHistoryRepository deploymentHistoryRepository;
  final TerminalLogRepository terminalLogRepository;
  final FakeSSHService sshService;
  final FakeGitHubSecretRepository secretRepository;
  final FakeGitHubIntegrationNotifier notifier;

  Server? server;
  Project? project;
  String? _mcpSessionId;

  Future<void> dispose() async {
    await service.dispose();
    if (deployDashAgentControlPortOverrideForTests == port) {
      deployDashAgentControlPortOverrideForTests = null;
    }
    container.dispose();
    await database.close();
  }

  Future<void> seedDefaultData({bool validServer = true}) async {
    server = await serverRepository.createServer(
      draft: ServerDraft(
        name: 'Prod-01',
        host: '203.0.113.10',
        port: 22,
        sshUser: 'root',
        authMethod: validServer
            ? ServerAuthMethod.password
            : ServerAuthMethod.sshKey,
        sshPassword: validServer ? 'secret' : null,
        keyPath: validServer ? null : null,
      ),
      specs: const ServerSpecs(osName: 'Ubuntu 24.04', cpuArch: 'x86_64'),
    );
    await serverRepository.updateServerServices(
      serverId: server!.id,
      enableDatabases: true,
      enableEmailAccounts: false,
      enableDomains: false,
    );
    await serverRepository.updateServerPostgresConfig(
      serverId: server!.id,
      config: const ServerPostgresConfig(
        postgresVersion: '17',
        superuserPassword: 'pg-secret',
      ),
    );
    server = (await serverRepository.listServers()).singleWhere(
      (saved) => saved.id == server!.id,
    );

    project = Project(
      id: 'project-blog',
      serverId: server!.id,
      name: 'Blog',
      type: 'Web app',
      gitUrl: 'https://github.com/me/blog',
      primaryDomain: 'blog.example.com',
      domainRoutingMode: 'single_host',
      repositoryFullName: 'me/blog',
      appSubdirectory: 'apps/web',
      deployBranch: 'main',
      appPort: 3000,
      railpackBuildCommand: 'npm run build',
      railpackRunCommand: 'npm run start',
      railpackProvider: 'node',
      isActive: true,
    );
    await projectRepository.createProject(project!);
    await projectRepository.createProject(
      const Project(
        id: 'project-worker',
        name: 'Worker',
        type: 'Worker',
        gitUrl: 'https://github.com/me/worker',
        primaryDomain: 'workers.example.com',
      ),
    );
    await deploymentHistoryRepository.append(
      projectId: project!.id,
      status: 'success',
      deployedAt: DateTime.utc(2026, 4, 13, 10),
      durationSeconds: 42,
      actor: 'agent-mcp',
      branch: 'main',
      commit: 'abc1234',
    );
    await terminalLogRepository.appendLog(
      message: 'Deploy started',
      renderedLine: '[deploy] Deploy started',
      source: 'engine',
      taskType: 'app_deploy',
      projectId: project!.id,
      createdAt: DateTime.utc(2026, 4, 13, 10, 0, 0),
    );
    await terminalLogRepository.appendLog(
      message: 'Deploy finished',
      renderedLine: '[deploy] Deploy finished',
      source: 'engine',
      taskType: 'app_deploy',
      projectId: project!.id,
      createdAt: DateTime.utc(2026, 4, 13, 10, 0, 1),
    );
    // Another project's deploy line. It must never appear in this project's
    // logs: the tool used to fetch every app_deploy row and label the lot
    // with the requested web_app_id.
    await terminalLogRepository.appendLog(
      message: 'Other project deploy',
      renderedLine: '[deploy] Other project deploy',
      source: 'engine',
      taskType: 'app_deploy',
      projectId: 'project-worker',
      createdAt: DateTime.utc(2026, 4, 13, 10, 0, 2),
    );
    await auditRepository.append(
      toolName: 'seed.action',
      accessLevel: 'read_only',
      status: 'success',
      summary: 'Seeded audit entry.',
      details: const <String, dynamic>{'seeded': true},
    );
    sshService.recentHistory = <EngineTaskHistoryEntry>[
      EngineTaskHistoryEntry(
        taskId: 701,
        status: 'running',
        code: null,
        message: 'Deploy in progress',
        cancelled: false,
        cooperativeCancel: false,
        startedAt: DateTime.utc(2026, 4, 13, 10, 1),
        completedAt: null,
        action: 'run_workflow',
        workflowId: 'app',
        operationId: 'run',
        clientOperationId: 'op-701',
        idempotencyKey: 'idem-701',
      ),
      EngineTaskHistoryEntry(
        taskId: 700,
        status: 'success',
        code: null,
        message: 'Deploy complete',
        cancelled: false,
        cooperativeCancel: false,
        startedAt: DateTime.utc(2026, 4, 13, 9, 0),
        completedAt: DateTime.utc(2026, 4, 13, 9, 2),
        action: 'run_workflow',
        workflowId: 'app',
        operationId: 'run',
        clientOperationId: 'op-700',
        idempotencyKey: 'idem-700',
      ),
      const EngineTaskHistoryEntry(
        taskId: 699,
        status: 'success',
        code: null,
        message: 'Ignored non-app task',
        cancelled: false,
        cooperativeCancel: false,
        startedAt: null,
        completedAt: null,
        action: 'run_workflow',
        workflowId: 'postgres',
        operationId: 'service_enable',
        clientOperationId: 'op-699',
        idempotencyKey: 'idem-699',
      ),
    ];
    sshService.eventPayloads[701] = <String, dynamic>{
      'status': 'success',
      'done': false,
      'events': <Map<String, dynamic>>[
        <String, dynamic>{'type': 'log', 'message': 'one'},
      ],
    };
    sshService.resultPayloads[701] = <String, dynamic>{
      'status': 'success',
      'result': <String, dynamic>{'status': 'success', 'msg': 'done'},
    };
  }

  Future<void> enableAgentAccess({
    String permissionMode = agentAccessPermissionReadOnly,
    bool issueSession = false,
  }) async {
    await service.setEnabled(true);
    await service.setPermissionMode(permissionMode);
    if (issueSession) {
      await service.issueSession(duration: const Duration(hours: 1));
    }
  }

  Future<JsonResponse> request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? bearerToken,
    Map<String, String>? query,
  }) async {
    try {
      final toolRequest = _legacyRouteToMcpRequest(
        method,
        path,
        body: body,
        query: query,
      );
      return await mcpRequest(
        toolRequest.$1,
        arguments: toolRequest.$2,
        bearerToken: bearerToken,
      );
    } on StateError {
      return rawRequest(
        method,
        '/$path',
        bearerToken: bearerToken,
        query: query,
      );
    }
  }

  Future<JsonResponse?> ensureMcpSession({String? bearerToken}) async {
    if (_mcpSessionId != null) {
      return null;
    }
    final response = await rawRequest(
      'POST',
      deployDashAgentMcpPath,
      body: jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, dynamic>{
          'protocolVersion': '2025-03-26',
          'capabilities': <String, dynamic>{},
          'clientInfo': <String, dynamic>{
            'name': 'deploydash-test',
            'version': '1.0.0',
          },
        },
      }),
      bearerToken: bearerToken,
    );
    final sessionId = response.headers[testMcpSessionIdHeader];
    if (response.statusCode != HttpStatus.ok || sessionId == null) {
      return response;
    }
    _mcpSessionId = sessionId;
    return null;
  }

  Future<JsonResponse> mcpRequest(
    String toolName, {
    Map<String, dynamic>? arguments,
    String? bearerToken,
  }) async {
    final initFailure = await ensureMcpSession(bearerToken: bearerToken);
    if (initFailure != null) {
      return initFailure;
    }
    final response = await rawRequest(
      'POST',
      deployDashAgentMcpPath,
      body: jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': <String, dynamic>{
          'name': toolName,
          'arguments': arguments ?? const <String, dynamic>{},
        },
      }),
      bearerToken: bearerToken,
      headers: <String, String>{testMcpSessionIdHeader: _mcpSessionId!},
    );
    if (response.body['result'] is! Map) {
      return response;
    }
    final result = (response.body['result'] as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );
    final meta =
        (result['_meta'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), value),
        ) ??
        <String, dynamic>{};
    final structured =
        (result['structuredContent'] as Map?)?.map(
          (key, value) => MapEntry(key.toString(), value),
        ) ??
        <String, dynamic>{};
    return JsonResponse(
      (meta['httpStatus'] as num?)?.toInt() ?? response.statusCode,
      structured,
      headers: response.headers,
    );
  }

  (String, Map<String, dynamic>) _legacyRouteToMcpRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) {
    switch ('$method $path') {
      case 'GET status':
        return ('deploydash_status', <String, dynamic>{});
      case 'GET servers':
        return ('deploydash_list_servers', <String, dynamic>{});
      case 'GET projects':
        return ('deploydash_list_projects', <String, dynamic>{});
      case 'GET web-apps':
        return ('deploydash_list_web_apps', <String, dynamic>{});
      case 'GET audit':
        return (
          'deploydash_read_audit',
          <String, dynamic>{
            if (query?['limit'] != null) 'limit': int.parse(query!['limit']!),
          },
        );
      case 'GET github/repositories':
        return ('deploydash_list_github_repositories', <String, dynamic>{});
      case 'GET github/repository-branches':
        return (
          'deploydash_list_repository_branches',
          <String, dynamic>{
            'repository_full_name': query?['repository_full_name'],
          },
        );
      case 'GET tasks/history':
        return (
          'deploydash_get_task_history',
          <String, dynamic>{
            if (query?['limit'] != null) 'limit': int.parse(query!['limit']!),
          },
        );
      case 'POST tasks/evaluate-conflict':
        return ('deploydash_evaluate_conflict', body ?? <String, dynamic>{});
    }

    final segments = path.split('/');
    if (segments.length == 2 && segments[0] == 'servers' && method == 'GET') {
      return (
        'deploydash_get_server_overview',
        <String, dynamic>{'server_id': segments[1]},
      );
    }
    if (segments.length == 2 && segments[0] == 'web-apps' && method == 'GET') {
      return (
        'deploydash_get_web_app_details',
        <String, dynamic>{'web_app_id': segments[1]},
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'web-apps' &&
        segments[2] == 'deploy-history' &&
        method == 'GET') {
      return (
        'deploydash_get_deploy_history',
        <String, dynamic>{
          'web_app_id': segments[1],
          if (query?['limit'] != null) 'limit': int.parse(query!['limit']!),
        },
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'web-apps' &&
        segments[2] == 'deploy-logs' &&
        method == 'GET') {
      return (
        'deploydash_get_deploy_logs',
        <String, dynamic>{
          'web_app_id': segments[1],
          if (query?['limit'] != null) 'limit': int.parse(query!['limit']!),
        },
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'web-apps' &&
        segments[2] == 'runtime-logs' &&
        method == 'GET') {
      return (
        'deploydash_get_runtime_logs',
        <String, dynamic>{
          'web_app_id': segments[1],
          'server_id': query?['server_id'],
          if (query?['tail_lines'] != null)
            'tail_lines': int.parse(query!['tail_lines']!),
        },
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'web-apps' &&
        segments[2] == 'prepare-redeploy' &&
        method == 'POST') {
      return (
        'deploydash_prepare_web_app_redeploy',
        <String, dynamic>{...?body, 'web_app_id': segments[1]},
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'web-apps' &&
        segments[2] == 'redeploy' &&
        method == 'POST') {
      return (
        'deploydash_redeploy_web_app',
        <String, dynamic>{...?body, 'web_app_id': segments[1]},
      );
    }
    if (segments.length == 2 && segments[0] == 'tasks' && method == 'GET') {
      return (
        'deploydash_get_task',
        <String, dynamic>{'task_id': int.tryParse(segments[1]) ?? segments[1]},
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'tasks' &&
        segments[2] == 'events' &&
        method == 'GET') {
      return (
        'deploydash_get_task_events',
        <String, dynamic>{
          'task_id': int.tryParse(segments[1]) ?? segments[1],
          if (query?['max_events'] != null)
            'max_events': int.parse(query!['max_events']!),
        },
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'tasks' &&
        segments[2] == 'result' &&
        method == 'GET') {
      return (
        'deploydash_get_task_result',
        <String, dynamic>{'task_id': int.tryParse(segments[1]) ?? segments[1]},
      );
    }
    if (segments.length == 3 &&
        segments[0] == 'tasks' &&
        segments[2] == 'cancel' &&
        method == 'POST') {
      return (
        'deploydash_cancel_task',
        <String, dynamic>{'task_id': int.tryParse(segments[1]) ?? segments[1]},
      );
    }
    if (segments.length == 4 &&
        segments[0] == 'projects' &&
        segments[2] == 'postgres' &&
        method == 'GET') {
      switch (segments[3]) {
        case 'databases':
          return (
            'deploydash_list_postgres_databases',
            <String, dynamic>{'project_id': segments[1]},
          );
        case 'schemas':
          return (
            'deploydash_list_postgres_schemas',
            <String, dynamic>{
              'project_id': segments[1],
              'database_name': query?['database_name'],
            },
          );
        case 'tables':
          return (
            'deploydash_list_postgres_tables',
            <String, dynamic>{
              'project_id': segments[1],
              'database_name': query?['database_name'],
              if (query?['schema_name'] != null)
                'schema_name': query!['schema_name'],
            },
          );
        case 'table':
          return (
            'deploydash_describe_postgres_table',
            <String, dynamic>{
              'project_id': segments[1],
              'database_name': query?['database_name'],
              'table_name': query?['table_name'],
              if (query?['schema_name'] != null)
                'schema_name': query!['schema_name'],
            },
          );
      }
    }
    if (segments.length == 4 &&
        segments[0] == 'projects' &&
        segments[2] == 'postgres' &&
        method == 'POST') {
      switch (segments[3]) {
        case 'explain-query':
          return (
            'deploydash_explain_postgres_query',
            <String, dynamic>{'project_id': segments[1], ...?body},
          );
        case 'query':
          return (
            'deploydash_execute_postgres_readonly_query',
            <String, dynamic>{'project_id': segments[1], ...?body},
          );
      }
    }
    throw StateError('Unhandled Agent Access MCP route: $method $path');
  }

  /// Calls one MCP method over the real socket, reusing the negotiated session.
  ///
  /// `mcpRequest` above can only reach `tools/call`; every other method —
  /// ping, tools/list, resources/list, resources/read — had no route into the
  /// suite at all before T-3.5.3, which is why `_dispatchMcpMethod` was
  /// entirely uncovered.
  Future<JsonResponse> mcpMethod(
    String method, {
    Map<String, dynamic>? params,
    Object? id = 7,
    bool includeId = true,
    String? bearerToken,
  }) async {
    final initFailure = await ensureMcpSession(bearerToken: bearerToken);
    if (initFailure != null) {
      return initFailure;
    }
    return rawRequest(
      'POST',
      deployDashAgentMcpPath,
      body: jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        if (includeId) 'id': id,
        'method': method,
        'params': ?params,
      }),
      bearerToken: bearerToken,
      headers: <String, String>{testMcpSessionIdHeader: _mcpSessionId!},
    );
  }

  /// The negotiated session id, once [mcpMethod] or [request] has opened one.
  String? get mcpSessionId => _mcpSessionId;

  Future<JsonResponse> rawRequest(
    String method,
    String path, {
    String? body,
    String? bearerToken,
    Map<String, String>? query,
    Map<String, String>? headers,
  }) {
    return HttpOverrides.runZoned(
      () async {
        final client = HttpClient();
        try {
          final uri = Uri.http('127.0.0.1:$port', path, query);
          final request = await client.openUrl(method, uri);
          if (bearerToken != null) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer $bearerToken',
            );
          }
          for (final entry in (headers ?? const <String, String>{}).entries) {
            request.headers.set(entry.key, entry.value);
          }
          if (body != null) {
            request.headers.contentType = ContentType.json;
            request.write(body);
          }
          final response = await request.close();
          final text = await utf8.decodeStream(response);
          final payload = text.trim().isEmpty
              ? <String, dynamic>{}
              : (jsonDecode(text) as Map).map(
                  (key, value) => MapEntry(key.toString(), value),
                );
          final headersMap = <String, String>{};
          response.headers.forEach((name, values) {
            headersMap[name] = values.join(', ');
          });
          return JsonResponse(
            response.statusCode,
            payload,
            headers: headersMap,
          );
        } finally {
          client.close(force: true);
        }
      },
      createHttpClient: (context) =>
          RealHttpOverrides().createHttpClient(context),
    );
  }

  /// Collects everything an open event stream emits within [window].
  ///
  /// `openMcpEventStream` stops at the first chunk, so it can see the
  /// `: connected` preamble but never a keepalive. The keepalive timer is what
  /// holds the connection open through an idle period, so it needs its own
  /// observation.
  Future<List<String>> collectMcpEventStream(Duration window) {
    return HttpOverrides.runZoned(
      () async {
        final client = HttpClient();
        try {
          final uri = Uri.http('127.0.0.1:$port', deployDashAgentMcpPath);
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          final response = await request.close();
          final chunks = <String>[];
          final subscription = response
              .transform(utf8.decoder)
              .listen(chunks.add);
          await Future<void>.delayed(window);
          await subscription.cancel();
          return chunks;
        } finally {
          client.close(force: true);
        }
      },
      createHttpClient: (context) =>
          RealHttpOverrides().createHttpClient(context),
    );
  }

  Future<EventStreamProbe> openMcpEventStream({String? sessionId}) {
    return HttpOverrides.runZoned(
      () async {
        final client = HttpClient();
        try {
          final uri = Uri.http('127.0.0.1:$port', deployDashAgentMcpPath);
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
          if (sessionId != null) {
            request.headers.set(testMcpSessionIdHeader, sessionId);
          }
          final response = await request.close();
          final headersMap = <String, String>{};
          response.headers.forEach((name, values) {
            headersMap[name] = values.join(', ');
          });
          final completer = Completer<String>();
          late final StreamSubscription<String> subscription;
          subscription = response.transform(utf8.decoder).listen((chunk) {
            if (!completer.isCompleted) {
              completer.complete(chunk);
            }
          });
          final firstChunk = await completer.future.timeout(
            const Duration(seconds: 2),
          );
          await subscription.cancel();
          return EventStreamProbe(
            response.statusCode,
            firstChunk,
            headers: headersMap,
          );
        } finally {
          client.close(force: true);
        }
      },
      createHttpClient: (context) =>
          RealHttpOverrides().createHttpClient(context),
    );
  }
}

/// Each harness binds a real `HttpServer`, so these ports must be ones the
/// kernel will never hand out on its own.
///
/// The previous base, 47437, sat inside Linux's default ephemeral range
/// (`/proc/sys/net/ipv4/ip_local_port_range` is 32768-60999), so every bind
/// here raced any outgoing connection on the machine. That is why this file
/// failed intermittently and passed on a re-run: it depended on unrelated
/// network activity. Verified by occupying 47437-47460 and watching this file
/// fail on every test.
///
/// **Keep this block below 32768 and above 1024.** Moving it back into the
/// ephemeral range reintroduces the flake, and the failure looks like a
/// product bug rather than a port collision.
/// **Each test file must claim its own block.** `flutter test` runs files in
/// separate isolates, in parallel, so a single shared counter starting at the
/// same value in seven files is seven files fighting over the same ports.
/// That is what T-3.6.2's split turned up: nine failures whose symptom --
/// `permission_denied` where `session_required` was expected -- looked like a
/// product bug and was two harnesses answering each other's requests.
///
/// Call [claimAgentAccessTestPortBlock] first in `main()`.
int _nextAgentAccessTestPort = 21437;

/// Reserves this file's 40-port block, [index] counting from zero.
void claimAgentAccessTestPortBlock(int index) {
  _nextAgentAccessTestPort = 21437 + index * 40;
}

Future<AgentAccessHarness> createHarness({
  FakeGitHubAuthGateway? authGateway,
  FakeGitHubSecretRepository? secretRepository,
  FakeGitHubIntegrationNotifier? notifier,
  FakeSSHService? sshService,
}) async {
  final port = _nextAgentAccessTestPort++;
  deployDashAgentControlPortOverrideForTests = port;
  // `clearEnabledOnFirstLaunch` is guarded by a process-lifetime static: the
  // first `_syncServerState` of a process writes `agentAccessEnabled = false`
  // and every later one skips it. That made the FIRST harness in a process
  // the only one whose enable was defeated, so whichever group ran first
  // failed with `SocketException: Connection refused` -- invisible in a
  // full-file run, fatal for `--plain-name '<group>'`.
  //
  // Resetting alone is not enough, and makes it worse: it would defeat every
  // harness rather than one. The flag has to be *spent* the way a real app
  // launch spends it -- during startup, before the user enables anything --
  // which is what the `initialize()` below does. See T-3.6.2, which will run
  // this file's pieces independently for the first time.
  AgentAccessAuthorization.resetFirstLaunchClearForTests();
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final secrets =
      secretRepository ?? FakeGitHubSecretRepository(authToken: 'token-123');
  final gateway = authGateway ?? FakeGitHubAuthGateway();
  final fakeNotifier = notifier ?? FakeGitHubIntegrationNotifier();
  final fakeSsh = sshService ?? FakeSSHService();
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      gitHubSecretRepositoryProvider.overrideWithValue(secrets),
      gitHubAuthGatewayProvider.overrideWithValue(gateway),
      sshServiceProvider.overrideWithValue(fakeSsh),
      gitHubIntegrationProvider.overrideWith(() => fakeNotifier),
    ],
  );
  final harness = AgentAccessHarness(
    port: port,
    database: database,
    container: container,
    service: container.read(agentAccessServiceProvider),
    preferencesRepository: container.read(appPreferencesRepositoryProvider),
    serverRepository: container.read(serverRepositoryProvider),
    projectRepository: container.read(projectRepositoryProvider),
    auditRepository: container.read(agentAuditRepositoryProvider),
    deploymentHistoryRepository: container.read(
      appDeploymentHistoryRepositoryProvider,
    ),
    terminalLogRepository: container.read(terminalLogRepositoryProvider),
    sshService: fakeSsh,
    secretRepository: secrets,
    notifier: fakeNotifier,
  );
  await harness.service.initialize();
  return harness;
}
