/// Fixtures, fakes and pump helpers shared by the project workspace tests.
///
/// Extracted by T-3.6.1 from `project_workspace_test.dart`, which was 16,030
/// lines holding 230 tests in two groups -- a directory's worth of tests
/// wearing a filename. Nothing here is a test; it is what the sixteen
/// per-surface files beside it all need.
///
/// The declarations are public because a Dart library cannot share private
/// names and these are now shared. Three were renamed rather than simply
/// unprefixed, because stripping the underscore would have collided with an
/// identifier already in the file: `pumpProjectWorkspace`, `projectFixture`
/// and `seedLiveReleaseFor`.
///
/// Everything the original imported is re-exported, so a test file needs one
/// import rather than the thirty-nine the original carried. `dart:async` is
/// exported `hide AsyncError`, which Riverpod also defines.
library;

import 'dart:async';
import 'package:ui/data/local/app_database.dart'
    show AppDatabase, appDatabaseProvider;
import 'package:ui/data/local/app_deployment_history_repository.dart';
import 'package:ui/data/local/app_environment_variable_repository.dart';
import 'package:ui/data/local/app_release_repository.dart';
import 'package:ui/data/local/project_sqlite_database_repository.dart';
import 'package:ui/data/local/project_managed_database_repository.dart';
import 'package:ui/data/local/project_network_trust_repository.dart';
import 'package:ui/data/local/scheduler_task_repository.dart';
import 'package:ui/data/local/terminal_log_repository.dart';
import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/providers/backup_provider.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/project_sqlite_database_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:ui/ui/system/app_forms.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import '../../../../_support/legacy_ssh_service.dart';

export 'dart:async' hide AsyncError;
export 'dart:ui' show Tristate;
export 'package:ui/data/local/app_database.dart'
    show AppDatabase, appDatabaseProvider;
export 'package:ui/data/local/app_deployment_history_repository.dart';
export 'package:ui/data/local/app_environment_variable_repository.dart';
export 'package:ui/data/local/app_release_repository.dart';
export 'package:ui/data/local/project_sqlite_database_repository.dart';
export 'package:ui/data/local/project_sqlite_snapshot_repository.dart';
export 'package:ui/data/local/project_repository.dart';
export 'package:ui/data/local/project_database_access_repository.dart';
export 'package:ui/data/local/project_deletion_recovery_repository.dart';
export 'package:ui/data/local/project_managed_database_repository.dart';
export 'package:ui/data/local/project_network_trust_repository.dart';
export 'package:ui/data/local/scheduler_task_repository.dart';
export 'package:ui/data/local/server_credential_repository.dart';
export 'package:ui/data/local/terminal_log_repository.dart';
export 'package:ui/data/local/worker_instance_repository.dart';
export 'package:ui/providers/github_integration_provider.dart';
export 'package:ui/providers/backup_provider.dart';
export 'package:ui/providers/project_provider.dart';
export 'package:ui/providers/project_managed_database_provider.dart';
export 'package:ui/providers/project_sqlite_database_provider.dart';
export 'package:ui/providers/server_list_provider.dart';
export 'package:ui/providers/server_provider.dart';
export 'package:ui/services/ssh_service.dart';
export 'package:ui/services/project_deletion_coordinator.dart';
export 'package:ui/ui/project/project_workspace.dart';
export 'package:ui/ui/project/workspace/app/app_deployment_tab_logic.dart';
export 'package:ui/ui/system/app_forms.dart';
export 'package:ui/ui/system/app_state_views.dart';
export 'package:drift/native.dart';
export 'package:flutter/material.dart';
export 'package:flutter/services.dart';
export 'package:flutter_riverpod/flutter_riverpod.dart';
export 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
export 'package:yaru/yaru.dart';
export '../../../../_support/sqlite_test_harness.dart';
export '../../../../_support/legacy_ssh_service.dart';

const showManualGitHubCallbackToolsForTest = bool.fromEnvironment(
  'DEPLOYDASH_SHOW_MANUAL_GITHUB_CALLBACK',
);

