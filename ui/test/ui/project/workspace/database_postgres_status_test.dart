import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// Forces local catalog reads to fail so status refresh proves its fallback.
class _ThrowingManagedDatabaseCatalog extends ProjectManagedDatabaseRepository {
  /// Creates the failure seam over the same database used by the workspace.
  _ThrowingManagedDatabaseCatalog(super.database);

  /// Models an unreadable local expectation catalog without disabling writes.
  @override
  Future<List<ProjectManagedDatabaseRecord>> listDatabasesForScope({
    required String projectId,
    required String serverId,
    String engine = 'postgres',
  }) async {
    throw StateError('local catalog unavailable');
  }
}

/// project workspace PostgreSQL service status.
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

  group('project workspace PostgreSQL service status', () {
    testWidgets('Database tab shows configure CTA when service is disabled', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
      await tester.pumpAndSettle();

      expect(
        find.text('Database service is disabled for this server.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('database-open-server-services-button')),
        findsOneWidget,
      );
    });

    testWidgets('Database tab shows loading while PostgreSQL catalog loads', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final managedRepository = DelayedProjectManagedDatabaseRepository(
        database,
      );
      final serverCatalog = MutableServerCatalogNotifier(
        ServerCatalogState(
          isLoading: false,
          onboardingComplete: true,
          servers: [serverWithDatabaseEnabled],
          selectedServerId: serverWithDatabaseEnabled.id,
          onboardingStep: 'connected',
        ),
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          serverCatalogProvider.overrideWith(() => serverCatalog),
          projectManagedDatabaseRepositoryProvider.overrideWithValue(
            managedRepository,
          ),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      managedRepository.delayNextDatabaseLoad = true;
      serverCatalog.setSelectedServer(
        serverWithUpdatedAt(
          serverWithDatabaseEnabled,
          DateTime.utc(2026, 9, 1),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(managedRepository.databaseLoadStarted.isCompleted, isTrue);

      expect(find.byKey(const Key('database-tab-scroll')), findsOneWidget);

      expect(find.byKey(const Key('database-managed-loading-card')), findsOne);
      expect(find.text('Loading PostgreSQL status...'), findsOneWidget);

      managedRepository.releaseDatabaseLoad.complete();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Database tab refreshes without expectations when local catalog fails',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final managedRepository = _ThrowingManagedDatabaseCatalog(database);
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>[],
            'users': <Map<String, dynamic>>[],
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            projectManagedDatabaseRepositoryProvider.overrideWithValue(
              managedRepository,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
        await tester.pumpAndSettle();

        final projectListCall = sshService.callLog.singleWhere(
          (call) => call['operation_id'] == 'project_list',
        );
        final params = projectListCall['params']! as Map<String, dynamic>;
        final settings = params['settings']! as Map<String, dynamic>;
        expect(settings['expected_databases'], isEmpty);
        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(
          find.textContaining('local catalog unavailable'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Database tab preserves storage status on failed list', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Could not inspect project databases.',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
            'storage_error': 'Detached data volume: expected database missing.',
          },
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      expect(find.text('Could not inspect project databases.'), findsOneWidget);
    });

    testWidgets(
      'Database tab shows setup guidance when service is unconfigured',
      (WidgetTester tester) async {
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': false,
              'running': false,
            },
            'databases': <String>[],
            'users': <Map<String, dynamic>>[],
          },
        );
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
        await tester.pumpAndSettle();

        expect(
          find.text('PostgreSQL service is not configured yet.'),
          findsOneWidget,
        );
        expect(
          find.text(
            'Finish PostgreSQL setup in Server Management, then return to this tab.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Database tab shows stopped guidance when service is down', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': false,
          },
          'databases': <String>[],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Stopped'), findsWidgets);
      expect(find.text('PostgreSQL 17'), findsOneWidget);
    });

    testWidgets('Database tab shows unhealthy service status', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
            'health': 'unhealthy',
            'container_status': <String, dynamic>{
              'present': true,
              'docker_state': 'running',
              'running': true,
              'health': 'unhealthy',
              'exit_code': 0,
              'image': 'deploydash/postgres-ext:17.10-bookworm-vector',
              'started_at': '2026-07-01T12:00:00Z',
              'effective_status': 'unhealthy',
              'readiness': <String, dynamic>{
                'status': 'unhealthy',
                'detail': 'pg_isready failed',
              },
            },
          },
          'databases': <String>[],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Unhealthy'), findsWidgets);
      expect(find.text('Healthy'), findsNothing);
    });

    testWidgets('Database tab surfaces detached storage and recovery link', (
      WidgetTester tester,
    ) async {
      const storageError =
          'Detached data volume: none of the 1 databases Deploy Dash expects '
          'are present (dd_test_app); the data volume may be detached. List '
          'candidates with dangling=true before removing anything.';
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
            'health': 'unhealthy',
            'missing_expected_databases': <String>['dd_test_app'],
            'storage_error': storageError,
            'detached_storage_volumes': <String>['c' * 64],
            'container_status': <String, dynamic>{
              'present': true,
              'docker_state': 'running',
              'running': true,
              'health': 'unhealthy',
              'effective_status': 'unhealthy',
              'readiness': <String, dynamic>{
                'status': 'unhealthy',
                'detail': storageError,
              },
            },
          },
          'databases': <String>[],
          'users': <Map<String, dynamic>>[],
        },
      );
      registerManagedPostgresCatalogSeed(const <String, dynamic>{
        'databases': <String>['dd_test_app'],
        'users': <Map<String, dynamic>>[],
      });
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Data volume may be detached'), findsOneWidget);
      expect(find.text(storageError), findsOneWidget);
      expect(
        find.byKey(const Key('database-open-server-services-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('database-actions-card')), findsNothing);
      final projectListCall = sshService.callLog.lastWhere(
        (call) => call['operation_id'] == 'project_list',
      );
      final params = projectListCall['params']! as Map<String, dynamic>;
      final settings = params['settings']! as Map<String, dynamic>;
      expect(settings['expected_databases'], <String>['dd_test_app']);
    });

    testWidgets('Database tab shows missing container status', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': false,
            'container_status': <String, dynamic>{
              'present': false,
              'docker_state': 'missing',
              'running': false,
              'health': 'unknown',
              'effective_status': 'missing',
            },
          },
          'databases': <String>[],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Not found'), findsWidgets);
    });

    testWidgets('Database tab shows container-safe PostgreSQL host details', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'host': '10.9.0.8',
          'port': 6543,
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'alpha_user',
              'database': 'alpha_db',
              'access_mode': 'read_write',
            },
          ],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      final connectionCard = find.byKey(const Key('database-connection-card'));
      expect(
        find.descendant(
          of: connectionCard,
          matching: find.text('host.docker.internal'),
        ),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: connectionCard, matching: find.text('6543')),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('Database tab uses segmented tabs for SQLite and PostgreSQL', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
      );
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      final tabsCard = find.byKey(const Key('database-type-tabs-card'));
      expect(tabsCard, findsOneWidget);
      expect(
        find.descendant(of: tabsCard, matching: find.text('SQLite')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: tabsCard, matching: find.text('PostgreSQL')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('database-sqlite-card')), findsOneWidget);

      await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('database-actions-card')), findsOneWidget);
    });

    testWidgets(
      'PostgreSQL connection card shows manual env guidance without an add action',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_HOST',
              value: 'deploydash_postgres',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PORT',
              value: '5432',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'alpha_db',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'alpha_user',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'pg-secret-123',
            ),
          ],
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('database-inject-postgres-toggle')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('database-copy-connection-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
        expect(
          find.textContaining('Environment variables editor'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PostgreSQL connection actions are disabled when no password is stored',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_HOST',
              value: 'deploydash_postgres',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PORT',
              value: '5432',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'alpha_db',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'alpha_user',
            ),
          ],
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.text('Not captured in this session'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('database-copy-connection-button')),
              )
              .onPressed,
          isNull,
        );
        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'PostgreSQL connection action requires a password captured in this session',
      (WidgetTester tester) async {
        String? clipboardText;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              final arguments = call.arguments as Map<dynamic, dynamic>;
              clipboardText = arguments['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });

        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_HOST',
              value: 'deploydash_postgres',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PORT',
              value: '5432',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_NAME',
              value: 'alpha_db',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_USER',
              value: 'alpha_user',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime',
              key: 'DATABASE_PASSWORD',
              value: 'pg secret/123',
            ),
          ],
        );
        final sshService = DatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'alpha_user',
                'database': 'alpha_db',
                'access_mode': 'read_write',
              },
            ],
          },
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        final copyButton = find.byKey(
          const Key('database-copy-connection-button'),
        );
        final actionsWrap = find.ancestor(
          of: copyButton,
          matching: find.byType(Wrap),
        );

        expect(tester.widget<OutlinedButton>(copyButton).onPressed, isNull);
        expect(
          find.byKey(const Key('database-add-postgres-webapp-button')),
          findsNothing,
        );
        expect(
          find.descendant(of: actionsWrap.first, matching: copyButton),
          findsOneWidget,
        );
        expect(find.text('Not captured in this session'), findsOneWidget);
        expect(clipboardText, isNull);
      },
    );

    testWidgets('Database tab uses compact stacked layout on narrow widths', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'engine_version': '16.4',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
      );

      await pumpProjectWorkspace(
        tester,
        surfaceSize: const Size(800, 1080),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      expect(find.text('Database overview'), findsOneWidget);
      expect(find.text('Databases'), findsWidgets);
    });
  }, skip: !sqliteAvailable);
}
