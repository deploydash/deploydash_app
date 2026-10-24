/// Fakes and fixtures for the GitHub integration provider tests.
///
/// Extracted by T-3.6.2 from `github_integration_provider_test.dart`
/// (3,374 lines, 40 tests directly in `main`). The five files beside this one
/// follow the seams T-3.3.6 split the provider along: the API gateway, the
/// OAuth session, the deploy key dance, the deploy payload, and the failure
/// diagnostics.
///
/// Most of the fakes were declared **after** `main()` in the original, not
/// before it, which is where a preamble-only extraction loses them.
///
/// `testWithSqlite` was a closure inside `main` over `sqliteAvailable`; it is
/// a function here so all five files share one definition.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ui/data/local/github_secret_repository.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/protocol_link_ingress.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../_support/sqlite_test_harness.dart';

export 'dart:async' hide AsyncError;
export 'dart:convert';
export 'dart:io';
export 'package:ui/data/local/app_database.dart'
    show AppDatabase, appDatabaseProvider;
export 'package:ui/data/local/app_deployment_history_repository.dart';
export 'package:ui/data/local/app_environment_variable_repository.dart';
export 'package:ui/data/local/app_preferences_repository.dart';
export 'package:ui/data/local/app_release_repository.dart';
export 'package:ui/data/local/github_secret_repository.dart';
export 'package:ui/data/local/project_sqlite_database_repository.dart';
export 'package:ui/data/local/terminal_log_repository.dart';
export 'package:ui/models/app_public_health.dart';
export 'package:ui/providers/github_integration_provider.dart';
export 'package:ui/providers/project_provider.dart';
export 'package:ui/providers/server_list_provider.dart';
export 'package:ui/providers/server_provider.dart';
export 'package:ui/services/protocol_link_ingress.dart';
export 'package:ui/services/ssh_service.dart';
export 'package:drift/native.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';
export '../../../_support/sqlite_test_harness.dart';

const selectedServer = Server(
  id: 'server-1',
  name: 'Prod-01',
  host: '203.0.113.10',
  port: 22,
  sshUser: 'root',
  authMethod: ServerAuthMethod.password,
);

Future<Map<String, dynamic>?> selectedServerConnectionPayload(
  Server server,
) async {
  if (server.id != selectedServer.id) {
    return null;
  }
  return <String, dynamic>{
    'host': server.host,
    'port': server.port,
    'username': server.sshUser,
    'password': 'secret',
  };
}

const selectedProject = Project(
  id: 'project-blog',
  name: 'Blog',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'blog.example.com',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
);

const selectedProjectWithPreferredRepository = Project(
  id: 'project-blog',
  name: 'Blog',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'blog.example.com',
  repositoryFullName: 'me/worker-api',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
);

const selectedProjectNoSubdirectory = Project(
  id: 'project-root',
  name: 'Root App',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'root.example.com',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
);

const selectedProjectWithPythonProvider = Project(
  id: 'project-python',
  name: 'Python API',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'python.example.com',
  deployBranch: 'main',
  appPort: 8000,
  railpackBuildCommand: '',
  railpackRunCommand: '',
  railpackProvider: 'python',
  tlsChallengeMode: 'dns',
  tlsDnsProvider: 'cloudflare',
  tlsDnsCredentials: {'api_token': 'cloudflare-token'},
  railpackNodeMode: 'auto',
);

const selectedProjectWithPostgresEnv = Project(
  id: 'project-postgres',
  name: 'Postgres App',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'postgres.example.com',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
  injectPostgresEnv: true,
);

const selectedProjectWithSqliteStorage = Project(
  id: 'project-sqlite',
  name: 'SQLite App',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'sqlite.example.com',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
  sqliteStorageEnabled: true,
  sqliteVolumeName: 'deploydash_sqlite_project-sqlite',
  sqliteMountPath: '/var/lib/deploydash/sqlite',
  sqliteFileName: 'main.db',
);