const serverWithServicesDisabled = Server(
  id: 'server-disabled',
  name: 'srv.disabled.local',
  host: '192.168.1.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

const serverWithEmailEnabled = Server(
  id: 'server-email-enabled',
  name: 'srv.email.local',
  host: '192.168.1.20',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: true,
  serviceDomainEnabled: false,
);

const serverWithDomainEnabled = Server(
  id: 'server-domain-enabled',
  name: 'srv.domain.local',
  host: '192.168.1.21',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: true,
);

const serverWithRuntimeCredentials = Server(
  id: 'server-runtime',
  name: 'srv.runtime.local',
  host: '192.168.1.30',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

const serverWithCloudflareDnsEnabled = Server(
  id: 'server-runtime-cloudflare',
  name: 'srv.runtime.cloudflare.local',
  host: '192.168.1.31',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
  webServerConfig: ServerWebServerConfig(enableDnsPluginCloudflare: true),
);

const serverWithDatabaseEnabled = Server(
  id: 'server-database-enabled',
  name: 'srv.database.local',
  host: '192.168.1.40',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

Server serverWithUpdatedAt(Server server, DateTime updatedAt) {
  return Server(
    id: server.id,
    name: server.name,
    host: server.host,
    port: server.port,
    sshUser: server.sshUser,
    authMethod: server.authMethod,
    osName: server.osName,
    cpuArch: server.cpuArch,
    memoryMb: server.memoryMb,
    diskGb: server.diskGb,
    serviceDatabaseEnabled: server.serviceDatabaseEnabled,
    serviceEmailEnabled: server.serviceEmailEnabled,
    serviceDomainEnabled: server.serviceDomainEnabled,
    webServerConfig: server.webServerConfig,
    postgresConfig: server.postgresConfig,
    firewallConfig: server.firewallConfig,
    systemConfig: server.systemConfig,
    managedSoftwareStatus: server.managedSoftwareStatus,
    lastCheckStatus: server.lastCheckStatus,
    lastError: server.lastError,
    lastCheckedAt: server.lastCheckedAt,
    createdAt: server.createdAt,
    updatedAt: updatedAt,
  );
}

const serverWithDatabaseEnabledMissingPassword = Server(
  id: 'server-database-missing-password',
  name: 'srv.database-no-password.local',
  host: '192.168.1.41',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
  serviceDatabaseEnabled: true,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

const serverWithSshKeyEnabled = Server(
  id: 'server-ssh-key-enabled',
  name: 'srv.ssh-key.local',
  host: '192.168.1.50',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.sshKey,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

const serverWithMissingSshKeyPath = Server(
  id: 'server-ssh-key-missing-path',
  name: 'srv.ssh-key-missing.local',
  host: '192.168.1.51',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.sshKey,
  serviceDatabaseEnabled: false,
  serviceEmailEnabled: false,
  serviceDomainEnabled: false,
);

Future<Map<String, dynamic>?> testServerConnectionPayload(Server server) async {
  const key =
      '-----BEGIN OPENSSH PRIVATE KEY-----\n'
      'test-private-key\n'
      '-----END OPENSSH PRIVATE KEY-----';
  final credential = switch (server.id) {
    'server-runtime' || 'server-runtime-cloudflare' => <String, dynamic>{
      'password': 'super-secret',
    },
    'server-database-enabled' => <String, dynamic>{
      'password': 'postgres-password',
    },
    'server-database-rebound' => <String, dynamic>{
      'password': 'postgres-password',
    },
    'server-ssh-key-enabled' => <String, dynamic>{'private_key': key},
    _ => null,
  };
  if (credential == null) {
    return null;
  }
  return <String, dynamic>{
    'host': server.host,
    'port': server.port,
    'username': server.sshUser,
    ...credential,
  };
}

const selectedProject = Project(
  id: 'project-runtime',
  name: 'Regs v3',
  type: 'Web app',
  gitUrl: 'https://github.com/example/buildingregs',
  primaryDomain: 'dev.buildingregs.app',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
);

final selectedProjectWithLiveRuntime = Project(
  id: 'project-runtime',
  name: 'Regs v3',
  type: 'Web app',
  gitUrl: 'https://github.com/example/buildingregs',
  primaryDomain: 'dev.buildingregs.app',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 3000,
  railpackNodeMode: 'auto',
  lastDeployCommit: 'abc123',
  lastDeployedAt: DateTime(2026, 2, 20, 10),
);

const selectedProjectWithPythonRuntime = Project(
  id: 'project-runtime-python',
  name: 'Regs Python',
  type: 'Web app',
  gitUrl: 'https://github.com/example/buildingregs',
  primaryDomain: 'python.buildingregs.app',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'website',
  deployBranch: 'main',
  appPort: 8000,
  railpackBuildCommand: '',
  railpackRunCommand: '',
  railpackProvider: 'python',
  railpackNodeMode: 'auto',
);

final List<Map<String, dynamic>> pendingManagedPostgresCatalogSeeds =
    <Map<String, dynamic>>[];

void registerManagedPostgresCatalogSeed(Map<String, dynamic> response) {
  pendingManagedPostgresCatalogSeeds.add(Map<String, dynamic>.from(response));
}

class NoopTaskClient implements EngineTaskClient {
  @override
  String cancelTask(int taskId) => '{"status":"success","cancelled":true}';

  @override
  String getRecentTaskHistory({int limit = 50}) =>
      '{"status":"success","history":[]}';

  @override
  String getTaskResult(int taskId) => '{"status":"success","result":{}}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) =>
      '{"status":"success","events":[],"done":true}';

  @override
  String startTask(String jsonPayload) => '{"status":"success","task_id":1}';
}

class MutableServerCatalogNotifier extends ServerCatalogNotifier {
  MutableServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }

  void setSelectedServer(Server? server) {
    if (server == null) {
      state = const ServerCatalogState(
        isLoading: false,
        onboardingComplete: true,
        servers: <Server>[],
        onboardingStep: 'connected',
      );
      return;
    }

    state = ServerCatalogState(
      isLoading: false,
      onboardingComplete: true,
      servers: <Server>[server],
      selectedServerId: server.id,
      onboardingStep: 'connected',
    );
  }
}

class RuntimeWorkflowSshService extends LegacySshService {
  RuntimeWorkflowSshService() : super(taskClient: NoopTaskClient());

  int runtimeLogCalls = 0;
  int resourceUsageCalls = 0;
  int execCalls = 0;
  int execTaskId = 41;
  bool execCancelled = false;
  bool execCancelReturnValue = true;
  Object? resourceUsageError;
  Object? execError;
  Object? disconnectError;
  Completer<void>? deployRunCompleter;
  Completer<void>? listReleasesCompleter;
  final List<int> cancelledTaskIds = <int>[];
  Completer<void>? execCompleter;
  Map<String, dynamic> resourceUsageResponse = <String, dynamic>{
    'status': 'success',
    'resource_usage': <String, dynamic>{
      'Container': 'abc123',
      'Name': 'deploydash_app_buildingregs',
      'CPUPerc': '0.12%',
      'MemPerc': '10.00%',
      'MemUsage': '128MiB / 1GiB',
      'NetIO': '1MB / 1MB',
      'BlockIO': '0B / 0B',
      'PIDs': '5',
      'collected_at': DateTime.utc(2026, 4, 13, 12).toIso8601String(),
    },
    'container_status': <String, dynamic>{
      'present': true,
      'docker_state': 'running',
      'running': true,
      'health': 'healthy',
      'effective_status': 'ready',
    },
  };
  Map<String, dynamic> execResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'One-off app command completed.',
    'exit_code': 0,
    'stdout_lines': <String>['Applying migrations'],
    'stderr_lines': <String>[],
  };
  Map<String, dynamic> runtimeLogResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Runtime logs captured.',
    'runtime_log_lines': <String>[
      '2026-02-19T22:47:00Z app booted',
      '2026-02-19T22:47:01Z request finished',
    ],
  };
  Map<String, dynamic> listReleasesResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Release inventory captured.',
    'live_release_id': null,
    'releases': <Map<String, dynamic>>[],
  };
  Map<String, dynamic> rollbackResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Rollback completed.',
    'release_id': 'rollback-release',
    'rollback_from_release_id': 'live-release',
    'commit_sha': 'rollbackcommit1234',
  };
  Map<String, dynamic> disconnectResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Web app disconnected.',
  };
  Map<String, dynamic> appRunResponse = const <String, dynamic>{
    'status': 'success',
    'msg': 'Web app deployed.',
  };
  final List<Map<String, dynamic>> workflowCalls = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    workflowCalls.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'connection': connection == null
          ? null
          : Map<String, dynamic>.from(connection),
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'app' && operationId == 'resource_usage') {
      resourceUsageCalls += 1;
      if (resourceUsageError != null) {
        throw resourceUsageError!;
      }
      return Map<String, dynamic>.from(resourceUsageResponse);
    }
    if (workflowId == 'app' && operationId == 'runtime_logs') {
      runtimeLogCalls += 1;
      onEvent?.call({'type': 'pyinfra_log', 'message': 'runtime-event-alpha'});
      onEvent?.call({'type': 'pyinfra_log', 'message': 'runtime-event-alpha'});
      onEvent?.call({'type': 'engine_event', 'message': 'runtime-event-beta'});
      return Map<String, dynamic>.from(runtimeLogResponse);
    }
    if (workflowId == 'app' && operationId == 'exec') {
      execCalls += 1;
      onTaskStarted?.call(execTaskId);
      onEvent?.call(<String, dynamic>{
        'type': 'pyinfra_operation_stdout',
        'message': 'workflow plumbing before command output',
      });
      if (execCompleter != null) {
        await execCompleter!.future;
      }
      if (execError != null) {
        throw execError!;
      }
      if (execCancelled) {
        return const <String, dynamic>{
          'status': 'error',
          'code': 'ENGINE_TASK_CANCELLED',
          'msg': 'Command cancelled.',
        };
      }
      return Map<String, dynamic>.from(execResponse);
    }
    if (workflowId == 'app' && operationId == 'prepare_key') {
      return const <String, dynamic>{
        'status': 'success',
        'deploy_public_key': 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest',
        'deploy_private_key':
            '-----BEGIN OPENSSH PRIVATE KEY-----\nfake\n-----END OPENSSH PRIVATE KEY-----',
      };
    }
    if (workflowId == 'app' && operationId == 'run') {
      if (deployRunCompleter != null) {
        await deployRunCompleter!.future;
      }
      return Map<String, dynamic>.from(appRunResponse);
    }
    if (workflowId == 'app' && operationId == 'list_releases') {
      if (listReleasesCompleter != null) {
        await listReleasesCompleter!.future;
      }
      return Map<String, dynamic>.from(listReleasesResponse);
    }
    if (workflowId == 'app' && operationId == 'rollback') {
      return Map<String, dynamic>.from(rollbackResponse);
    }
    if (workflowId == 'app' && operationId == 'disconnect') {
      if (disconnectError != null) {
        throw disconnectError!;
      }
      return Map<String, dynamic>.from(disconnectResponse);
    }
    return const <String, dynamic>{'status': 'success'};
  }

  @override
  Future<bool> cancelTaskLegacy(int taskId) async {
    cancelledTaskIds.add(taskId);
    if (execCancelReturnValue) {
      execCancelled = true;
      if (execCompleter != null && !execCompleter!.isCompleted) {
        execCompleter!.complete();
      }
    }
    return execCancelReturnValue;
  }
}

