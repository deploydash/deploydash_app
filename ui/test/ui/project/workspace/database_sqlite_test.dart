import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace SQLite storage.
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

  group('project workspace SQLite storage', () {
    testWidgets('SQLite create flow ensures volume and shows metadata', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseSqliteWorkflowSshService(
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
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-sqlite-card')), findsOneWidget);
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Primary',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(sshService.sqliteEnsureCalls, 1);
      expect(find.text('Primary'), findsWidgets);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Prepare storage'), findsNothing);
      expect(find.text('deploydash_sqlite_regs-v3_primary'), findsNothing);
    });

    testWidgets('SQLite storage mutations report the database event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final sshService = DatabaseSqliteWorkflowSshService(
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
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Primary',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(sshService.sqliteEnsureCalls, 1);
      expect(analytics.databaseEvents, [
        (engine: DatabaseEngine.sqlite, outcome: DataOperationOutcome.success),
      ]);
    });

    testWidgets('SQLite storage failures report the database event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'sqlite_volume_ensure': <String, dynamic>{
            'status': 'error',
            'msg': 'Docker volume missing.',
          },
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Prepare storage'));
      await tester.pumpAndSettle();

      expect(find.text('storage missing.'), findsOneWidget);
      expect(analytics.databaseEvents, [
        (engine: DatabaseEngine.sqlite, outcome: DataOperationOutcome.failure),
      ]);
    });

    testWidgets('SQLite card prompts for a selected server and project', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-sqlite-card')), findsOneWidget);
      expect(
        find.text('Select a server and project to manage SQLite databases.'),
        findsOneWidget,
      );
      final createButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('database-sqlite-create-button')),
      );
      expect(createButton.onPressed, isNull);
    });

    testWidgets(
      'SQLite create dialog validates duplicate names and alphanumeric input',
      (WidgetTester tester) async {
        final database = await createDatabaseWithSqliteRows([
          sqliteRecord(
            id: 'sqlite-primary',
            name: 'Primary',
            volumeName: 'deploydash_sqlite_regs-v3_primary',
            isPrimary: true,
          ),
        ]);
        final sshService = DatabaseSqliteWorkflowSshService(
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
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-sqlite-create-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('database-sqlite-volume-field')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('database-sqlite-mount-path-field')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('database-sqlite-file-name-field')),
          findsNothing,
        );

        await tester.enterText(
          find.byKey(const Key('database-sqlite-name-field')),
          'Primary',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        expect(
          find.text('A SQLite config with this name already exists.'),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('database-sqlite-name-field')),
          'Primary 2',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();

        expect(
          find.text('Name can only use letters and numbers.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('SQLite create flow reports incomplete SSH key credentials', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseSqliteWorkflowSshService(
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
          selectedServerProvider.overrideWithValue(serverWithMissingSshKeyPath),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Primary',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        find.text('Selected server credentials are incomplete.'),
        findsOneWidget,
      );
    });

    testWidgets('SQLite prepare storage normalizes backend volume wording', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'sqlite_volume_ensure': <String, dynamic>{
            'status': 'error',
            'msg': 'Docker volume missing.',
          },
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Prepare storage'));
      await tester.pumpAndSettle();

      expect(find.text('storage missing.'), findsOneWidget);
    });

    testWidgets('SQLite refresh storage surfaces thrown errors', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        throwingOperations: const <String, Object>{
          'sqlite_volume_status': 'status exploded',
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh storage status'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Could not refresh SQLite status: Bad state: status exploded',
        ),
        findsOneWidget,
      );
    });

    testWidgets('SQLite set primary updates the stored primary database', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
        sqliteRecord(
          id: 'sqlite-replica',
          name: 'Replica',
          volumeName: 'deploydash_sqlite_regs-v3_replica',
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Set primary'));
      await tester.pumpAndSettle();

      final repository = ProjectSqliteDatabaseRepository(database);
      final rows = await repository.listForProject(selectedProject.id);
      final primary = rows.singleWhere((row) => row.isPrimary);
      expect(primary.name, 'Replica');
    });

    testWidgets('SQLite set primary surfaces repository failures', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
        sqliteRecord(
          id: 'sqlite-replica',
          name: 'Replica',
          volumeName: 'deploydash_sqlite_regs-v3_replica',
        ),
      ]);
      final repository = ThrowingProjectSqliteDatabaseRepository(
        database,
        throwOnSetPrimary: true,
      );
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(repository),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Set primary'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Could not set primary SQLite database: Bad state: sqlite set primary failed',
        ),
        findsOneWidget,
      );
    });

    testWidgets('SQLite delete cancel keeps the database config', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete SQLite database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      final repository = ProjectSqliteDatabaseRepository(database);
      final rows = await repository.listForProject(selectedProject.id);
      expect(rows, hasLength(1));
      expect(sshService.sqliteDeleteCalls, 0);
    });

    testWidgets('SQLite delete success removes the config and shows feedback', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete SQLite database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      final repository = ProjectSqliteDatabaseRepository(database);
      expect(await repository.listForProject(selectedProject.id), isEmpty);
      expect(find.text('SQLite database deleted.'), findsOneWidget);
    });

    testWidgets('SQLite delete surfaces backend and repository failures', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final repository = ThrowingProjectSqliteDatabaseRepository(
        database,
        throwOnDelete: true,
      );
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'sqlite_volume_delete': <String, dynamic>{
            'status': 'error',
            'msg': 'SQLite volume delete failed.',
          },
        },
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(repository),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete SQLite database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.text('SQLite storage delete failed.'), findsOneWidget);
    });

    testWidgets('SQLite create flow uses SSH key connection payload', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseSqliteWorkflowSshService(
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
          selectedServerProvider.overrideWithValue(serverWithSshKeyEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Primary',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        sshService.lastConnection?['private_key'],
        '-----BEGIN OPENSSH PRIVATE KEY-----\n'
        'test-private-key\n'
        '-----END OPENSSH PRIVATE KEY-----',
      );
      expect(sshService.lastConnection?.containsKey('key_path'), isFalse);
      expect(sshService.lastConnection?.containsKey('password'), isFalse);
    });

    testWidgets(
      'SQLite create dialog cancel closes without creating a config',
      (WidgetTester tester) async {
        final database = await createDatabaseWithSqliteRows(const []);
        final sshService = DatabaseSqliteWorkflowSshService(
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
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-sqlite-create-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();

        final repository = ProjectSqliteDatabaseRepository(database);
        expect(await repository.listForProject(selectedProject.id), isEmpty);
      },
    );

    testWidgets('SQLite create flow surfaces repository upsert failures', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final repository = ThrowingProjectSqliteDatabaseRepository(
        database,
        throwOnUpsert: true,
      );
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(repository),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Replica',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Could not create SQLite database: Bad state: sqlite upsert failed',
        ),
        findsOneWidget,
      );
    });

    testWidgets('SQLite dialog field errors clear on change and toggle', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseSqliteWorkflowSshService(
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-sqlite-create-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        '',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(find.text('Name is required.'), findsOneWidget);
      expect(
        find.byKey(const Key('database-sqlite-volume-field')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('database-sqlite-mount-path-field')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('database-sqlite-file-name-field')),
        findsNothing,
      );

      await tester.enterText(
        find.byKey(const Key('database-sqlite-name-field')),
        'Primary',
      );
      await tester.tap(find.byKey(const Key('database-sqlite-primary-toggle')));
      await tester.pumpAndSettle();

      expect(find.text('Name is required.'), findsNothing);
    });

    testWidgets('SQLite storage usage formatting covers bytes MiB and GiB', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-bytes',
          name: 'BytesDb',
          volumeName: 'deploydash_sqlite_regs-v3_bytes',
          isPrimary: true,
          volumeSizeBytes: 512,
        ),
        sqliteRecord(
          id: 'sqlite-mib',
          name: 'MiBDb',
          volumeName: 'deploydash_sqlite_regs-v3_mib',
          volumeSizeBytes: 1024 * 1024,
        ),
        sqliteRecord(
          id: 'sqlite-gib',
          name: 'GiBDb',
          volumeName: 'deploydash_sqlite_regs-v3_gib',
          volumeSizeBytes: 1024 * 1024 * 1024,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
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
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();

      expect(find.text('Size: 512 B'), findsOneWidget);
      expect(find.text('Size: 1.0 MiB'), findsOneWidget);
      expect(find.text('Size: 1.00 GiB'), findsOneWidget);
    });

    testWidgets(
      'SQLite compact summary leads with readiness and hides PostgreSQL state',
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
        final database = await createDatabaseWithSqliteRows([
          sqliteRecord(
            id: 'sqlite-ready',
            name: 'Primary',
            volumeName: 'deploydash_sqlite_regs-v3_primary',
            isPrimary: true,
            volumeExists: true,
            volumeMountpoint: '/var/lib/docker/volumes/primary/_data',
            volumeSizeBytes: 1024 * 1024,
            lastCheckedAt: DateTime.now().subtract(const Duration(minutes: 2)),
          ),
        ]);
        await pumpProjectWorkspace(
          tester,
          database: database,
          surfaceSize: const Size(760, 900),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
        await tester.pumpAndSettle();

        expect(find.text('Ready'), findsOneWidget);
        expect(find.text('Role: Primary'), findsOneWidget);
        expect(find.text('Size: 1.0 MiB'), findsOneWidget);
        expect(find.textContaining('Checked 2 min ago'), findsOneWidget);
        expect(find.text('Stale status'), findsNothing);
        expect(find.text('Prepare storage'), findsNothing);
        expect(find.text('Managed databases'), findsNothing);
        expect(
          find.text('Database service is disabled for this server.'),
          findsNothing,
        );
        expect(
          find.text('/var/lib/docker/volumes/primary/_data'),
          findsNothing,
        );

        final connectionText = tester.widget<Text>(
          find.descendant(
            of: find.byKey(
              const Key('database-sqlite-connection-sqlite-ready'),
            ),
            matching: find.text('sqlite:////workspace/data/primary.db'),
          ),
        );
        expect(connectionText.maxLines, 1);
        expect(connectionText.overflow, TextOverflow.ellipsis);
        final copyButton = find.byKey(
          const Key('database-sqlite-copy-connection-sqlite-ready'),
        );
        await tester.ensureVisible(copyButton);
        await tester.tap(copyButton);
        await tester.pump();
        expect(clipboardText, 'sqlite:////workspace/data/primary.db');
        expect(find.text('SQLite connection copied.'), findsOneWidget);
      },
    );

    testWidgets(
      'SQLite refresh storage parses string sizes and updates metadata',
      (WidgetTester tester) async {
        final database = await createDatabaseWithSqliteRows([
          sqliteRecord(
            id: 'sqlite-primary',
            name: 'Primary',
            volumeName: 'deploydash_sqlite_regs-v3_primary',
            isPrimary: true,
          ),
        ]);
        final sshService = DatabaseSqliteWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['alpha_db'],
            'users': <Map<String, dynamic>>[],
          },
          operationResponses: <String, Map<String, dynamic>>{
            'sqlite_volume_status': <String, dynamic>{
              'status': 'success',
              'msg': 'SQLite volume status captured.',
              'sqlite_storage': <String, dynamic>{
                'enabled': true,
                'volume_name': 'deploydash_sqlite_regs-v3_primary',
                'mount_path': '/workspace/data',
                'file_name': 'primary.db',
                'database_path': '/workspace/data/primary.db',
                'database_url': 'sqlite:////workspace/data/primary.db',
                'volume_exists': true,
                'volume_mountpoint': '/var/lib/docker/volumes/primary/_data',
                'volume_size_bytes': '1048576',
                'checked_at': '2026-04-14T12:34:00Z',
              },
            },
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
        await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Refresh storage status'));
        await tester.pumpAndSettle();

        expect(find.text('Size: 1.0 MiB'), findsOneWidget);
        expect(find.textContaining('Checked '), findsOneWidget);
        expect(find.text('Stale status'), findsOneWidget);
        await tester.tap(find.text('Technical details'));
        await tester.pumpAndSettle();
        expect(
          find.text('/var/lib/docker/volumes/primary/_data'),
          findsOneWidget,
        );
      },
    );

    testWidgets('SQLite prepare and delete surface thrown exceptions', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        throwingOperations: const <String, Object>{
          'sqlite_volume_ensure': 'ensure exploded',
          'sqlite_volume_delete': 'delete exploded',
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Prepare storage'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not prepare SQLite storage: Bad state: ensure exploded',
        ),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Delete SQLite database'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not delete SQLite database: Bad state: delete exploded',
        ),
        findsOneWidget,
      );
    });

    testWidgets('SQLite refresh storage falls back to the default error copy', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'sqlite_volume_status': <String, dynamic>{
            'status': 'error',
            'msg': '   ',
          },
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh storage status'));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not refresh SQLite storage status.'),
        findsOneWidget,
      );
    });

    testWidgets('SQLite refresh normalizes backend storage wording in errors', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DatabaseSqliteWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'sqlite_volume_status': <String, dynamic>{
            'status': 'error',
            'msg': 'Docker volume is missing for this SQLite volume.',
          },
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh storage status'));
      await tester.pumpAndSettle();

      expect(
        find.text('storage is missing for this SQLite storage.'),
        findsOneWidget,
      );
    });

    testWidgets('SQLite prepare storage shows a busy label', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
      ]);
      final sshService = DelayedOperationDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedOperationId: 'sqlite_volume_ensure',
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
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Prepare storage'));
      await sshService.operationStarted.future;
      await tester.pump();
      expect(find.text('Preparing...'), findsOneWidget);
      sshService.releaseOperation.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('SQLite refresh, set primary, and delete show busy labels', (
      WidgetTester tester,
    ) async {
      final database = await createDatabaseWithSqliteRows([
        sqliteRecord(
          id: 'sqlite-primary',
          name: 'Primary',
          volumeName: 'deploydash_sqlite_regs-v3_primary',
          isPrimary: true,
        ),
        sqliteRecord(
          id: 'sqlite-replica',
          name: 'Replica',
          volumeName: 'deploydash_sqlite_regs-v3_replica',
        ),
      ]);
      final repository = DelayedProjectSqliteDatabaseRepository(
        database,
        delaySetPrimary: true,
      );

      final refreshService = DelayedOperationDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedOperationId: 'sqlite_volume_status',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(repository),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(refreshService),
        ],
      );
      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Refresh storage status').first);
      await refreshService.operationStarted.future;
      await tester.pump();
      expect(find.byTooltip('Refreshing storage status'), findsOneWidget);
      refreshService.releaseOperation.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.widgetWithText(OutlinedButton, 'Set primary'));
      await repository.setPrimaryStarted.future;
      await tester.pump();
      expect(find.text('Setting...'), findsOneWidget);
      repository.releaseSetPrimary.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final deleteService = DelayedOperationDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['alpha_db'],
          'users': <Map<String, dynamic>>[],
        },
        delayedOperationId: 'sqlite_volume_delete',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(repository),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(deleteService),
        ],
      );
      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-sqlite-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete SQLite database').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await deleteService.operationStarted.future;
      await tester.pump();
      expect(find.byTooltip('Deleting SQLite database'), findsOneWidget);
      deleteService.releaseOperation.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('SQLite storage derives a safe volume name from a blank slug', (
      WidgetTester tester,
    ) async {
      const sqliteProject = Project(
        id: 'project-sqlite-safe-default',
        name: '!!!',
        type: 'Web app',
        gitUrl: 'https://github.com/example/sqlite-default',
        primaryDomain: 'sqlite-default.example.com',
        repositoryFullName: 'deploydash/laravel-example-app',
        appSubdirectory: 'website',
        appPort: 3000,
        sqliteStorageEnabled: true,
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(sqliteProject);
      final sshService = RuntimeWorkflowSshService();
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: sqliteProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();

      final deployCall = sshService.workflowCalls.lastWhere(
        (call) => call['workflow_id'] == 'app' && call['operation_id'] == 'run',
      );
      final params = deployCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      final sqliteStorage = settings['sqlite_storage'] as Map<String, dynamic>;
      expect(sqliteStorage['volume_name'], 'deploydash_sqlite_project-app');
      expect(sqliteStorage['mount_path'], '/var/lib/deploydash/sqlite');
      expect(sqliteStorage['file_name'], 'app.sqlite3');
    });

    testWidgets(
      'a project without SQLite storage does not send storage setup',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        final sshService = RuntimeWorkflowSshService();
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );

        await tester.tap(find.byKey(const Key('github-deploy-button')));
        await tester.pumpAndSettle();

        final deployCall = sshService.workflowCalls.lastWhere(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        );
        final params = deployCall['params'] as Map<String, dynamic>;
        final settings = params['settings'] as Map<String, dynamic>;
        expect(settings.containsKey('sqlite_storage'), isFalse);
      },
    );

    testWidgets('SQLite storage trims an explicitly saved volume name', (
      WidgetTester tester,
    ) async {
      final sqliteProject = selectedProject.copyWith(
        sqliteStorageEnabled: true,
        sqliteVolumeName: '  deploydash_sqlite_custom  ',
        sqliteMountPath: ' /workspace/sqlite ',
        sqliteFileName: ' main.sqlite3 ',
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(sqliteProject);
      final sshService = RuntimeWorkflowSshService();
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: sqliteProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();

      final deployCall = sshService.workflowCalls.lastWhere(
        (call) => call['workflow_id'] == 'app' && call['operation_id'] == 'run',
      );
      final params = deployCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      final sqliteStorage = settings['sqlite_storage'] as Map<String, dynamic>;
      expect(sqliteStorage['volume_name'], 'deploydash_sqlite_custom');
      expect(sqliteStorage['mount_path'], '/workspace/sqlite');
      expect(sqliteStorage['file_name'], 'main.sqlite3');
    });
  }, skip: !sqliteAvailable);
}