class FakeGitHubSecretRepository implements GitHubSecretRepository {
  FakeGitHubSecretRepository({String? authToken}) : _token = authToken;

  String? _token;
  final Map<String, GitHubDeployKeyRecord> _keys = {};
  int deleteCalls = 0;

  @override
  Future<void> clearAuthToken() async {
    _token = null;
  }

  @override
  Future<String?> readAuthToken() async {
    return _token;
  }

  @override
  Future<GitHubDeployKeyRecord?> readDeployKey(
    String repositoryFullName,
  ) async {
    return _keys[repositoryFullName.trim()];
  }

  @override
  Future<void> deleteDeployKey(String repositoryFullName) async {
    deleteCalls += 1;
    _keys.remove(repositoryFullName.trim());
  }

  @override
  Future<void> saveAuthToken(String accessToken) async {
    _token = accessToken.trim();
  }

  @override
  Future<void> saveDeployKey({
    required String repositoryFullName,
    required String publicKey,
    required String privateKey,
  }) async {
    final repo = repositoryFullName.trim();
    _keys[repo] = GitHubDeployKeyRecord(
      repositoryFullName: repo,
      publicKey: publicKey.trim(),
      privateKey: privateKey.trim(),
    );
  }
}

class FakeHttpClientResponseSpec {
  const FakeHttpClientResponseSpec({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final Object body;
  final Map<String, String> headers;
}

class FakeHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  String? value(String name) {
    final values = _values[name.toLowerCase()];
    if (values == null || values.isEmpty) {
      return null;
    }
    return values.join(',');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest(this._response);

  final FakeHttpClientResponse _response;
  final FakeHttpHeaders _headers = FakeHttpHeaders();
  final StringBuffer _body = StringBuffer();
  ContentType? contentType;

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? obj) {
    _body.write(obj);
  }

  @override
  Future<HttpClientResponse> close() async {
    return _response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse(this.spec) : _headers = FakeHttpHeaders() {
    for (final entry in spec.headers.entries) {
      _headers.set(entry.key, entry.value);
    }
  }

  final FakeHttpClientResponseSpec spec;
  final FakeHttpHeaders _headers;

  @override
  int get statusCode => spec.statusCode;

  @override
  HttpHeaders get headers => _headers;

  @override
  bool get isRedirect => false;

  @override
  List<RedirectInfo> get redirects => const <RedirectInfo>[];

  @override
  int get contentLength => utf8.encode(jsonEncode(spec.body)).length;

  @override
  bool get persistentConnection => false;

  @override
  String get reasonPhrase => 'OK';

  @override
  List<Cookie> get cookies => const <Cookie>[];

  @override
  HttpConnectionInfo? get connectionInfo => null;

  @override
  X509Certificate? get certificate => null;

  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) {
    throw UnsupportedError('redirect not supported in tests');
  }

  @override
  Future<Socket> detachSocket() {
    throw UnsupportedError('detachSocket not supported in tests');
  }

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final stream = Stream<List<int>>.fromIterable(<List<int>>[
      utf8.encode(jsonEncode(spec.body)),
    ]);
    return stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient({required List<FakeHttpClientResponseSpec> responses})
    : _responses = List<FakeHttpClientResponseSpec>.from(responses);

  final List<FakeHttpClientResponseSpec> _responses;
  final List<Uri> requestedUrls = <Uri>[];
  final List<String?> authorizationHeaders = <String?>[];
  bool closed = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requestedUrls.add(url);
    if (_responses.isEmpty) {
      throw StateError('No fake responses remaining.');
    }
    final request = FakeHttpClientRequest(
      FakeHttpClientResponse(_responses.removeAt(0)),
    );
    unawaited(
      Future<void>.microtask(() {
        authorizationHeaders.add(
          request.headers.value(HttpHeaders.authorizationHeader),
        );
      }),
    );
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeGitHubAuthGateway implements GitHubAuthGateway {
  FakeGitHubAuthGateway({
    this.openAuthorizationUrlResult = true,
    this.exchangeCodeError,
  });

  final bool openAuthorizationUrlResult;
  final Object? exchangeCodeError;
  void Function()? onRegisterDeployKey;
  Uri? initialCallbackUri;

  @override
  Stream<Uri> get callbackLinks => const Stream<Uri>.empty();

  @override
  Future<Uri?> getInitialCallbackLink() async => initialCallbackUri;

  int registerCalls = 0;

  @override
  Future<String> exchangeCodeForToken({
    required String code,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    final error = exchangeCodeError;
    if (error != null) {
      throw error;
    }
    return 'token_$code';
  }

  @override
  Future<List<GitHubRepository>> fetchRepositories({
    required String accessToken,
  }) async {
    return const [
      GitHubRepository(
        name: 'my-blog',
        fullName: 'me/my-blog',
        isPrivate: false,
      ),
      GitHubRepository(
        name: 'worker-api',
        fullName: 'me/worker-api',
        isPrivate: true,
      ),
    ];
  }

  @override
  Future<bool> openAuthorizationUrl(Uri authorizeUrl) async {
    return openAuthorizationUrlResult;
  }

  @override
  Future<List<String>> fetchBranches({
    required String accessToken,
    required String repositoryFullName,
  }) async {
    return const ['main', 'staging'];
  }

  @override
  Future<void> registerDeployKey({
    required String accessToken,
    required String repositoryFullName,
    required String publicKey,
  }) async {
    registerCalls += 1;
    final callback = onRegisterDeployKey;
    onRegisterDeployKey = null;
    callback?.call();
  }
}

class NoopProtocolLinkIngress implements ProtocolLinkIngress {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();

  @override
  void dispose() {}
}

class FakeEngineTaskClient implements EngineTaskClient {
  FakeEngineTaskClient({
    this.failAppRun = false,
    this.appRunFailuresBeforeSuccess = 0,
    this.appRunFailureMessage = 'Web app deployment failed on server.',
    this.appRunFailureMessages,
    this.appRunFailureResults,
    this.appRunPollResponses,
    this.appRunSuccessResult,
    this.prepareKeyFailureMessage,
    this.prepareKeyFailureResult,
    this.prepareKeyMissingMaterial = false,
    this.throwAppRunResult = false,
  });

  int _nextTaskId = 1;
  int appPrepareCalls = 0;
  int appRunCalls = 0;
  final Map<int, Map<String, dynamic>> _payloads = {};
  final bool failAppRun;
  final int appRunFailuresBeforeSuccess;
  final String appRunFailureMessage;
  final List<String>? appRunFailureMessages;
  final List<Map<String, dynamic>>? appRunFailureResults;
  final List<Map<String, dynamic>>? appRunPollResponses;
  final Map<String, dynamic>? appRunSuccessResult;
  final String? prepareKeyFailureMessage;
  final Map<String, dynamic>? prepareKeyFailureResult;
  final bool prepareKeyMissingMaterial;
  final bool throwAppRunResult;
  void Function()? onPrepareKeyResult;
  void Function()? onAppRunResult;
  final Map<int, List<Map<String, dynamic>>> _taskPollResponses = {};
  final Map<int, int> _taskPollIndices = {};

  Map<String, dynamic>? get lastRunSettings {
    return lastAppSettingsForOperation('run');
  }

  Map<String, dynamic>? get lastPrepareKeySettings {
    return lastAppSettingsForOperation('prepare_key');
  }

  Map<String, dynamic>? lastAppSettingsForOperation(String operationId) {
    final entries = _payloads.values.toList(growable: false);
    for (int index = entries.length - 1; index >= 0; index -= 1) {
      final payload = entries[index];
      if (payload['workflow_id'] == 'app' &&
          payload['operation_id'] == operationId) {
        final params = payload['params'];
        if (params is! Map) {
          return null;
        }
        final settings = params['settings'];
        if (settings is! Map) {
          return null;
        }
        return settings.map((key, value) => MapEntry(key.toString(), value));
      }
    }
    return null;
  }

  @override
  String cancelTask(int taskId) {
    return jsonEncode({'status': 'success', 'cancelled': true});
  }

  @override
  String getTaskResult(int taskId) {
    final payload = _payloads[taskId]!;
    final workflowId = payload['workflow_id']?.toString();
    final operationId = payload['operation_id']?.toString();
    if (workflowId == 'app' && operationId == 'prepare_key') {
      appPrepareCalls += 1;
      final callback = onPrepareKeyResult;
      onPrepareKeyResult = null;
      callback?.call();
      if (prepareKeyFailureResult != null) {
        return jsonEncode({
          'status': 'success',
          'result': prepareKeyFailureResult,
        });
      }
      if (prepareKeyFailureMessage != null) {
        return jsonEncode({
          'status': 'success',
          'result': {'status': 'error', 'msg': prepareKeyFailureMessage},
        });
      }
      return jsonEncode({
        'status': 'success',
        'result': {
          'status': 'success',
          'deploy_public_key': prepareKeyMissingMaterial
              ? ''
              : 'ssh-ed25519 AAAATESTKEY',
          'deploy_private_key': prepareKeyMissingMaterial
              ? ''
              : '-----BEGIN PRIVATE KEY-----test',
        },
      });
    }
    if (workflowId == 'app' && operationId == 'run') {
      appRunCalls += 1;
      final callback = onAppRunResult;
      onAppRunResult = null;
      callback?.call();
      if (throwAppRunResult) {
        throw StateError('app run task result unavailable');
      }
      if (failAppRun || appRunCalls <= appRunFailuresBeforeSuccess) {
        final attemptIndex = appRunCalls - 1;
        if (appRunFailureResults != null &&
            attemptIndex >= 0 &&
            attemptIndex < appRunFailureResults!.length) {
          return jsonEncode({
            'status': 'success',
            'result': appRunFailureResults![attemptIndex],
          });
        }
        final failureMessage =
            appRunFailureMessages != null &&
                attemptIndex >= 0 &&
                attemptIndex < appRunFailureMessages!.length
            ? appRunFailureMessages![attemptIndex]
            : appRunFailureMessage;
        return jsonEncode({
          'status': 'success',
          'result': {'status': 'error', 'msg': failureMessage},
        });
      }
      return jsonEncode({
        'status': 'success',
        'result':
            appRunSuccessResult ??
            {
              'status': 'success',
              'http_url': 'http://blog.example.com',
              'https_url': 'https://blog.example.com',
              'process_readiness': {'status': 'ready'},
              'public_health': {
                'enabled': true,
                'status': 'healthy',
                'path': '/',
                'http_status': 200,
              },
            },
      });
    }
    return jsonEncode({
      'status': 'success',
      'result': {'status': 'success'},
    });
  }

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) {
    final responses = _taskPollResponses[taskId];
    if (responses != null && responses.isNotEmpty) {
      final index = _taskPollIndices[taskId] ?? 0;
      final boundedIndex = index >= responses.length
          ? responses.length - 1
          : index;
      _taskPollIndices[taskId] = boundedIndex + 1;
      return jsonEncode(responses[boundedIndex]);
    }
    return jsonEncode({
      'status': 'success',
      'events': const <Map<String, dynamic>>[],
      'done': true,
    });
  }

  @override
  String startTask(String jsonPayload) {
    final taskId = _nextTaskId++;
    final payload = jsonDecode(jsonPayload) as Map<String, dynamic>;
    _payloads[taskId] = payload;
    final workflowId = payload['workflow_id']?.toString();
    final operationId = payload['operation_id']?.toString();
    if (workflowId == 'app' &&
        operationId == 'run' &&
        appRunPollResponses != null &&
        appRunPollResponses!.isNotEmpty) {
      _taskPollResponses[taskId] = List<Map<String, dynamic>>.from(
        appRunPollResponses!,
      );
      _taskPollIndices[taskId] = 0;
    }
    return jsonEncode({'status': 'success', 'task_id': taskId});
  }

  @override
  String getRecentTaskHistory({int limit = 50}) {
    return jsonEncode({'status': 'success', 'history': const <dynamic>[]});
  }
}

class FakeProjectListNotifier extends ProjectListNotifier {
  String? lastDeploymentConfigProjectId;
  String? lastDeploymentConfigDomain;
  String? lastDeploymentConfigDomainRoutingMode;
  String? lastDeploymentConfigRepository;
  String? lastDeploymentConfigBranch;
  int? lastDeploymentConfigPort;
  String? lastDeploymentConfigBuildCommand;
  String? lastDeploymentConfigRunCommand;
  String? lastDeploymentConfigRailpackProvider;
  String? lastDeploymentConfigAppSubdirectory;
  String? lastDeploymentConfigTlsChallengeMode;
  String? lastDeploymentConfigTlsDnsProvider;
  Map<String, String>? lastDeploymentConfigTlsDnsCredentials;
  bool? lastDeploymentConfigSqliteStorageEnabled;
  String? lastDeploymentConfigSqliteVolumeName;
  String? lastDeploymentConfigSqliteMountPath;
  String? lastDeploymentConfigSqliteFileName;
  String? lastDeployStateProjectId;
  String? lastDeployStateCommit;
  DateTime? lastDeployStateDeployedAt;

  @override
  List<Project> build() => const [];

  @override
  void updateDeploymentConfig({
    required String projectId,
    required String primaryDomain,
    required String domainRoutingMode,
    required String repositoryFullName,
    required String? appSubdirectory,
    required String deployBranch,
    required int appPort,
    bool? publicHealthCheckEnabled,
    String? publicHealthCheckPath,
    required String railpackNodeMode,
    String? railpackProvider,
    required String tlsChallengeMode,
    required String? tlsDnsProvider,
    required Map<String, String> tlsDnsCredentials,
    required bool sqliteStorageEnabled,
    String? sqliteVolumeName,
    String? sqliteMountPath,
    String? sqliteFileName,
    String? railpackBuildCommand,
    String? railpackRunCommand,
  }) {
    lastDeploymentConfigProjectId = projectId;
    lastDeploymentConfigDomain = primaryDomain;
    lastDeploymentConfigDomainRoutingMode = domainRoutingMode;
    lastDeploymentConfigRepository = repositoryFullName;
    lastDeploymentConfigBranch = deployBranch;
    lastDeploymentConfigPort = appPort;
    lastDeploymentConfigBuildCommand = railpackBuildCommand;
    lastDeploymentConfigRunCommand = railpackRunCommand;
    lastDeploymentConfigRailpackProvider = railpackProvider;
    lastDeploymentConfigAppSubdirectory = appSubdirectory;
    lastDeploymentConfigTlsChallengeMode = tlsChallengeMode;
    lastDeploymentConfigTlsDnsProvider = tlsDnsProvider;
    lastDeploymentConfigTlsDnsCredentials = Map<String, String>.from(
      tlsDnsCredentials,
    );
    lastDeploymentConfigSqliteStorageEnabled = sqliteStorageEnabled;
    lastDeploymentConfigSqliteVolumeName = sqliteVolumeName;
    lastDeploymentConfigSqliteMountPath = sqliteMountPath;
    lastDeploymentConfigSqliteFileName = sqliteFileName;
  }

  @override
  void updateLastDeployState({
    required String projectId,
    required String commit,
    required DateTime deployedAt,
  }) {
    lastDeployStateProjectId = projectId;
    lastDeployStateCommit = commit;
    lastDeployStateDeployedAt = deployedAt;
  }
}

/// Runs [body] as a test, skipped when the SQLite runtime is unavailable.
void testWithSqlite(String description, Future<void> Function() body) {
  test(description, body, skip: !ensureSqliteRuntimeAvailable());
}