class RecordingUrlLauncher extends UrlLauncherPlatform {
  String? launchedUrl;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrl = url;
    return true;
  }
}

class WorkspaceImportWorkflowSshService extends LegacySshService {
  WorkspaceImportWorkflowSshService() : super(taskClient: NoopTaskClient());

  final List<Map<String, dynamic>> workflowCalls = <Map<String, dynamic>>[];

  int countCalls(String workflowId, String operationId) {
    return workflowCalls
        .where(
          (call) =>
              call['workflow_id'] == workflowId &&
              call['operation_id'] == operationId,
        )
        .length;
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    workflowCalls.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return const <String, dynamic>{
        'status': 'success',
        'service_status': {'configured': true, 'running': true},
        'host': 'postgres.internal',
        'port': 5432,
        'databases': ['dd_regs_v3_app'],
        'users': [
          {
            'database': 'dd_regs_v3_app',
            'username': 'dd_regs_user',
            'access_mode': 'read_write',
            'connection_uri':
                'postgresql://dd_regs_user:secret@postgres.internal:5432/dd_regs_v3_app',
          },
        ],
      };
    }
    if (workflowId == 'app' && operationId == 'list_releases') {
      return const <String, dynamic>{
        'status': 'success',
        'live_release_id': 'release-import-live',
        'releases': [
          {
            'release_id': 'release-import-live',
            'status': 'live',
            'branch': 'main',
            'commit_sha': 'abc123import',
            'created_at': '2026-06-01T12:00:00Z',
            'live_at': '2026-06-01T12:02:00Z',
          },
        ],
      };
    }
    if (workflowId == 'postgres' && operationId == 'backup_artifact_list') {
      return const <String, dynamic>{
        'status': 'success',
        'artifacts': [
          {
            'remote_path': 's3://deploydash/backups/dd_regs_v3_app.sql.gz',
            'created_at': '2026-06-01T12:30:00Z',
            'size_bytes': 4096,
          },
        ],
      };
    }
    if (workflowId == 'app' && operationId == 'workers_status') {
      return const <String, dynamic>{
        'status': 'success',
        'workers': {
          'configured': [
            {'name': 'Indexer', 'container_running': true},
          ],
          'orphans': <dynamic>[],
        },
      };
    }
    if (workflowId == 'scheduler' && operationId == 'task_status') {
      return const <String, dynamic>{
        'status': 'success',
        'task_statuses': [
          {
            'task_id': 'task-import',
            'enabled': true,
            'timer_active_state': 'active',
            'service_result': 'success',
            'last_run_at': '2026-06-01T12:45:00Z',
            'next_run_at': '2026-06-01T13:00:00Z',
          },
        ],
      };
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class FailingWorkspaceImportWorkflowSshService
    extends WorkspaceImportWorkflowSshService {
  FailingWorkspaceImportWorkflowSshService(this.failure);

  final Object failure;
  int failedReleaseInventoryAttempts = 0;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (workflowId == 'app' && operationId == 'list_releases') {
      failedReleaseInventoryAttempts += 1;
      throw failure;
    }
    return super.runWorkflowLegacy(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

class ThrowingAppEnvironmentVariableRepository
    extends AppEnvironmentVariableRepository {
  ThrowingAppEnvironmentVariableRepository({
    this.throwOnList = false,
    this.throwOnReplace = true,
  }) : super(AppDatabase.forTesting(NativeDatabase.memory()));

  bool throwOnList;
  bool throwOnReplace;
  int listCalls = 0;

  @override
  Future<List<AppEnvironmentVariableRecord>> listForProject(
    String projectId,
  ) async {
    listCalls += 1;
    if (throwOnList) {
      throw StateError('list failed');
    }
    return const <AppEnvironmentVariableRecord>[];
  }

  @override
  Future<void> replaceForProject({
    required String projectId,
    required List<AppEnvironmentVariableRecord> rows,
  }) async {
    if (!throwOnReplace) {
      return;
    }
    throw StateError('replace failed');
  }
}

class ThrowingAppReleaseRepository extends AppReleaseRepository {
  ThrowingAppReleaseRepository(this.failure)
    : super(AppDatabase.forTesting(NativeDatabase.memory()));

  final Object failure;
  int remoteSuccessJournalReads = 0;

  @override
  Future<List<ProjectManagedOperationJournalRecord>> listRemoteSuccessJournal({
    int limit = 100,
  }) async {
    remoteSuccessJournalReads += 1;
    throw failure;
  }
}

class ThrowingAppDeploymentHistoryRepository
    extends AppDeploymentHistoryRepository {
  ThrowingAppDeploymentHistoryRepository(this.failure)
    : super(AppDatabase.forTesting(NativeDatabase.memory()));

  final Object failure;

  @override
  Future<List<AppDeploymentHistoryRecord>> listForProject(
    String projectId, {
    int limit = 5,
  }) async {
    throw failure;
  }
}

class DelegatingThrowingAppEnvironmentVariableRepository
    extends AppEnvironmentVariableRepository {
  DelegatingThrowingAppEnvironmentVariableRepository(this.delegate)
    : super(AppDatabase.forTesting(NativeDatabase.memory()));

  final AppEnvironmentVariableRepository delegate;

  @override
  Future<List<AppEnvironmentVariableRecord>> listForProject(String projectId) {
    return delegate.listForProject(projectId);
  }

  @override
  Future<void> replaceForProject({
    required String projectId,
    required List<AppEnvironmentVariableRecord> rows,
  }) async {
    throw StateError('replace failed');
  }
}

class ThrowingProjectNetworkTrustRepository
    extends ProjectNetworkTrustRepository {
  ThrowingProjectNetworkTrustRepository(super.database);

  @override
  Future<List<ProjectNetworkGroupRecord>> listGroupsForProject(
    String projectId,
  ) async {
    throw StateError('linked project lookup failed');
  }
}

class DatabaseWorkflowSshService extends LegacySshService {
  DatabaseWorkflowSshService({
    required this.projectListResponse,
    this.postgresOperationResponses = const <String, Map<String, dynamic>>{},
    this.operationEvents = const <String, List<Map<String, dynamic>>>{},
    this.throwingOperations = const <String>{},
  }) : super(taskClient: NoopTaskClient()) {
    registerManagedPostgresCatalogSeed(projectListResponse);
  }

  final Map<String, dynamic> projectListResponse;
  final Map<String, Map<String, dynamic>> postgresOperationResponses;
  final Map<String, List<Map<String, dynamic>>> operationEvents;
  final Set<String> throwingOperations;
  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  int countCalls(String workflowId, String operationId) {
    return callLog
        .where(
          (call) =>
              call['workflow_id'] == workflowId &&
              call['operation_id'] == operationId,
        )
        .length;
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    final events = operationEvents[operationId];
    if (events != null && onEvent != null) {
      for (final event in events) {
        onEvent(Map<String, dynamic>.from(event));
      }
    }
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return projectListResponse;
    }
    if (workflowId == 'postgres' && throwingOperations.contains(operationId)) {
      throw StateError('$operationId unavailable');
    }
    if (workflowId == 'postgres' &&
        postgresOperationResponses.containsKey(operationId)) {
      return postgresOperationResponses[operationId]!;
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class DatabaseSqliteWorkflowSshService extends LegacySshService {
  DatabaseSqliteWorkflowSshService({
    required this.projectListResponse,
    this.operationResponses = const <String, Map<String, dynamic>>{},
    this.throwingOperations = const <String, Object>{},
  }) : super(taskClient: NoopTaskClient());

  final Map<String, dynamic> projectListResponse;
  final Map<String, Map<String, dynamic>> operationResponses;
  final Map<String, Object> throwingOperations;
  int sqliteEnsureCalls = 0;
  int sqliteStatusCalls = 0;
  int sqliteDeleteCalls = 0;
  Map<String, dynamic>? lastSqliteSettings;
  Map<String, dynamic>? lastConnection;

  Map<String, dynamic> sqliteResponse({
    required Map<String, dynamic> settings,
    required String message,
    bool exists = true,
  }) {
    final sqlite = settings['sqlite_storage'];
    final sqliteMap = sqlite is Map
        ? sqlite.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final mountPath = sqliteMap['mount_path']?.toString() ?? '';
    final fileName = sqliteMap['file_name']?.toString() ?? '';
    final databasePath = mountPath.isNotEmpty && fileName.isNotEmpty
        ? '$mountPath/$fileName'
        : '';
    return <String, dynamic>{
      'status': 'success',
      'msg': message,
      'sqlite_storage': <String, dynamic>{
        'enabled': true,
        'volume_name': sqliteMap['volume_name']?.toString() ?? '',
        'mount_path': mountPath,
        'file_name': fileName,
        'database_path': databasePath,
        'database_url': databasePath.isEmpty ? '' : 'sqlite:///$databasePath',
        'volume_exists': exists,
        'volume_mountpoint': exists
            ? '/var/lib/docker/volumes/${sqliteMap['volume_name']}/_data'
            : '',
        'volume_size_bytes': exists ? 65536 : 0,
        'checked_at': DateTime.utc(2026, 3, 2, 12, 0, 0).toIso8601String(),
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return projectListResponse;
    }
    if (workflowId == 'app' &&
        (operationId == 'sqlite_volume_ensure' ||
            operationId == 'sqlite_volume_status' ||
            operationId == 'sqlite_volume_delete')) {
      lastConnection = connection == null
          ? null
          : Map<String, dynamic>.from(connection);
      if (throwingOperations.containsKey(operationId)) {
        throw StateError(throwingOperations[operationId].toString());
      }
      final settings = params?['settings'];
      lastSqliteSettings = settings is Map<String, dynamic>
          ? Map<String, dynamic>.from(settings)
          : settings is Map
          ? settings.map((key, value) => MapEntry(key.toString(), value))
          : const <String, dynamic>{};
      if (operationResponses.containsKey(operationId)) {
        return operationResponses[operationId]!;
      }
      if (operationId == 'sqlite_volume_ensure') {
        sqliteEnsureCalls += 1;
        return sqliteResponse(
          settings: lastSqliteSettings!,
          message: 'SQLite volume ensured.',
          exists: true,
        );
      }
      if (operationId == 'sqlite_volume_status') {
        sqliteStatusCalls += 1;
        return sqliteResponse(
          settings: lastSqliteSettings!,
          message: 'SQLite volume status captured.',
          exists: true,
        );
      }
      sqliteDeleteCalls += 1;
      return sqliteResponse(
        settings: lastSqliteSettings!,
        message: 'SQLite volume deleted.',
        exists: false,
      );
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class ThrowingProjectSqliteDatabaseRepository
    extends ProjectSqliteDatabaseRepository {
  ThrowingProjectSqliteDatabaseRepository(
    super.database, {
    this.throwOnUpsert = false,
    this.throwOnSetPrimary = false,
    this.throwOnDelete = false,
  });

  final bool throwOnUpsert;
  final bool throwOnSetPrimary;
  final bool throwOnDelete;

  @override
  Future<void> upsert(ProjectSqliteDatabase record) async {
    if (throwOnUpsert) {
      throw StateError('sqlite upsert failed');
    }
    return super.upsert(record);
  }

  @override
  Future<void> setPrimary({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    if (throwOnSetPrimary) {
      throw StateError('sqlite set primary failed');
    }
    return super.setPrimary(
      projectId: projectId,
      sqliteDatabaseId: sqliteDatabaseId,
    );
  }

  @override
  Future<void> delete({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    if (throwOnDelete) {
      throw StateError('sqlite delete failed');
    }
    return super.delete(
      projectId: projectId,
      sqliteDatabaseId: sqliteDatabaseId,
    );
  }
}

class DelayedProjectSqliteDatabaseRepository
    extends ProjectSqliteDatabaseRepository {
  DelayedProjectSqliteDatabaseRepository(
    super.database, {
    this.delaySetPrimary = false,
  });

  final bool delaySetPrimary;
  final Completer<void> setPrimaryStarted = Completer<void>();
  final Completer<void> releaseSetPrimary = Completer<void>();

  @override
  Future<void> setPrimary({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    if (delaySetPrimary) {
      if (!setPrimaryStarted.isCompleted) {
        setPrimaryStarted.complete();
      }
      await releaseSetPrimary.future;
    }
    return super.setPrimary(
      projectId: projectId,
      sqliteDatabaseId: sqliteDatabaseId,
    );
  }
}

class DelayedProjectManagedDatabaseRepository
    extends ProjectManagedDatabaseRepository {
  DelayedProjectManagedDatabaseRepository(super.database);

  bool delayNextDatabaseLoad = false;
  final Completer<void> databaseLoadStarted = Completer<void>();
  final Completer<void> releaseDatabaseLoad = Completer<void>();

  @override
  Future<List<ProjectManagedDatabaseRecord>> listDatabasesForScope({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
  }) async {
    if (!delayNextDatabaseLoad) {
      return super.listDatabasesForScope(
        projectId: projectId,
        serverId: serverId,
        engine: engine,
      );
    }
    delayNextDatabaseLoad = false;
    databaseLoadStarted.complete();
    await releaseDatabaseLoad.future;
    return super.listDatabasesForScope(
      projectId: projectId,
      serverId: serverId,
      engine: engine,
    );
  }
}

class GitHubReadyGateway implements GitHubAuthGateway {
  @override
  Stream<Uri> get callbackLinks => const Stream<Uri>.empty();

  @override
  Future<List<String>> fetchBranches({
    required String accessToken,
    required String repositoryFullName,
  }) async {
    return const <String>['main', 'develop'];
  }

  @override
  Future<List<GitHubRepository>> fetchRepositories({
    required String accessToken,
  }) async {
    return const <GitHubRepository>[
      GitHubRepository(
        name: 'laravel-example-app',
        fullName: 'deploydash/laravel-example-app',
        isPrivate: false,
      ),
      GitHubRepository(
        name: 'website',
        fullName: 'deploydash/amplitude-flutter-desktop',
        isPrivate: true,
      ),
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

  @override
  Future<String> exchangeCodeForToken({
    required String code,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    return 'token_$code';
  }
}

class DialogProjectNotifier extends ProjectListNotifier {
  DialogProjectNotifier(this.project);

  final Project project;
  String? lastProjectId;
  String? lastRepositoryFullName;
  String? lastRailpackProvider;
  String? lastRailpackBuildCommand;
  String? lastRailpackRunCommand;
  int? lastAppPort;
  String? lastDomainRoutingMode;
  String? lastTlsChallengeMode;
  String? lastTlsDnsProvider;
  int updateRuntimeStateCalls = 0;
  bool? lastAppDisconnected;

  @override
  List<Project> build() => <Project>[project];

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
    lastProjectId = projectId;
    lastRepositoryFullName = repositoryFullName;
    lastDomainRoutingMode = domainRoutingMode;
    lastRailpackProvider = railpackProvider;
    lastRailpackBuildCommand = railpackBuildCommand;
    lastRailpackRunCommand = railpackRunCommand;
    lastAppPort = appPort;
    lastTlsChallengeMode = tlsChallengeMode;
    lastTlsDnsProvider = tlsDnsProvider;
  }

  @override
  void updateRuntimeState({required String projectId, bool? appDisconnected}) {
    updateRuntimeStateCalls += 1;
    lastProjectId = projectId;
    lastAppDisconnected = appDisconnected;
  }
}

class MutableGitHubIntegrationNotifier extends GitHubIntegrationNotifier {
  MutableGitHubIntegrationNotifier(this._initialState);

  final GitHubIntegrationState _initialState;

  @override
  GitHubIntegrationState build() => _initialState;

  void publish(GitHubIntegrationState nextState) {
    state = nextState;
  }
}

class RecordingDatabaseWiringProjectNotifier extends ProjectListNotifier {
  RecordingDatabaseWiringProjectNotifier(this.project);

  final Project project;
  String? lastProjectId;
  bool? lastInjectPostgresEnv;

  @override
  List<Project> build() => <Project>[project];

  @override
  void updateDatabaseWiring({
    required String projectId,
    required bool injectPostgresEnv,
  }) {
    lastProjectId = projectId;
    lastInjectPostgresEnv = injectPostgresEnv;
    state = [project.copyWith(injectPostgresEnv: injectPostgresEnv)];
  }
}

class StaticProjectListNotifier extends ProjectListNotifier {
  StaticProjectListNotifier(this.projects);

  final List<Project> projects;

  @override
  List<Project> build() => List<Project>.from(projects);
}

class OperationOverrideDatabaseWorkflowSshService extends LegacySshService {
  OperationOverrideDatabaseWorkflowSshService({
    required this.projectListResponse,
    required this.operationResponses,
  }) : super(taskClient: NoopTaskClient()) {
    registerManagedPostgresCatalogSeed(projectListResponse);
  }

  final Map<String, dynamic> projectListResponse;
  final Map<String, Map<String, dynamic>> operationResponses;
  int projectListCalls = 0;
  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'postgres' && operationId == 'project_list') {
      projectListCalls += 1;
      return projectListResponse;
    }
    if (workflowId == 'postgres' &&
        operationResponses.containsKey(operationId)) {
      return operationResponses[operationId]!;
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class SharingDatabaseWorkflowSshService extends LegacySshService {
  SharingDatabaseWorkflowSshService({
    this.postgresProjectListBySlug = const <String, Map<String, dynamic>>{},
  }) : super(taskClient: NoopTaskClient());

  final Map<String, Map<String, dynamic>> postgresProjectListBySlug;
  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    final rawSettings = params?['settings'];
    final settings = rawSettings is Map<String, dynamic>
        ? Map<String, dynamic>.from(rawSettings)
        : rawSettings is Map
        ? rawSettings.map((key, value) => MapEntry(key.toString(), value))
        : const <String, dynamic>{};
    final projectSlug = settings['project_slug']?.toString().trim() ?? '';
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'project_slug': projectSlug,
      'connection': connection == null
          ? null
          : Map<String, dynamic>.from(connection),
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });

    if (operationId == 'project_list') {
      if (workflowId == 'postgres') {
        return postgresProjectListBySlug[projectSlug] ??
            const <String, dynamic>{
              'status': 'success',
              'service_status': <String, dynamic>{
                'configured': true,
                'running': true,
              },
              'databases': <String>[],
              'users': <Map<String, dynamic>>[],
            };
      }
    }

    return const <String, dynamic>{'status': 'success'};
  }
}

class OutcomeDatabaseWorkflowSshService extends LegacySshService {
  OutcomeDatabaseWorkflowSshService({
    required this.projectListOutcome,
    this.operationOutcomes = const <String, Object>{},
  }) : super(taskClient: NoopTaskClient()) {
    final outcome = projectListOutcome;
    if (outcome is Map<String, dynamic>) {
      registerManagedPostgresCatalogSeed(outcome);
    } else if (outcome is Map) {
      registerManagedPostgresCatalogSeed(
        outcome.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
  }

  final Object projectListOutcome;
  final Map<String, Object> operationOutcomes;
  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  Map<String, dynamic> resolve(Object outcome) {
    if (outcome is Map<String, dynamic>) {
      return outcome;
    }
    if (outcome is Map) {
      return outcome.map((key, value) => MapEntry(key.toString(), value));
    }
    if (outcome is Error) {
      throw outcome;
    }
    if (outcome is Exception) {
      throw outcome;
    }
    throw StateError(outcome.toString());
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return resolve(projectListOutcome);
    }
    final outcome = operationOutcomes['$workflowId/$operationId'];
    if (outcome != null) {
      return resolve(outcome);
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class DelayedOperationDatabaseWorkflowSshService extends LegacySshService {
  DelayedOperationDatabaseWorkflowSshService({
    required this.projectListResponse,
    required this.delayedOperationId,
    this.delayedResponse = const <String, dynamic>{
      'status': 'success',
      'msg': 'Done.',
    },
  }) : super(taskClient: NoopTaskClient()) {
    registerManagedPostgresCatalogSeed(projectListResponse);
  }

  final Map<String, dynamic> projectListResponse;
  final String delayedOperationId;
  final Map<String, dynamic> delayedResponse;
  final Completer<void> operationStarted = Completer<void>();
  final Completer<void> releaseOperation = Completer<void>();

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (workflowId == 'postgres' && operationId == 'project_list') {
      return projectListResponse;
    }
    if (operationId == delayedOperationId) {
      if (!operationStarted.isCompleted) {
        operationStarted.complete();
      }
      await releaseOperation.future;
      return delayedResponse;
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class DelayedProjectListDatabaseWorkflowSshService extends LegacySshService {
  DelayedProjectListDatabaseWorkflowSshService({
    required this.projectListResponse,
    this.delayedCallNumber = 1,
  }) : super(taskClient: NoopTaskClient());

  final Map<String, dynamic> projectListResponse;
  final int delayedCallNumber;
  final Completer<void> projectListStarted = Completer<void>();
  final Completer<void> releaseProjectList = Completer<void>();
  int projectListCalls = 0;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (workflowId == 'postgres' && operationId == 'project_list') {
      projectListCalls += 1;
      if (projectListCalls == delayedCallNumber) {
        if (!projectListStarted.isCompleted) {
          projectListStarted.complete();
        }
        await releaseProjectList.future;
      }
      return projectListResponse;
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class WorkersWorkflowSshService extends LegacySshService {
  WorkersWorkflowSshService({
    required this.projectListResponse,
    required Map<String, dynamic> statusResponse,
    required Map<String, dynamic> applyResponse,
    Map<String, dynamic>? precheckResponse,
    Map<String, dynamic>? workerOperationResponse,
    Map<String, dynamic>? workerLogsResponse,
    Map<String, List<Object>> operationOutcomesByKey = const {},
    Map<String, Duration> operationDelaysByKey = const {},
  }) : _statusResponse = statusResponse,
       _applyResponse = applyResponse,
       _precheckResponse =
           precheckResponse ??
           const <String, dynamic>{
             'status': 'success',
             'workers_precheck': {
               'image_exists': true,
               'app_container_exists': true,
               'app_container_running': true,
               'worker_network': 'deploydash_default',
             },
           },
       _workerOperationResponse =
           workerOperationResponse ??
           const <String, dynamic>{
             'status': 'success',
             'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
           },
       _workerLogsResponse =
           workerLogsResponse ??
           const <String, dynamic>{'status': 'success', 'logs': <dynamic>[]},
       _operationOutcomesByKey = operationOutcomesByKey,
       _operationDelaysByKey = operationDelaysByKey,
       super(taskClient: NoopTaskClient()) {
    registerManagedPostgresCatalogSeed(projectListResponse);
  }

  final Map<String, dynamic> projectListResponse;
  final Map<String, dynamic> _statusResponse;
  final Map<String, dynamic> _applyResponse;
  final Map<String, dynamic> _precheckResponse;
  final Map<String, dynamic> _workerOperationResponse;
  final Map<String, dynamic> _workerLogsResponse;
  final Map<String, List<Object>> _operationOutcomesByKey;
  final Map<String, Duration> _operationDelaysByKey;
  final Map<String, int> _operationOutcomeIndexByKey = <String, int>{};

  int projectListCalls = 0;
  int statusCalls = 0;
  int applyCalls = 0;
  int precheckCalls = 0;
  int workerStartCalls = 0;
  int workerStopCalls = 0;
  int workerRestartCalls = 0;
  int workerLogsCalls = 0;
  Map<String, dynamic>? lastStatusParams;
  Map<String, dynamic>? lastApplyParams;
  Map<String, dynamic>? lastWorkerOperationParams;
  Map<String, dynamic>? lastWorkerLogsParams;

  Map<String, dynamic> resolveOutcome({
    required String key,
    required Map<String, dynamic> fallback,
  }) {
    final outcomes = _operationOutcomesByKey[key];
    if (outcomes == null || outcomes.isEmpty) {
      return fallback;
    }
    final index = _operationOutcomeIndexByKey[key] ?? 0;
    final safeIndex = index < outcomes.length ? index : outcomes.length - 1;
    _operationOutcomeIndexByKey[key] = index + 1;
    final outcome = outcomes[safeIndex];
    if (outcome is Map<String, dynamic>) {
      return outcome;
    }
    if (outcome is Map) {
      return outcome.map((key, value) => MapEntry(key.toString(), value));
    }
    if (outcome is Error) {
      throw outcome;
    }
    if (outcome is Exception) {
      throw outcome;
    }
    throw StateError(outcome.toString());
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    final operationKey = '$workflowId/$operationId';
    final delay = _operationDelaysByKey[operationKey];
    if (delay != null) {
      await Future<void>.delayed(delay);
    }
    if (workflowId == 'postgres' && operationId == 'project_list') {
      projectListCalls += 1;
      return resolveOutcome(key: operationKey, fallback: projectListResponse);
    }
    if (workflowId == 'app' && operationId == 'workers_precheck') {
      precheckCalls += 1;
      return resolveOutcome(key: operationKey, fallback: _precheckResponse);
    }
    if (workflowId == 'app' && operationId == 'workers_status') {
      statusCalls += 1;
      lastStatusParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(key: operationKey, fallback: _statusResponse);
    }
    if (workflowId == 'app' && operationId == 'workers_apply') {
      applyCalls += 1;
      lastApplyParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(key: operationKey, fallback: _applyResponse);
    }
    if (workflowId == 'app' && operationId == 'worker_start') {
      workerStartCalls += 1;
      lastWorkerOperationParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(
        key: operationKey,
        fallback: _workerOperationResponse,
      );
    }
    if (workflowId == 'app' && operationId == 'worker_stop') {
      workerStopCalls += 1;
      lastWorkerOperationParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(
        key: operationKey,
        fallback: _workerOperationResponse,
      );
    }
    if (workflowId == 'app' && operationId == 'worker_restart') {
      workerRestartCalls += 1;
      lastWorkerOperationParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(
        key: operationKey,
        fallback: _workerOperationResponse,
      );
    }
    if (workflowId == 'app' && operationId == 'worker_logs') {
      workerLogsCalls += 1;
      lastWorkerLogsParams = params == null
          ? null
          : Map<String, dynamic>.from(params);
      return resolveOutcome(key: operationKey, fallback: _workerLogsResponse);
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class SchedulerWorkflowSshService extends LegacySshService {
  SchedulerWorkflowSshService({Map<String, dynamic>? runNowResponse})
    : runNowResponse =
          runNowResponse ??
          const <String, dynamic>{
            'status': 'success',
            'msg': 'Scheduled job completed.',
            'service_result': 'success',
            'service_active_state': 'inactive',
            'exit_code': '0',
            'finished_at': '2026-02-25T10:02:00Z',
            'run_succeeded': true,
            'run_output_lines': ['PHP 8.3.1'],
            'run_output': 'PHP 8.3.1',
          },
      super(taskClient: NoopTaskClient());

  int upsertCalls = 0;
  int runNowCalls = 0;
  int statusCalls = 0;
  final Map<String, dynamic> runNowResponse;
  Map<String, dynamic>? lastUpsertSettings;
  Map<String, dynamic>? lastRunNowSettings;
  Map<String, dynamic>? lastStatusSettings;

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    if (workflowId == 'scheduler' && operationId == 'task_upsert') {
      upsertCalls += 1;
      final settings = params?['settings'];
      lastUpsertSettings = settings is Map
          ? settings.map((key, value) => MapEntry(key.toString(), value))
          : null;
      return const <String, dynamic>{
        'status': 'success',
        'msg': 'Saved.',
        'timer_active_state': 'active',
        'service_result': 'success',
        'last_run_at': '2026-02-25T10:00:00Z',
        'next_run_at': '2026-02-25T10:05:00Z',
      };
    }
    if (workflowId == 'scheduler' && operationId == 'task_run_now') {
      runNowCalls += 1;
      final settings = params?['settings'];
      lastRunNowSettings = settings is Map
          ? settings.map((key, value) => MapEntry(key.toString(), value))
          : null;
      return runNowResponse;
    }
    if (workflowId == 'scheduler' && operationId == 'task_status') {
      statusCalls += 1;
      final settings = params?['settings'];
      lastStatusSettings = settings is Map
          ? settings.map((key, value) => MapEntry(key.toString(), value))
          : null;
      final taskIds = settings is Map ? settings['task_ids'] : null;
      final ids = taskIds is List
          ? taskIds.map((value) => value.toString()).toList(growable: false)
          : const <String>[];
      return <String, dynamic>{
        'status': 'success',
        'task_statuses': ids
            .map(
              (id) => <String, dynamic>{
                'task_id': id,
                'enabled': true,
                'timer_active_state': 'active',
                'service_result': 'success',
                'last_run_at': '2026-02-25T10:00:00Z',
                'next_run_at': '2026-02-25T10:05:00Z',
              },
            )
            .toList(growable: false),
      };
    }
    if (workflowId == 'scheduler' && operationId == 'task_set_enabled') {
      return const <String, dynamic>{
        'status': 'success',
        'timer_active_state': 'active',
        'service_result': 'success',
      };
    }
    if (workflowId == 'scheduler' && operationId == 'task_delete') {
      return const <String, dynamic>{'status': 'success', 'msg': 'Deleted.'};
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class ProjectDeleteWorkflowSshService extends LegacySshService {
  ProjectDeleteWorkflowSshService() : super(taskClient: NoopTaskClient());

  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  int countCalls(String workflowId, String operationId) {
    return callLog
        .where(
          (call) =>
              call['workflow_id'] == workflowId &&
              call['operation_id'] == operationId,
        )
        .length;
  }

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    // The coordinator dry-runs project deletes before executing them, and
    // refuses to execute when the plan is missing. An empty plan keeps this
    // fake's "every workflow succeeds" contract without inventing resources.
    if (workflowId == 'postgres' &&
        operationId == 'project_delete' &&
        params?['dry_run'] == true) {
      return <String, dynamic>{
        'status': 'success',
        'msg': 'postgres/project_delete plan ready',
        'databases': <String>[],
        'users': <String>[],
      };
    }
    return <String, dynamic>{
      'status': 'success',
      'msg': '$workflowId/$operationId ok',
    };
  }
}

class DeleteFailureProjectNotifier extends ProjectListNotifier {
  @override
  List<Project> build() => const [selectedProject];

  @override
  Future<String?> deleteProject(String projectId) async {
    throw Exception('delete project failed');
  }
}

class DeleteSuccessProjectNotifier extends ProjectListNotifier {
  DeleteSuccessProjectNotifier([this.project = selectedProject]);

  final Project project;

  @override
  List<Project> build() => <Project>[project];

  @override
  Future<String?> deleteProject(String projectId) async {
    state = const <Project>[];
    return null;
  }
}

class MutableSelectedProjectNotifier extends Notifier<Project?> {
  @override
  Project? build() => selectedProject;

  void select(Project? project) {
    state = project;
  }
}

final mutableSelectedProjectProvider =
    NotifierProvider<MutableSelectedProjectNotifier, Project?>(
      MutableSelectedProjectNotifier.new,
    );

class DeleteFallbackMessageSshService extends LegacySshService {
  DeleteFallbackMessageSshService() : super(taskClient: NoopTaskClient());

  final List<Map<String, dynamic>> callLog = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> runWorkflowLegacy({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) async {
    callLog.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'connection': connection == null
          ? null
          : Map<String, dynamic>.from(connection),
      'params': params == null ? null : Map<String, dynamic>.from(params),
    });
    if (workflowId == 'app' && operationId == 'disconnect') {
      return const <String, dynamic>{'status': 'error', 'msg': '   '};
    }
    return const <String, dynamic>{'status': 'success'};
  }
}

class ThrowingBackupRepository extends BackupRepository {
  const ThrowingBackupRepository(super.database);

  @override
  Future<List<BackupDestinationRecord>> listDestinationsForScope({
    required String projectId,
    required String serverId,
  }) {
    throw Exception('backup scope exploded');
  }
}

class ThrowingSchedulerTaskRepository extends SchedulerTaskRepository {
  const ThrowingSchedulerTaskRepository(super.database);

  @override
  Future<List<SchedulerTaskRecord>> listTasksForProject(String projectId) {
    throw Exception('scheduler load exploded');
  }
}

class RecordingProjectSqliteDatabasesNotifier
    extends ProjectSqliteDatabasesNotifier {
  RecordingProjectSqliteDatabasesNotifier();
  final List<String> loadedProjects = <String>[];

  @override
  Map<String, List<ProjectSqliteDatabase>> build() =>
      const <String, List<ProjectSqliteDatabase>>{};

  @override
  Future<void> loadProject(String projectId) async {
    loadedProjects.add(projectId);
  }
}

ProjectSqliteDatabase sqliteRecord({
  required String id,
  required String name,
  required String volumeName,
  bool isPrimary = false,
  bool? volumeExists,
  String? volumeMountpoint,
  int? volumeSizeBytes,
  DateTime? lastCheckedAt,
}) {
  return ProjectSqliteDatabase(
    id: id,
    projectId: selectedProject.id,
    name: name,
    volumeName: volumeName,
    mountPath: '/workspace/data',
    fileName: '${name.toLowerCase()}.db',
    isPrimary: isPrimary,
    volumeExists: volumeExists,
    volumeMountpoint: volumeMountpoint,
    volumeSizeBytes: volumeSizeBytes,
    lastCheckedAt: lastCheckedAt,
  );
}

Future<AppDatabase> createDatabaseWithSqliteRows(
  List<ProjectSqliteDatabase> rows,
) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  final repository = ProjectSqliteDatabaseRepository(database);
  for (final row in rows) {
    await repository.upsert(row);
  }
  return database;
}

Future<void> pumpProjectWorkspace(
  WidgetTester tester, {
  Widget child = const ProjectWorkspace(),
  // riverpod 3.x's Override type is intentionally not exported from
  // the public riverpod.dart/flutter_riverpod.dart barrel (ProviderScope
  // itself still declares `final List<Override> overrides` -- it's just
  // not nameable outside the package). No supported way to spell this
  // parameter's type explicitly; ignore is the documented escape hatch.
  // ignore: strict_raw_type
  List overrides = const [],
  AppDatabase? database,
  Size surfaceSize = const Size(1920, 1080),
}) async {
  final ownsDatabase = database == null;
  final resolvedDatabase =
      database ?? AppDatabase.forTesting(NativeDatabase.memory());
  if (ownsDatabase) {
    addTearDown(() async {
      await resolvedDatabase.close();
    });
  }
  final pendingManagedSeeds = List<Map<String, dynamic>>.from(
    pendingManagedPostgresCatalogSeeds,
  );
  pendingManagedPostgresCatalogSeeds.clear();
  for (final seed in pendingManagedSeeds) {
    await seedManagedPostgresCatalog(
      resolvedDatabase,
      projectListResponse: seed,
    );
  }
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = surfaceSize;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(resolvedDatabase),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          testServerConnectionPayload,
        ),
        // ignore: list_element_type_not_assignable
        ...overrides,
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openProjectWorkspaceDestination(
  WidgetTester tester,
  String destinationId,
) async {
  final destination = find.byKey(Key('project-workspace-nav-$destinationId'));
  final verticalNavigation = find.byKey(
    const Key('app-context-navigation-project-workspace-vertical'),
  );
  if (verticalNavigation.evaluate().isNotEmpty) {
    await tester.scrollUntilVisible(
      destination,
      80,
      scrollable: find
          .descendant(of: verticalNavigation, matching: find.byType(Scrollable))
          .first,
    );
  } else {
    await tester.ensureVisible(destination);
  }
  await tester.pumpAndSettle();
  await tester.tap(destination);
  await tester.pumpAndSettle();
}

Project projectRecord(
  Project project, {
  required String serverId,
  bool isActive = false,
}) {
  return Project(
    id: project.id,
    serverId: serverId,
    name: project.name,
    type: project.type,
    gitUrl: project.gitUrl,
    primaryDomain: project.primaryDomain,
    repositoryFullName: project.repositoryFullName,
    appSubdirectory: project.appSubdirectory,
    deployBranch: project.deployBranch,
    appPort: project.appPort,
    railpackBuildCommand: project.railpackBuildCommand,
    railpackRunCommand: project.railpackRunCommand,
    railpackProvider: project.railpackProvider,
    railpackNodeMode: project.railpackNodeMode,
    domainRoutingMode: project.domainRoutingMode,
    tlsChallengeMode: project.tlsChallengeMode,
    tlsDnsProvider: project.tlsDnsProvider,
    isActive: isActive,
  );
}

Project projectFixture({
  required String id,
  required String name,
  required String serverId,
  required String primaryDomain,
}) {
  return Project(
    id: id,
    serverId: serverId,
    name: name,
    type: selectedProject.type,
    gitUrl: selectedProject.gitUrl,
    primaryDomain: primaryDomain,
    repositoryFullName: selectedProject.repositoryFullName,
    appSubdirectory: selectedProject.appSubdirectory,
    deployBranch: selectedProject.deployBranch,
    appPort: selectedProject.appPort,
    railpackBuildCommand: selectedProject.railpackBuildCommand,
    railpackRunCommand: selectedProject.railpackRunCommand,
    railpackProvider: selectedProject.railpackProvider,
    railpackNodeMode: selectedProject.railpackNodeMode,
    tlsChallengeMode: selectedProject.tlsChallengeMode,
    tlsDnsProvider: selectedProject.tlsDnsProvider,
  );
}

Future<ProviderContainer> pumpWorkspaceWithGitHubReady(
  WidgetTester tester, {
  required AppDatabase database,
  required Project project,
  required DialogProjectNotifier projectNotifier,
  Server? server = serverWithRuntimeCredentials,
  RuntimeWorkflowSshService? sshService,
  AppEnvironmentVariableRepository? envRepository,
  bool seedLiveRelease = false,
  bool selectRepository = true,
  Size viewSize = const Size(1920, 1080),
}) async {
  final effectiveSshService = sshService ?? RuntimeWorkflowSshService();
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      gitHubAuthGatewayProvider.overrideWithValue(GitHubReadyGateway()),
      gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
      projectListProvider.overrideWith(() => projectNotifier),
      selectedProjectProvider.overrideWithValue(project),
      selectedServerProvider.overrideWithValue(server),
      serverConnectionPayloadResolverProvider.overrideWithValue(
        testServerConnectionPayload,
      ),
      sshServiceProvider.overrideWithValue(effectiveSshService),
      if (envRepository != null)
        appEnvironmentVariableRepositoryProvider.overrideWithValue(
          envRepository,
        ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    if (sshService == null) {
      effectiveSshService.dispose();
    }
    await database.close();
  });

  final notifier = container.read(gitHubIntegrationProvider.notifier);
  await notifier.connectGitHub();
  final authUrl = Uri.parse(
    container.read(gitHubIntegrationProvider).authorizationUrl!,
  );
  final oauthState = authUrl.queryParameters['state']!;
  await notifier.processCallbackUrl(
    'deploydash://callback?code=abc123&state=$oauthState',
  );
  if (selectRepository) {
    notifier.selectRepository('deploydash/laravel-example-app');
  }
  if (seedLiveRelease && server != null) {
    await seedLiveReleaseFor(database, project: project, server: server);
  }

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = viewSize;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> confirmRemoveWebAppRuntime(
  WidgetTester tester, {
  required Project project,
}) async {
  await expandAppDisclosure(tester, const Key('app-disconnect-card'));
  await tester.ensureVisible(find.byKey(const Key('app-disconnect-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('app-disconnect-button')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, project.name);
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Remove web app').last);
  await tester.pumpAndSettle();
}

Future<void> expandAppDisclosure(WidgetTester tester, Key key) async {
  final appScroll = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(find.byKey(key), 300, scrollable: appScroll);
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byKey(key), matching: find.byType(ExpansionTile)),
  );
  await tester.pumpAndSettle();
}

Future<void> seedLiveReleaseFor(
  AppDatabase database, {
  required Project project,
  required Server server,
}) async {
  final now = DateTime(2026, 2, 20, 12, 0);
  final release = AppReleaseRepository.fromBackendRelease(
    projectId: project.id,
    serverId: server.id,
    observedAt: now,
    payload: <String, dynamic>{
      'release_id': 'release-live',
      'status': 'live',
      'branch': project.deployBranch,
      'commit_sha': 'abc123',
      'app_port': project.appPort,
      'created_at': now.toUtc().toIso8601String(),
      'live_at': now.toUtc().toIso8601String(),
    },
  );
  if (release == null) {
    return;
  }
  await AppReleaseRepository(database).replaceReleasesForScope(
    projectId: project.id,
    serverId: server.id,
    releases: [release],
  );
}

Future<void> seedReleaseInventory(
  AppDatabase database, {
  required Project project,
  required Server server,
  required List<Map<String, dynamic>> releases,
}) async {
  final records = releases
      .map(
        (release) => AppReleaseRepository.fromBackendRelease(
          projectId: project.id,
          serverId: server.id,
          payload: release,
          observedAt: DateTime.utc(2026, 6, 1, 12),
        ),
      )
      .whereType<AppReleaseRecord>()
      .toList(growable: false);
  await AppReleaseRepository(database).replaceReleasesForScope(
    projectId: project.id,
    serverId: server.id,
    releases: records,
  );
}

Future<void> seedManagedPostgresCatalog(
  AppDatabase database, {
  Project project = selectedProject,
  Server server = serverWithDatabaseEnabled,
  required Map<String, dynamic> projectListResponse,
}) async {
  final now = DateTime.utc(2026, 6, 1, 12);
  final databases = <ProjectManagedDatabaseRecord>[];
  final users = <ProjectManagedDatabaseUserRecord>[];
  final responseHost =
      projectListResponse['host']?.toString() ??
      projectListResponse['database_host']?.toString();
  final responsePort =
      nullableInt(projectListResponse['port']) ??
      nullableInt(projectListResponse['database_port']);
  final databaseNames = <String>{};
  final databasesPayload = projectListResponse['databases'];
  if (databasesPayload is List) {
    for (final item in databasesPayload) {
      final databaseName = item is Map
          ? item['name']?.toString().trim()
          : item.toString().trim();
      if (databaseName == null || databaseName.isEmpty) {
        continue;
      }
      databaseNames.add(databaseName);
    }
  }
  final usersPayload = projectListResponse['users'];
  if (usersPayload is List) {
    for (final item in usersPayload.whereType<Map<dynamic, dynamic>>()) {
      final databaseName = item['database']?.toString().trim();
      final username = item['username']?.toString().trim();
      if (databaseName == null ||
          databaseName.isEmpty ||
          username == null ||
          username.isEmpty) {
        continue;
      }
      databaseNames.add(databaseName);
      final user = ProjectManagedDatabaseRepository.fromBackendUser(
        projectId: project.id,
        serverId: server.id,
        databaseName: databaseName,
        username: username,
        accessMode: item['access_mode']?.toString() ?? 'read_write',
        password:
            item['password']?.toString() ??
            item['database_password']?.toString(),
        host:
            item['host']?.toString() ??
            item['database_host']?.toString() ??
            responseHost,
        port:
            nullableInt(item['port']) ??
            nullableInt(item['database_port']) ??
            responsePort,
        connectionUri:
            item['connection_uri']?.toString() ??
            item['connectionUri']?.toString() ??
            item['database_url']?.toString(),
        observedAt: now,
      );
      if (user != null) {
        users.add(user);
      }
    }
  }
  for (final databaseName in databaseNames) {
    final databaseRecord = ProjectManagedDatabaseRepository.fromBackendDatabase(
      projectId: project.id,
      serverId: server.id,
      databaseName: databaseName,
      observedAt: now,
    );
    if (databaseRecord != null) {
      databases.add(databaseRecord);
    }
  }
  await ProjectManagedDatabaseRepository(database).replaceScope(
    projectId: project.id,
    serverId: server.id,
    databases: databases,
    users: users,
  );
}

int? nullableInt(Object? value) {
  if (value is int) {
    return value;
  }
  return int.tryParse(value?.toString().trim() ?? '');
}

Future<void> seedLogs(
  AppDatabase database, {
  required List<
    ({
      String renderedLine,
      String message,
      String source,
      String? taskType,
      DateTime createdAt,
    })
  >
  rows,
}) async {
  final repository = TerminalLogRepository(database);
  for (final row in rows) {
    await repository.appendLog(
      message: row.message,
      renderedLine: row.renderedLine,
      source: row.source,
      taskType: row.taskType,
      projectId: selectedProject.id,
      serverId: serverWithDatabaseEnabled.id,
      createdAt: row.createdAt,
    );
  }
}

Future<void> openDeploymentSettingsDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('deployment-edit-settings-button')));
  await tester.pumpAndSettle();
  expect(find.text('Review deployment settings'), findsOneWidget);
  final advancedSettings = find.text('Advanced settings');
  if (advancedSettings.evaluate().isNotEmpty) {
    await tester.tap(advancedSettings);
    await tester.pumpAndSettle();
  }
}

Future<void> openDeploymentRuntimeMenu(WidgetTester tester) async {
  final runtimeField = find.byKey(const Key('deploy-runtime-field'));
  await tester.ensureVisible(runtimeField);
  await tester.pumpAndSettle();
  await tester.tap(runtimeField);
  await tester.pumpAndSettle();
}

String textFieldValue(WidgetTester tester, Key key) {
  final field = tester.widget<Widget>(find.byKey(key));
  return switch (field) {
    AppTextFormField(:final controller) => controller?.text ?? '',
    AppPasswordFormField(:final controller) => controller?.text ?? '',
    AppNumberFormField(:final controller) => controller?.text ?? '',
    TextFormField(:final controller) => controller?.text ?? '',
    _ => '',
  };
}
