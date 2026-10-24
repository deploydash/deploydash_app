import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace PostgreSQL restore and errors.
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

  group('project workspace PostgreSQL restore and errors', () {
    testWidgets(
      'Database tab surfaces thrown list exceptions as retryable errors',
      (WidgetTester tester) async {
        final sshService = OutcomeDatabaseWorkflowSshService(
          projectListOutcome: Exception('list exploded'),
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
        expect(
          find.text(
            'Could not load project databases: Exception: list exploded',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore picks a workstation file and runs import workflow',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        debugOverridePostgresRestoreSqlFilePicker(
          () async => '/tmp/local-backup.sql',
        );
        addTearDown(() => debugOverridePostgresRestoreSqlFilePicker(null));
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'success',
              'code': 'OK',
              'msg': 'Local SQL restore completed.',
              'target_database_name': 'restore_db',
              'imported_size_bytes': 42,
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.text('Import .sql into DB'), findsOneWidget);
        expect(
          find.byKey(const Key('database-restore-local-sql-button')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Restore local SQL file'), findsOneWidget);
        expect(
          find.text(
            'Restore this database dump into "restore_db"? Deploy Dash uploads the selected .sql or custom-format .dump file from this workstation and imports it into the selected PostgreSQL database. The import runs as one transaction: if anything fails, the database is left unchanged and you can safely retry.',
          ),
          findsOneWidget,
        );
        expect(find.text('/tmp/local-backup.sql'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        final importCall = sshService.callLog.lastWhere(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'import_local_sql',
        );
        final params = importCall['params'] as Map<String, dynamic>?;
        final settings = params?['settings'] as Map?;
        expect(settings?['database_name'], 'restore_db');
        expect(settings?['import_local_file_path'], '/tmp/local-backup.sql');
        expect(settings?['import_ignore_ownership'], isFalse);
        expect(
          find.text('SQL file restored into "restore_db".'),
          findsOneWidget,
        );
        final journalRows =
            await (database.select(database.projectManagedOperationJournal)
                  ..where(
                    (table) => table.operationType.equals('import_local_sql'),
                  ))
                .get();
        expect(journalRows, hasLength(1));
        expect(journalRows.single.status, 'committed_local');
        expect(journalRows.single.requestJson, contains('restore_db'));
        expect(journalRows.single.requestJson, isNot(contains('local-backup')));
        expect(journalRows.single.resultJson, contains('imported_size_bytes'));
        expect(journalRows.single.resultJson, isNot(contains('local-backup')));
      },
    );

    testWidgets(
      'PostgreSQL restore ignore-ownership option reaches the import workflow',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        debugOverridePostgresRestoreSqlFilePicker(
          () async => '/tmp/local-backup.sql',
        );
        addTearDown(() => debugOverridePostgresRestoreSqlFilePicker(null));
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'success',
              'code': 'OK',
              'msg': 'Local SQL restore completed.',
              'target_database_name': 'restore_db',
              'imported_size_bytes': 42,
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('Ignore ownership and permission statements'),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('database-restore-ignore-ownership-field')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        final importCall = sshService.callLog.lastWhere(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'import_local_sql',
        );
        final params = importCall['params'] as Map<String, dynamic>?;
        final settings = params?['settings'] as Map?;
        expect(settings?['import_ignore_ownership'], isTrue);
        expect(
          find.text('SQL file restored into "restore_db".'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore sends the logical database name',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        debugOverridePostgresRestoreSqlFilePicker(
          () async => '/tmp/local-backup.sql',
        );
        addTearDown(() => debugOverridePostgresRestoreSqlFilePicker(null));
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['dd_regs_v3_main'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'dd_regs_v3_main_user',
                'database': 'dd_regs_v3_main',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'success',
              'code': 'OK',
              'msg': 'Local SQL restore completed.',
              'target_database_name': 'dd_regs_v3_main',
              'imported_size_bytes': 42,
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: const ProjectWorkspace(),
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        final importCall = sshService.callLog.lastWhere(
          (call) =>
              call['workflow_id'] == 'postgres' &&
              call['operation_id'] == 'import_local_sql',
        );
        final params = importCall['params'] as Map<String, dynamic>?;
        final settings = params?['settings'] as Map?;
        expect(settings?['database_name'], 'main');
        final journalRows =
            await (database.select(database.projectManagedOperationJournal)
                  ..where(
                    (table) => table.operationType.equals('import_local_sql'),
                  ))
                .get();
        expect(journalRows, hasLength(1));
        expect(
          journalRows.single.requestJson,
          contains('"database_name":"main"'),
        );
        expect(journalRows.single.requestJson, isNot(contains('dd_regs_v3')));
      },
    );

    testWidgets('PostgreSQL local SQL restores report the restore event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      debugOverridePostgresRestoreSqlFilePicker(
        () async => '/tmp/local-backup.sql',
      );
      addTearDown(() => debugOverridePostgresRestoreSqlFilePicker(null));
      final sshService = OperationOverrideDatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['restore_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'restore_user',
              'database': 'restore_db',
              'access_mode': 'read_write',
            },
          ],
        },
        operationResponses: const <String, Map<String, dynamic>>{
          'import_local_sql': <String, dynamic>{
            'status': 'success',
            'msg': 'Local SQL restore completed.',
            'target_database_name': 'restore_db',
            'imported_size_bytes': 42,
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
      await tester.tap(
        find.byKey(const Key('database-restore-local-sql-button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
      await tester.pumpAndSettle();

      expect(find.text('SQL file restored into "restore_db".'), findsOneWidget);
      expect(analytics.restoreEvents, hasLength(1));
      expect(
        analytics.restoreEvents.single.outcome,
        DataOperationOutcome.success,
      );
      expect(
        analytics.restoreEvents.single.durationSeconds,
        greaterThanOrEqualTo(0),
      );
    });

    testWidgets(
      'PostgreSQL local SQL restore failures report the restore event',
      (WidgetTester tester) async {
        final analytics = FakeAnalyticsService();
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'error',
              'msg': 'PostgreSQL local SQL restore failed.',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
            appAnalyticsServiceProvider.overrideWithValue(analytics),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.text('SQL restore failed'), findsOneWidget);
        expect(analytics.restoreEvents, hasLength(1));
        expect(
          analytics.restoreEvents.single.outcome,
          DataOperationOutcome.failure,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore surfaces backend details prominently on failure',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'error',
              'msg': 'PostgreSQL local SQL restore failed.',
              'details': 'psql: relation "users" does not exist',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(find.byKey(const Key('database-error-pill')), findsOneWidget);
        expect(find.text('SQL restore failed'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('database-error-text')))
              .data,
          'PostgreSQL local SQL restore failed.',
        );
        expect(
          find.byKey(const Key('database-error-details-text')),
          findsOneWidget,
        );
        expect(
          find.text('psql: relation "users" does not exist'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('database-error-copy-details-button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore failure returns the Database view to its error summary',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'error',
              'msg': 'PostgreSQL local SQL restore failed.',
              'details': 'psql: syntax error at or near "THIS"',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          surfaceSize: const Size(800, 600),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        final restoreButton = find.byKey(
          const Key('database-restore-local-sql-button'),
        );
        final databaseScrollable = find
            .descendant(
              of: find.byKey(const Key('database-tab-scroll')),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.drag(databaseScrollable, const Offset(0, -800));
        await tester.pumpAndSettle();
        await tester.tap(restoreButton);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(
          tester.state<ScrollableState>(databaseScrollable).position.pixels,
          0,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore failure survives Database tab recreation',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const projectListResponse = <String, dynamic>{
          'status': 'success',
          'service_status': <String, dynamic>{
            'configured': true,
            'running': true,
          },
          'databases': <String>['restore_db'],
          'users': <Map<String, dynamic>>[
            <String, dynamic>{
              'username': 'restore_user',
              'database': 'restore_db',
              'access_mode': 'read_write',
            },
          ],
        };
        await seedManagedPostgresCatalog(
          database,
          projectListResponse: projectListResponse,
        );
        final sshService = DelayedOperationDatabaseWorkflowSshService(
          projectListResponse: projectListResponse,
          delayedOperationId: 'import_local_sql',
          delayedResponse: const <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_RUNTIME_ERROR',
            'msg': 'PostgreSQL local SQL restore failed.',
            'details': 'psql: syntax error at or near "THIS"',
          },
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            serverConnectionPayloadResolverProvider.overrideWithValue(
              testServerConnectionPayload,
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );
        addTearDown(container.dispose);
        Future<void> pumpWorkspace() {
          return tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                home: Scaffold(
                  body: ProjectWorkspace(
                    pickPostgresRestoreSqlFile: () async =>
                        '/tmp/local-backup.sql',
                  ),
                ),
              ),
            ),
          );
        }

        await pumpWorkspace();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        final restoreButton = find.byKey(
          const Key('database-restore-local-sql-button'),
        );
        await tester.ensureVisible(restoreButton);
        await tester.tap(restoreButton);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await sshService.operationStarted.future;

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: SizedBox())),
          ),
        );
        await tester.pump();
        sshService.releaseOperation.complete();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await pumpWorkspace();
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(find.text('SQL restore failed'), findsOneWidget);
        expect(
          find.text('PostgreSQL local SQL restore failed.'),
          findsOneWidget,
        );
        expect(
          find.text('psql: syntax error at or near "THIS"'),
          findsOneWidget,
        );
        final journals = await AppReleaseRepository(
          database,
        ).listFailedJournal();
        final journal = journals.singleWhere(
          (entry) => entry.operationType == 'import_local_sql',
        );
        expect(journal.requestJson, contains('restore_db'));
        expect(journal.requestJson, isNot(contains('local-backup.sql')));
        expect(journal.resultJson, isNot(contains('syntax error')));
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore failure survives a same-workspace server rebind',
      (WidgetTester tester) async {
        var selectedServer = serverWithDatabaseEnabled;
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'error',
              'msg': 'PostgreSQL local SQL restore failed.',
              'details': 'psql: syntax error at or near "THIS"',
            },
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWith((ref) => selectedServer),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('database-error-card')), findsOneWidget);

        selectedServer = serverWithUpdatedAt(
          selectedServer,
          DateTime.utc(2026, 8, 9, 17),
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );
        container.invalidate(selectedServerProvider);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(find.text('SQL restore failed'), findsOneWidget);
        expect(find.text('PostgreSQL local SQL restore failed.'), findsWidgets);
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore cancels without running the import workflow',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{},
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
        await tester.pumpAndSettle();

        expect(
          sshService.callLog.where(
            (call) => call['operation_id'] == 'import_local_sql',
          ),
          isEmpty,
        );
      },
    );

    testWidgets(
      'PostgreSQL local SQL restore surfaces thrown import exceptions',
      (WidgetTester tester) async {
        final sshService = OutcomeDatabaseWorkflowSshService(
          projectListOutcome: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationOutcomes: <String, Object>{
            'postgres/import_local_sql': Exception('import exploded'),
          },
        );
        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();

        expect(find.text('SQL restore failed'), findsOneWidget);
        expect(
          find.text('Could not restore SQL file: Exception: import exploded'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Database error details copy button copies the summary and details',
      (WidgetTester tester) async {
        final sshService = OperationOverrideDatabaseWorkflowSshService(
          projectListResponse: const <String, dynamic>{
            'status': 'success',
            'service_status': <String, dynamic>{
              'configured': true,
              'running': true,
            },
            'databases': <String>['restore_db'],
            'users': <Map<String, dynamic>>[
              <String, dynamic>{
                'username': 'restore_user',
                'database': 'restore_db',
                'access_mode': 'read_write',
              },
            ],
          },
          operationResponses: const <String, Map<String, dynamic>>{
            'import_local_sql': <String, dynamic>{
              'status': 'error',
              'msg': 'PostgreSQL local SQL restore failed.',
              'details': 'psql: relation "users" does not exist',
            },
          },
        );
        String? clipboardText;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                final arguments = call.arguments as Map<dynamic, dynamic>;
                clipboardText = arguments['text'] as String?;
              }
              return null;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null);
        });

        await pumpProjectWorkspace(
          tester,
          child: ProjectWorkspace(
            pickPostgresRestoreSqlFile: () async => '/tmp/local-backup.sql',
          ),
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-restore-local-sql-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Restore').last);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('database-error-copy-details-button')),
        );
        await tester.pump();

        expect(
          clipboardText,
          'PostgreSQL local SQL restore failed.\n\n'
          'psql: relation "users" does not exist',
        );
      },
    );

    testWidgets('Database error card hides blank details and copy action', (
      WidgetTester tester,
    ) async {
      final sshService = DatabaseWorkflowSshService(
        projectListResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Could not list project databases.',
          'details': '   ',
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
      await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      expect(
        find.byKey(const Key('database-error-details-text')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('database-error-copy-details-button')),
        findsNothing,
      );
    });

    testWidgets(
      'Thrown database mutations surface the fallback exception message',
      (WidgetTester tester) async {
        final sshService = OutcomeDatabaseWorkflowSshService(
          projectListOutcome: const <String, dynamic>{
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
          operationOutcomes: <String, Object>{
            'postgres/project_create_user': Exception('grant exploded'),
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
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, -700),
        );
        await tester.pumpAndSettle();
        final createUserButton = tester.widget<OutlinedButton>(
          find.byKey(const Key('database-link-button')),
        );
        createUserButton.onPressed!.call();
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('database-connect-existing-username-field')),
          'alpha_reader',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('database-tab-scroll')),
          const Offset(0, 700),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('database-error-card')), findsOneWidget);
        expect(
          find.text('Database action failed: Exception: grant exploded'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Mutation failures render prominent retryable error card', (
      WidgetTester tester,
    ) async {
      final sshService = OperationOverrideDatabaseWorkflowSshService(
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
        operationResponses: const <String, Map<String, dynamic>>{
          'project_create_user': <String, dynamic>{
            'status': 'error',
            'msg': 'Access grant failed due to role conflict.',
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final createUserButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('database-link-button')),
      );
      expect(createUserButton.onPressed, isNotNull);
      createUserButton.onPressed!.call();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-connect-existing-username-field')),
        'alpha_reader',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, 700),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      expect(find.byKey(const Key('database-error-text')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('database-error-text'))).data,
        'Access grant failed due to role conflict.',
      );
      expect(
        find.byKey(const Key('database-error-retry-button')),
        findsOneWidget,
      );
    });

    testWidgets('Retry button refreshes data and clears database error card', (
      WidgetTester tester,
    ) async {
      final sshService = OperationOverrideDatabaseWorkflowSshService(
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
        operationResponses: const <String, Map<String, dynamic>>{
          'project_create_user': <String, dynamic>{
            'status': 'error',
            'msg': 'Access grant failed due to role conflict.',
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
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final createUserButton = tester.widget<OutlinedButton>(
        find.byKey(const Key('database-link-button')),
      );
      expect(createUserButton.onPressed, isNotNull);
      createUserButton.onPressed!.call();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('database-connect-existing-username-field')),
        'alpha_reader',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create user'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('database-tab-scroll')),
        const Offset(0, 700),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('database-error-card')), findsOneWidget);
      final callsBeforeRetry = sshService.projectListCalls;

      await tester.tap(find.byKey(const Key('database-error-retry-button')));
      await tester.pumpAndSettle();

      expect(sshService.projectListCalls, greaterThan(callsBeforeRetry));
      expect(find.byKey(const Key('database-error-card')), findsNothing);
    });

    testWidgets(
      'Create database dialog clears database name errors when edited',
      (WidgetTester tester) async {
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
        await tester.tap(find.byKey(const Key('database-create-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Create').last);
        await tester.pumpAndSettle();
        expect(find.text('Database name is required.'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('database-create-name-field')),
          'alpha_db',
        );
        await tester.pumpAndSettle();
        expect(find.text('Database name is required.'), findsNothing);
      },
    );
  }, skip: !sqliteAvailable);
}
