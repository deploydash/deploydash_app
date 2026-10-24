import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace workers runtime.
///
/// One of sixteen files T-3.6.1 split `project_workspace_test.dart` into. That
/// file was 16,030 lines holding 230 tests in two groups: a directory's worth
/// of tests wearing a filename, which nobody could hold in view, so a coverage
/// gap in it was invisible by construction.
///
/// Fixtures and pump helpers live in
/// `_support/project_workspace_harness.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace workers runtime', () {
    testWidgets('Workers tab applies runtime with worker payload', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await WorkerInstanceRepository(database).replaceForProject(
        projectId: selectedProject.id,
        rows: [
          WorkerInstanceRecord(
            id: 'queue-worker',
            projectId: selectedProject.id,
            name: 'Queue worker',
            startCommand: 'npm run worker:queue',
            cpuLimit: 2.0,
            memoryMb: 1024,
            diskMb: 4096,
            databaseUser: 'app_rw',
            databaseName: 'app_db',
            databasePassword: 'secret-123',
            enabled: true,
            sortOrder: 0,
          ),
        ],
      );

      final sshService = WorkersWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'users': <dynamic>[],
        },
        statusResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {
            'configured': [
              {
                'id': 'queue-worker',
                'runtime': {'state': 'not_created', 'status': 'Not created'},
              },
            ],
            'orphans': <dynamic>[],
          },
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'msg': 'Workers applied.',
          'workers': {
            'configured': [
              {
                'id': 'queue-worker',
                'runtime': {
                  'state': 'running',
                  'status': 'Up 5s',
                  'stats': {
                    'cpu_perc': '0.60%',
                    'mem_usage': '32MiB / 1024MiB',
                  },
                },
              },
            ],
            'orphans': <dynamic>[],
          },
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithLiveRuntime,
          ),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('worker-row-queue-worker')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
      await tester.pumpAndSettle();

      expect(sshService.applyCalls, 1);
      final params = sshService.lastApplyParams;
      expect(params, isNotNull);
      final settings = params!['settings'];
      expect(settings, isA<Map<String, dynamic>>());
      final workers = (settings as Map<String, dynamic>)['workers'];
      expect(workers, isA<List<dynamic>>());
      expect((workers as List<dynamic>), hasLength(1));
      final payload = workers.first as Map<String, dynamic>;
      expect(payload['id'], 'queue-worker');
      expect(payload['cpu_limit'], 2.0);
      expect(payload['memory_mb'], 1024);
      expect(payload['disk_mb'], 4096);
      expect(payload['database_user'], 'app_rw');
      expect(payload['database_name'], 'app_db');
      expect(payload['database_password'], 'secret-123');
      expect(payload['database_host'], 'host.docker.internal');
      expect(payload['database_port'], 5432);

      final row = find.byKey(const Key('worker-row-queue-worker'));
      expect(
        find.descendant(of: row, matching: find.text('running')),
        findsOne,
      );
      expect(find.descendant(of: row, matching: find.text('Up 5s')), findsOne);
      expect(
        find.byKey(const Key('workers-apply-runtime-button')),
        findsNothing,
      );
    });

    testWidgets(
      'Workers tab applies runtime with injected postgres DATABASE_URL',
      (WidgetTester tester) async {
        final project = selectedProjectWithLiveRuntime.copyWith(
          injectPostgresEnv: true,
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: project.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: project.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 2.0,
              memoryMb: 1024,
              diskMb: 4096,
              enabled: true,
              sortOrder: 0,
            ),
          ],
        );
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: project.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'APP_KEY',
              value: 'abc',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_HOST',
              value: 'deploydash_postgres',
              secret: true,
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PORT',
              value: '5432',
              secret: true,
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'app_db',
              secret: true,
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'app_user',
              secret: true,
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'secret-123',
              secret: true,
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_URL',
              value:
                  'postgresql://app_user:secret-123@deploydash_postgres:5432/app_db',
              secret: true,
            ),
          ],
        );

        final sshService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'not_created', 'status': 'Not created'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'msg': 'Workers applied.',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'running', 'status': 'Running'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(project),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
        await tester.pumpAndSettle();

        final settings =
            (sshService.lastApplyParams?['settings'] as Map<String, dynamic>?)!;
        final runtimeEnv = (settings['runtime_env'] as Map?)!
            .cast<String, dynamic>();
        expect(runtimeEnv['APP_KEY'], 'abc');
        expect(runtimeEnv['DATABASE_HOST'], 'deploydash_postgres');
        expect(runtimeEnv['DATABASE_PORT'], '5432');
        expect(runtimeEnv['DATABASE_NAME'], 'app_db');
        expect(runtimeEnv['DATABASE_USER'], 'app_user');
        expect(runtimeEnv['DATABASE_PASSWORD'], 'secret-123');
        expect(
          runtimeEnv['DATABASE_URL'],
          'postgresql://app_user:secret-123@deploydash_postgres:5432/app_db',
        );
      },
    );

    testWidgets(
      'Workers tab row actions call start stop restart and logs refresh',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: selectedProject.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 0,
            ),
            WorkerInstanceRecord(
              id: 'email-worker',
              projectId: selectedProject.id,
              name: 'Email worker',
              startCommand: 'npm run worker:email',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 1,
            ),
          ],
        );

        final sshService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'not_created', 'status': 'Not created'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          workerOperationResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'running', 'status': 'Up 2s'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
          workerLogsResponse: const <String, dynamic>{
            'status': 'success',
            'logs': ['booting worker', 'worker ready'],
          },
        );

        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(initialTabIndex: 8),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();

        final row = find.byKey(const Key('worker-row-queue-worker'));
        expect(row, findsOneWidget);

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Start worker')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(sshService.workerStartCalls, 1);
        expect(
          sshService.lastWorkerOperationParams?['worker_id'],
          'queue-worker',
        );

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Stop worker')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(sshService.workerStopCalls, 1);

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Restart worker')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(sshService.workerRestartCalls, 1);

        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byTooltip('View worker activity'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(sshService.workerLogsCalls, 1);
        expect(
          find.byKey(const Key('workers-logs-refresh-button')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('workers-logs-refresh-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(sshService.workerLogsCalls, 2);

        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Workers logs dialog shows an empty state before output exists',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: selectedProject.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 0,
            ),
          ],
        );

        final sshService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'running', 'status': 'healthy'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          workerLogsResponse: const <String, dynamic>{
            'status': 'success',
            'logs': <dynamic>[],
          },
        );

        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(initialTabIndex: 8),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('View worker activity'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.text('No log lines are available yet.'), findsOneWidget);
      },
    );

    testWidgets('Workers tab does not auto-refresh when opened initially', (
      WidgetTester tester,
    ) async {
      final sshService = WorkersWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'users': <dynamic>[],
        },
        statusResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
      );

      await pumpProjectWorkspace(
        tester,
        child: const ProjectWorkspace(initialTabIndex: 1),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      expect(find.byKey(const Key('workers-overview-card')), findsOneWidget);
      expect(sshService.projectListCalls, 0);
      expect(sshService.statusCalls, 0);
    });

    testWidgets(
      'Workers tab surfaces worker status failure responses during refresh',
      (WidgetTester tester) async {
        final failingService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          operationOutcomesByKey: <String, List<Object>>{
            'app/workers_status': <Object>[
              const <String, dynamic>{
                'status': 'error',
                'msg': 'status failed',
                'details': 'inspect error',
              },
            ],
          },
        );

        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(failingService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('workers-refresh-status-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('status failed\ninspect error'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Workers tab surfaces worker status exceptions during refresh',
      (WidgetTester tester) async {
        final explodingService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          operationOutcomesByKey: <String, List<Object>>{
            'app/workers_status': <Object>[StateError('status exploded')],
          },
        );

        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(explodingService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('workers-refresh-status-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Couldn’t load worker status.\nBad state: status exploded',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Workers tab apply runtime surfaces backend details', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      await WorkerInstanceRepository(database).replaceForProject(
        projectId: selectedProjectWithLiveRuntime.id,
        rows: [
          WorkerInstanceRecord(
            id: 'queue-worker',
            projectId: selectedProjectWithLiveRuntime.id,
            name: 'Queue worker',
            startCommand: 'npm run worker:queue',
            cpuLimit: 1.0,
            memoryMb: 512,
            diskMb: 2048,
            enabled: true,
            sortOrder: 0,
          ),
        ],
      );
      final sshService = WorkersWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'users': <dynamic>[],
        },
        statusResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
        operationOutcomesByKey: <String, List<Object>>{
          'app/workers_apply': <Object>[
            const <String, dynamic>{
              'status': 'error',
              'msg': 'apply failed',
              'details': 'missing image',
            },
          ],
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithLiveRuntime,
          ),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('apply failed\nmissing image'), findsOne);
    });

    testWidgets(
      'Workers tab apply runtime surfaces missing credentials and thrown exceptions',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: selectedProject.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 0,
            ),
          ],
        );

        final missingCredsService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(
              serverWithServicesDisabled,
            ),
            sshServiceProvider.overrideWithValue(missingCredsService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('This server connection needs to be reconnected'),
          findsWidgets,
        );

        final explodingService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          operationOutcomesByKey: <String, List<Object>>{
            'app/workers_apply': <Object>[StateError('apply exploded')],
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(explodingService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'Couldn’t update the worker runtime.\nBad state: apply exploded',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Workers tab operations and logs cover credential guards, errors, fallback success, and exceptions',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: selectedProject.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 0,
            ),
          ],
        );

        final sshService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {
              'configured': [
                {
                  'id': 'queue-worker',
                  'runtime': {'state': 'not_created', 'status': 'Not created'},
                },
              ],
              'orphans': <dynamic>[],
            },
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          workerOperationResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          workerLogsResponse: const <String, dynamic>{
            'status': 'success',
            'logs': ['boot complete'],
          },
          operationOutcomesByKey: <String, List<Object>>{
            'app/worker_start': <Object>[
              const <String, dynamic>{
                'status': 'error',
                'msg': 'worker start failed',
                'details': 'container create failed',
              },
              const <String, dynamic>{
                'status': 'success',
                'msg': '',
                'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
              },
              StateError('worker start exploded'),
            ],
            'app/worker_logs': <Object>[
              const <String, dynamic>{
                'status': 'error',
                'msg': 'log read failed',
                'details': 'docker logs timeout',
              },
              StateError('log transport failed'),
              const <String, dynamic>{
                'status': 'success',
                'logs': ['boot complete'],
              },
              const <String, dynamic>{
                'status': 'error',
                'msg': 'refresh failed',
                'details': 'tail command failed',
              },
            ],
            'app/worker_stop': <Object>[
              const <String, dynamic>{
                'status': 'success',
                'msg': '',
                'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
              },
            ],
          },
          operationDelaysByKey: const <String, Duration>{
            'app/worker_logs': Duration(milliseconds: 80),
          },
        );

        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(initialTabIndex: 8),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithRuntimeCredentials,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();

        final row = find.byKey(const Key('worker-row-queue-worker'));
        expect(row, findsOneWidget);

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Start worker')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('worker start failed\ncontainer create failed'),
          findsOneWidget,
        );

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Start worker')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Worker started.'), findsOneWidget);

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Start worker')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Couldn’t update this worker.'), findsOne);

        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byTooltip('View worker activity'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('log read failed\ndocker logs timeout'),
          findsOne,
        );

        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byTooltip('View worker activity'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Couldn’t load worker activity.'), findsOne);

        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byTooltip('View worker activity'),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byKey(const Key('workers-logs-refresh-button')), findsOne);

        await tester.tap(find.byKey(const Key('workers-logs-refresh-button')));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsWidgets);
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        expect(
          find.textContaining('refresh failed\ntail command failed'),
          findsOne,
        );
        await tester.tap(find.widgetWithText(TextButton, 'Close'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'Workers tab operation guards show credential error when server auth is incomplete',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: [
            WorkerInstanceRecord(
              id: 'queue-worker',
              projectId: selectedProject.id,
              name: 'Queue worker',
              startCommand: 'npm run worker:queue',
              cpuLimit: 1.0,
              memoryMb: 512,
              diskMb: 2048,
              enabled: true,
              sortOrder: 0,
            ),
          ],
        );

        final sshService = WorkersWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'users': <dynamic>[],
          },
          statusResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
          applyResponse: const <String, dynamic>{
            'status': 'success',
            'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
          },
        );

        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(initialTabIndex: 8),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(
              serverWithServicesDisabled,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('workers-refresh-status-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('This server connection needs to be reconnected'),
          findsOneWidget,
        );
        final row = find.byKey(const Key('worker-row-queue-worker'));

        await tester.tap(
          find.descendant(of: row, matching: find.byTooltip('Start worker')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('This server connection needs to be reconnected'),
          findsWidgets,
        );

        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byTooltip('View worker activity'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('This server connection needs to be reconnected'),
          findsWidgets,
        );
      },
    );

    testWidgets('Workers tab logs operation catches settings build failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await WorkerInstanceRepository(database).replaceForProject(
        projectId: selectedProject.id,
        rows: [
          WorkerInstanceRecord(
            id: 'queue-worker',
            projectId: selectedProject.id,
            name: 'Queue worker',
            startCommand: 'npm run worker:queue',
            cpuLimit: 1.0,
            memoryMb: 512,
            diskMb: 2048,
            enabled: true,
            sortOrder: 0,
          ),
        ],
      );

      final sshService = WorkersWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'users': <dynamic>[],
        },
        statusResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
      );
      final throwingRepo = ThrowingAppEnvironmentVariableRepository(
        throwOnList: false,
        throwOnReplace: false,
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
          appEnvironmentVariableRepositoryProvider.overrideWithValue(
            throwingRepo,
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      throwingRepo.throwOnList = true;
      await tester.tap(find.byTooltip('View worker activity'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn’t load worker activity.'), findsOne);
    });

    testWidgets('Workers tab shows orphan worker containers', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await WorkerInstanceRepository(database).replaceForProject(
        projectId: selectedProject.id,
        rows: [
          WorkerInstanceRecord(
            id: 'queue-worker',
            projectId: selectedProject.id,
            name: 'Queue worker',
            startCommand: 'npm run worker:queue',
            cpuLimit: 1.0,
            memoryMb: 512,
            diskMb: 2048,
            enabled: true,
            sortOrder: 0,
          ),
        ],
      );
      final sshService = WorkersWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'users': <dynamic>[],
        },
        statusResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {
            'configured': <dynamic>[],
            'orphans': [
              {'container_name': 'deploydash_orphan_a'},
              {'container_name': 'deploydash_orphan_b'},
            ],
          },
        },
        applyResponse: const <String, dynamic>{
          'status': 'success',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workers-refresh-status-button')));
      await tester.pumpAndSettle();

      expect(find.text('Orphan worker containers'), findsOneWidget);
      expect(find.text('deploydash_orphan_a'), findsOneWidget);
      expect(find.text('deploydash_orphan_b'), findsOneWidget);
    });
  }, skip: !sqliteAvailable);
}
