import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/backup_repository.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/scheduler_task_repository.dart';
import 'package:ui/data/local/server_credential_repository.dart';
import 'package:ui/models/result.dart';
import 'package:ui/providers/server_provider.dart';
import 'package:ui/providers/project_deletion_provider.dart';
import 'package:ui/services/ssh_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';
import '../_support/legacy_ssh_service.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectDeletionCoordinator', () {
    late AppDatabase database;
    late ProjectRepository projectRepository;
    late ProjectDeletionRecoveryRepository recoveryRepository;
    late BackupRepository backupRepository;
    late SchedulerTaskRepository schedulerRepository;
    late ServerCredentialRepository credentialRepository;
    late _ScriptedSshService sshService;
    late ProjectDeletionCoordinator coordinator;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      projectRepository = ProjectRepository(database);
      recoveryRepository = ProjectDeletionRecoveryRepository(database);
      backupRepository = BackupRepository(database);
      schedulerRepository = SchedulerTaskRepository(database);
      credentialRepository = ServerCredentialRepository(database);
      sshService = _ScriptedSshService();
      coordinator = ProjectDeletionCoordinator(
        recoveryRepository: recoveryRepository,
        projectRepository: projectRepository,
        backupRepository: backupRepository,
        schedulerRepository: schedulerRepository,
        credentialRepository: credentialRepository,
        sshService: sshService,
      );
      await credentialRepository.write(
        reference: _server.credentialReference,
        privateKey: 'private-key',
      );
      await projectRepository.createProject(_projectRecord);
    });

    tearDown(() async {
      sshService.dispose();
      await database.close();
    });

    test(
      'persists missing-server and missing-credential recovery failures',
      () async {
        final missingServer = await coordinator.start(
          project: _project,
          server: null,
        );
        expect(missingServer.completed, isFalse);
        expect(missingServer.messages.single, contains('not available'));
        expect(await projectRepository.listProjects(), isEmpty);
        expect(
          await projectRepository.readProject(
            _project.id,
            includePendingDeletion: true,
          ),
          isNotNull,
        );

        final missingCredentials = await coordinator.retry(
          recovery: (await recoveryRepository.getRecovery(_project.id))!,
          server: const Server(
            id: 'server-without-credentials',
            name: 'Server without credentials',
            host: '192.0.2.10',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
          ),
        );
        expect(missingCredentials.completed, isFalse);
        expect(missingCredentials.messages.single, contains('reconnected'));
        expect(sshService.calls, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'runs every saved cleanup step and preserves secrets outside recovery',
      () async {
        await backupRepository.upsertDestination(
          const BackupDestinationRecord(
            id: 'destination-1',
            projectId: 'project-1',
            serverId: 'server-1',
            name: 'B2',
            type: BackupDestinationType.s3,
            config: <String, dynamic>{
              'prefix': 'e2e/run',
              'access_key_id': 'key-id',
              'secret_access_key': 'secret-value',
              'region': 'eu-central-003',
              'endpoint': 's3.example.invalid',
              'force_path_style': true,
            },
          ),
        );
        await backupRepository.upsertPolicy(
          const BackupPolicyRecord(
            id: 'policy-1',
            projectId: 'project-1',
            serverId: 'server-1',
            name: 'Daily database',
            destinationId: 'destination-1',
            databaseName: 'dd_app',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'backup-task-1',
          ),
        );
        await schedulerRepository.upsertTask(
          const SchedulerTaskRecord(
            id: 'scheduler-1',
            projectId: 'project-1',
            name: 'Run queue',
            targetType: 'web_app',
            command: 'php artisan queue:work --once',
            scheduleType: 'every_minutes',
            intervalValue: 5,
          ),
        );
        await schedulerRepository.upsertTask(
          const SchedulerTaskRecord(
            id: 'managed-task',
            projectId: 'project-1',
            name: 'Managed backup',
            targetType: 'host',
            command: 'managed',
            scheduleType: 'daily_at',
            dailyTime: '02:00',
            managedByService: true,
          ),
        );

        sshService.queuedResponses['postgres/project_delete'] = [
          const <String, dynamic>{
            'status': 'success',
            'databases': <String>['example-app_dd_app'],
            'users': <String>['example-app_dd_app_user'],
          },
          const <String, dynamic>{'status': 'success'},
        ];

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );
        expect(outcome.completed, isTrue);
        expect(outcome.messages, isEmpty);
        expect(sshService.operations, <String>[
          'app/disconnect',
          'postgres/backup_policy_delete',
          'scheduler/task_delete',
          'postgres/project_delete',
          'postgres/project_delete',
        ]);

        final appSettings = sshService.settingsFor('app/disconnect');
        expect(appSettings['primary_domain'], 'app.example.com');
        expect(appSettings['tls_challenge_mode'], 'dns');
        expect(appSettings['tls_dns_provider'], 'cloudflare');
        expect(appSettings['app_subdirectory'], 'backend');

        final backupSettings = sshService.settingsFor(
          'postgres/backup_policy_delete',
        );
        expect(backupSettings['backup_aws_secret_access_key'], 'secret-value');
        // host_port is backend-resolved; the wire must not carry it at all.
        final projectDeleteSettings = sshService.settingsFor(
          'postgres/project_delete',
        );
        expect(projectDeleteSettings.containsKey('host_port'), isFalse);
        final recovery = (await recoveryRepository.getRecovery('project-1'))!;
        expect(
          recovery.steps.every((step) => step.status.name == 'success'),
          isTrue,
        );
        expect(recovery.toString(), isNot(contains('secret-value')));
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete dry-runs, then executes with confirmed lists',
      () async {
        sshService.queuedResponses['postgres/project_delete'] = [
          <String, dynamic>{
            'status': 'success',
            'databases': ['example-app_dd_app'],
            'users': ['example-app_dd_app_user'],
          },
          const <String, dynamic>{'status': 'success'},
        ];

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isTrue);
        final deleteCalls = _projectDeleteCalls(sshService);
        expect(deleteCalls, hasLength(2));
        final dryRunParams = deleteCalls[0]['params'] as Map<String, dynamic>;
        expect(dryRunParams['dry_run'], isTrue);
        expect(
          (dryRunParams['settings'] as Map<String, dynamic>).containsKey(
            'confirmed_databases',
          ),
          isFalse,
        );
        final executeParams = deleteCalls[1]['params'] as Map<String, dynamic>;
        expect(executeParams['dry_run'], isFalse);
        final executeSettings =
            executeParams['settings'] as Map<String, dynamic>;
        expect(executeSettings['confirmed_databases'], ['example-app_dd_app']);
        expect(executeSettings['confirmed_users'], ['example-app_dd_app_user']);
        expect(executeSettings['project_slug'], 'example-app');
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete confirms empty plans as empty lists',
      () async {
        sshService.queuedResponses['postgres/project_delete'] = [
          const <String, dynamic>{
            'status': 'success',
            'databases': <String>[],
            'users': <String>[],
          },
          const <String, dynamic>{'status': 'success'},
        ];

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isTrue);
        final executeParams =
            _projectDeleteCalls(sshService).last['params']
                as Map<String, dynamic>;
        expect(executeParams['dry_run'], isFalse);
        final executeSettings =
            executeParams['settings'] as Map<String, dynamic>;
        expect(executeSettings['confirmed_databases'], isEmpty);
        expect(executeSettings['confirmed_users'], isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete surfaces a drift refusal as a failed step',
      () async {
        sshService.queuedResponses['postgres/project_delete'] = [
          <String, dynamic>{
            'status': 'success',
            'databases': ['example-app_dd_app'],
            'users': ['example-app_dd_app_user'],
          },
          <String, dynamic>{
            'status': 'error',
            'msg':
                'The confirmed delete list no longer matches the registry. '
                'Review the current databases and users, then confirm again.',
          },
        ];

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isFalse);
        expect(outcome.messages.join(' '), contains('no longer matches'));
        final recovery = (await recoveryRepository.getRecovery('project-1'))!;
        final deleteStep = recovery.steps.firstWhere(
          (step) => step.id == 'postgres_project',
        );
        expect(deleteStep.status, ProjectDeletionStepStatus.failed);
        expect(_projectDeleteCalls(sshService), hasLength(2));
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete does not execute when its dry run fails',
      () async {
        sshService.responses['postgres/project_delete'] = <String, dynamic>{
          'status': 'error',
          'msg': 'Could not inspect project databases.',
        };

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isFalse);
        expect(
          outcome.messages.join(' '),
          contains('Could not inspect project databases.'),
        );
        final deleteCalls = _projectDeleteCalls(sshService);
        expect(deleteCalls, hasLength(1));
        expect(
          (deleteCalls.single['params'] as Map<String, dynamic>)['dry_run'],
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete does not execute on a plan without lists',
      () async {
        sshService.responses['postgres/project_delete'] =
            const <String, dynamic>{'status': 'success'};

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isFalse);
        expect(
          outcome.messages.join(' '),
          contains('confirmation list was unavailable'),
        );
        expect(_projectDeleteCalls(sshService), hasLength(1));
      },
      skip: !sqliteAvailable,
    );

    test(
      'postgres project delete does not execute on non-string plan entries',
      () async {
        sshService.responses['postgres/project_delete'] = <String, dynamic>{
          'status': 'success',
          'databases': ['example-app_dd_app'],
          'users': [7],
        };

        final outcome = await coordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isFalse);
        expect(
          outcome.messages.join(' '),
          contains('confirmation list was unavailable'),
        );
        expect(_projectDeleteCalls(sshService), hasLength(1));
      },
      skip: !sqliteAvailable,
    );

    test(
      'persists local catalog loading failures for explicit retry',
      () async {
        sshService.queuedResponses['postgres/project_delete'] = [
          const <String, dynamic>{
            'status': 'success',
            'databases': <String>['example-app_dd_app'],
            'users': <String>['example-app_dd_app_user'],
          },
          const <String, dynamic>{'status': 'success'},
        ];
        final failingCoordinator = ProjectDeletionCoordinator(
          recoveryRepository: recoveryRepository,
          projectRepository: projectRepository,
          backupRepository: _ThrowingBackupRepository(database),
          schedulerRepository: _ThrowingSchedulerRepository(database),
          credentialRepository: credentialRepository,
          sshService: sshService,
        );

        final outcome = await failingCoordinator.start(
          project: _project,
          server: _server,
        );

        expect(outcome.completed, isFalse);
        expect(outcome.messages, hasLength(2));
        expect(outcome.messages.join(' '), contains('backup catalog failed'));
        expect(
          outcome.messages.join(' '),
          contains('scheduler catalog failed'),
        );
        final recovery = (await recoveryRepository.getRecovery('project-1'))!;
        expect(recovery.needsAttention, isTrue);
        expect(
          recovery.steps
              .where((step) => step.status == ProjectDeletionStepStatus.failed)
              .map((step) => step.id),
          <String>['load_backup_plans', 'load_scheduler_tasks'],
        );
      },
      skip: !sqliteAvailable,
    );

    test('a step whose call raises is recorded as failed, sanitized', () async {
      // The other half of `throwOperations`. A workflow reporting an error
      // returns an `Err`; the transport dying mid-call raises, and that is
      // the only path to the coordinator's per-step `catch`. Deletion is
      // destructive and partly irreversible, so a step that blew up has to
      // land in the recovery record as failed rather than vanish.
      sshService.raiseOperations.add('app/disconnect');

      final result = await coordinator.start(
        project: _project,
        server: _server,
      );

      expect(result.completed, isFalse);
      final joined = result.messages.join(' ');
      expect(joined, contains('connection dropped'));
      // Sanitized on the way in, like every other persisted message: the
      // recovery record outlives the session that wrote it.
      expect(joined, isNot(contains('raise-secret')));
      expect(joined, contains('secret=***'));

      final recovery = await recoveryRepository.getRecovery('project-1');
      expect(recovery, isNotNull);
      expect(
        recovery!.steps.any(
          (step) => step.status == ProjectDeletionStepStatus.failed,
        ),
        isTrue,
      );
    });

    test(
      'retry reruns failed steps only and sanitizes persisted errors',
      () async {
        // A step that succeeds on the first attempt, so the retry proves it
        // skips successful steps instead of rerunning the whole sequence.
        await schedulerRepository.upsertTask(
          const SchedulerTaskRecord(
            id: 'scheduler-1',
            projectId: 'project-1',
            name: 'Run queue',
            targetType: 'web_app',
            command: 'php artisan queue:work --once',
            scheduleType: 'every_minutes',
            intervalValue: 5,
          ),
        );
        sshService.responses['app/disconnect'] = <String, dynamic>{
          'status': 'error',
          'msg': 'password=super-secret deploy failed',
        };
        sshService.throwOperations.add('postgres/project_delete');

        final failed = await coordinator.start(
          project: _project.copyWithForTest(primaryDomain: 'not-a-domain'),
          server: _server,
        );
        expect(failed.completed, isFalse);
        expect(failed.messages.join(' '), isNot(contains('super-secret')));
        expect(failed.messages.join(' '), contains('password=***'));
        expect(
          sshService.settingsFor('app/disconnect')['primary_domain'],
          'app.example.com',
        );

        sshService.responses['app/disconnect'] = const <String, dynamic>{
          'status': 'success',
        };
        sshService.throwOperations.clear();
        sshService.queuedResponses['postgres/project_delete'] = [
          const <String, dynamic>{
            'status': 'success',
            'databases': <String>['example-app_dd_app'],
            'users': <String>['example-app_dd_app_user'],
          },
          const <String, dynamic>{'status': 'success'},
        ];
        final beforeRetry = Map<String, int>.from(sshService.counts);
        final retry = await coordinator.retry(
          recovery: (await recoveryRepository.getRecovery('project-1'))!,
          server: _server,
        );
        expect(retry.completed, isTrue);
        // The scheduler step ran on the first attempt, so the retry below
        // proves the skip rather than comparing two nulls.
        expect(beforeRetry['scheduler/task_delete'], 1);
        expect(
          sshService.counts['app/disconnect'],
          beforeRetry['app/disconnect']! + 1,
        );
        expect(
          sshService.counts['postgres/project_delete'],
          beforeRetry['postgres/project_delete']! + 2,
        );
        expect(
          sshService.counts['scheduler/task_delete'],
          beforeRetry['scheduler/task_delete'],
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'retry removes orphan recovery when project is already absent',
      () async {
        final recovery = await recoveryRepository.startRecovery(
          projectId: 'orphan',
          serverId: 'server-1',
          projectName: 'Orphan',
          projectSlug: 'orphan',
        );
        final outcome = await coordinator.retry(
          recovery: recovery,
          server: _server,
        );
        expect(outcome.completed, isTrue);
        expect(outcome.projectName, 'Orphan');
        expect(await recoveryRepository.getRecovery('orphan'), isNull);
      },
      skip: !sqliteAvailable,
    );

    test('provider constructs coordinator from repository dependencies', () {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      addTearDown(container.dispose);
      expect(
        container.read(projectDeletionCoordinatorProvider),
        isA<ProjectDeletionCoordinator>(),
      );
    }, skip: !sqliteAvailable);
  });
}

const Project _project = Project(
  id: 'project-1',
  serverId: 'server-1',
  name: 'Example App',
  type: 'Web app',
  gitUrl: 'git@github.com:deploydash/laravel-example-app.git',
  primaryDomain: 'app.example.com',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'backend',
  deployBranch: 'main',
  appPort: 8080,
  railpackBuildCommand: '',
  railpackRunCommand: '',
  railpackNodeMode: 'auto',
  tlsChallengeMode: 'dns',
  tlsDnsProvider: 'cloudflare',
  tlsDnsCredentials: <String, String>{'api_token': 'dns-secret'},
  isActive: true,
);

const Project _projectRecord = Project(
  id: 'project-1',
  serverId: 'server-1',
  name: 'Example App',
  type: 'Web app',
  gitUrl: 'git@github.com:deploydash/laravel-example-app.git',
  primaryDomain: 'app.example.com',
  repositoryFullName: 'deploydash/laravel-example-app',
  appSubdirectory: 'backend',
  deployBranch: 'main',
  appPort: 8080,
  railpackBuildCommand: '',
  railpackRunCommand: '',
  railpackNodeMode: 'auto',
  tlsChallengeMode: 'dns',
  tlsDnsProvider: 'cloudflare',
  tlsDnsCredentials: <String, String>{'api_token': 'dns-secret'},
  isActive: true,
);

const Server _server = Server(
  id: 'server-1',
  name: 'Server',
  host: '192.0.2.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.sshKey,
  serviceDatabaseEnabled: true,
  postgresConfig: ServerPostgresConfig(
    postgresVersion: '17',
    superuserPassword: 'postgres-secret',
    enabledExtensions: <String>['pgvector'],
  ),
);

extension on Project {
  Project copyWithForTest({String? primaryDomain}) {
    return Project(
      id: id,
      serverId: serverId,
      name: name,
      type: type,
      gitUrl: gitUrl,
      primaryDomain: primaryDomain ?? this.primaryDomain,
      repositoryFullName: repositoryFullName,
      appSubdirectory: appSubdirectory,
      deployBranch: deployBranch,
      appPort: appPort,
      railpackBuildCommand: railpackBuildCommand,
      railpackRunCommand: railpackRunCommand,
      railpackNodeMode: railpackNodeMode,
      tlsChallengeMode: tlsChallengeMode,
      tlsDnsProvider: tlsDnsProvider,
      tlsDnsCredentials: tlsDnsCredentials,
      isActive: isActive,
    );
  }
}

/// The recorded `postgres/project_delete` calls in order.
///
/// The coordinator dry-runs the delete before executing it, so one step
/// produces two calls; tests tell them apart through `params['dry_run']`.
List<Map<String, dynamic>> _projectDeleteCalls(_ScriptedSshService ssh) {
  return ssh.calls
      .where(
        (call) =>
            '${call['workflow_id']}/${call['operation_id']}' ==
            'postgres/project_delete',
      )
      .toList(growable: false);
}

class _ScriptedSshService extends LegacySshService {
  _ScriptedSshService() : super(taskClient: _NoopTaskClient());

  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> responses =
      <String, Map<String, dynamic>>{};
  final Map<String, List<Map<String, dynamic>>> queuedResponses =
      <String, List<Map<String, dynamic>>>{};
  final Set<String> throwOperations = <String>{};

  /// Operations whose call raises instead of returning an `Err`.
  ///
  /// Distinct from [throwOperations], which models the ordinary remote
  /// failure: a workflow that reports an error still returns a Result. This
  /// models the transport itself failing mid-call, which is the only way to
  /// reach the coordinator's `catch` around each step.
  final Set<String> raiseOperations = <String>{};
  final Map<String, int> counts = <String, int>{};

  List<String> get operations => calls
      .map((call) => '${call['workflow_id']}/${call['operation_id']}')
      .toList(growable: false);

  Map<String, dynamic> settingsFor(String operation) {
    final call = calls.lastWhere(
      (entry) =>
          '${entry['workflow_id']}/${entry['operation_id']}' == operation,
    );
    final params = call['params'] as Map<String, dynamic>;
    return Map<String, dynamic>.from(
      params['settings'] as Map<String, dynamic>,
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
    final operation = '$workflowId/$operationId';
    calls.add(<String, dynamic>{
      'workflow_id': workflowId,
      'operation_id': operationId,
      'connection': connection,
      'params': params,
    });
    counts[operation] = (counts[operation] ?? 0) + 1;
    if (raiseOperations.contains(operation)) {
      throw StateError('secret=raise-secret connection dropped');
    }
    if (throwOperations.contains(operation)) {
      return Err<Map<String, dynamic>>(
        UnexpectedFailure(StateError('secret=throw-secret remote unavailable')),
      );
    }
    final queue = queuedResponses[operation];
    if (queue != null && queue.isNotEmpty) {
      return Ok<Map<String, dynamic>>(queue.removeAt(0));
    }
    return Ok<Map<String, dynamic>>(
      responses[operation] ?? const <String, dynamic>{'status': 'success'},
    );
  }
}

class _ThrowingBackupRepository extends BackupRepository {
  const _ThrowingBackupRepository(super.database);

  @override
  Future<List<BackupDestinationRecord>> listDestinationsForScope({
    required String projectId,
    required String serverId,
  }) {
    return Future<List<BackupDestinationRecord>>.error(
      StateError('backup catalog failed'),
    );
  }
}

class _ThrowingSchedulerRepository extends SchedulerTaskRepository {
  const _ThrowingSchedulerRepository(super.database);

  @override
  Future<List<SchedulerTaskRecord>> listTasksForProject(String projectId) {
    return Future<List<SchedulerTaskRecord>>.error(
      StateError('scheduler catalog failed'),
    );
  }
}

class _NoopTaskClient implements EngineTaskClient {
  @override
  String cancelTask(int taskId) => '{}';

  @override
  String getRecentTaskHistory({int limit = 50}) => '[]';

  @override
  String getTaskResult(int taskId) => '{}';

  @override
  String pollTaskEvents(int taskId, {int maxEvents = 100}) => '[]';

  @override
  String startTask(String jsonPayload) => '1';
}
