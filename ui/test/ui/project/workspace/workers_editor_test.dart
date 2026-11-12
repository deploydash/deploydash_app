import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace workers editor.
///
/// One of sixteen files T-3.6.1 split `project_workspace_test.dart` into. That
/// file was 16,030 lines holding 230 tests in two groups: a directory's worth
/// of tests wearing a filename, which nobody could hold in view, so a coverage
/// gap in it was invisible by construction.
///
/// Fixtures and pump helpers live in
/// `_support/project_workspace_harness.dart`.
Future<WorkersWorkflowSshService> _pumpWorkersWithOneSavedWorker(
  WidgetTester tester, {
  required FakeAnalyticsService analytics,
  Map<String, dynamic>? applyResponse,
  Map<String, List<Object>> operationOutcomesByKey = const {},
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() async {
    await database.close();
  });

  final sshService = WorkersWorkflowSshService(
    projectListResponse: const <String, dynamic>{
      'status': 'success',
      'users': [
        {
          'username': 'app_rw',
          'database': 'app_db',
          'access_mode': 'read_write',
        },
      ],
    },
    statusResponse: const <String, dynamic>{
      'status': 'success',
      'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
    },
    applyResponse:
        applyResponse ??
        const <String, dynamic>{
          'status': 'success',
          'msg': 'Applied.',
          'workers': {'configured': <dynamic>[], 'orphans': <dynamic>[]},
        },
    operationOutcomesByKey: operationOutcomesByKey,
  );
  await seedManagedPostgresCatalog(
    database,
    projectListResponse: sshService.projectListResponse,
  );

  await pumpProjectWorkspace(
    tester,
    database: database,
    overrides: [
      selectedProjectProvider.overrideWithValue(selectedProjectWithLiveRuntime),
      selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
      sshServiceProvider.overrideWithValue(sshService),
      appAnalyticsServiceProvider.overrideWithValue(analytics),
    ],
  );

  await tester.tap(find.widgetWithText(Tab, 'Workers'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workers-add-button')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('workers-editor-name-field')),
    'Queue worker',
  );
  await tester.enterText(
    find.byKey(const Key('workers-editor-command-field')),
    'npm run worker:queue',
  );
  // Let the dialog rebuild with the entered text: the save button stays
  // disabled until the form validates, and the tap below must land on the
  // enabled button.
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('workers-editor-save-button')));
  await tester.pumpAndSettle();

  return sshService;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('project workspace workers editor', () {
    testWidgets('Workers tab shows the missing-selection empty state', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(null),
          selectedServerProvider.overrideWithValue(null),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workers-missing-selection-message')),
        findsOneWidget,
      );
      expect(
        find.text(
          'Choose a project and server before you set up background workers.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'Workers tab blocks runtime actions before a live app release',
      (WidgetTester tester) async {
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('workers-app-runtime-required-callout')),
          findsOneWidget,
        );
        expect(find.text('Deploy this web app first.'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('workers-add-button')))
              .onPressed,
          isNull,
        );
        expect(
          find.byKey(const Key('workers-apply-runtime-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('workers-add-button')), findsOneWidget);
        expect(
          find.byKey(const Key('workers-empty-state-text')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('project-open-web-app-tab-button')),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('app-tab-scroll')), findsOneWidget);
      },
    );

    testWidgets('Workers tab creates and persists worker configuration', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

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
          'msg': 'Applied.',
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
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workers-overview-card')), findsOneWidget);

      await tester.tap(find.byKey(const Key('workers-add-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('workers-editor-name-field')),
        'Queue worker',
      );
      await tester.enterText(
        find.byKey(const Key('workers-editor-command-field')),
        'npm run worker:queue',
      );
      await tester.enterText(
        find.byKey(const Key('workers-editor-environment-field')),
        'DATABASE_URL=postgresql://db/one\nANOTHER_KEY=another value',
      );
      await tester.pumpAndSettle();
      expect(find.text('2 variables'), findsOneWidget);

      final saveButton = tester.widget<FilledButton>(
        find.byKey(const Key('workers-editor-save-button')),
      );
      expect(saveButton.onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('workers-editor-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Queue worker'), findsOneWidget);

      final records = await WorkerInstanceRepository(
        database,
      ).listForProject(selectedProject.id);
      expect(records, hasLength(1));
      final saved = records.first;
      expect(saved.id, 'queue-worker');
      expect(saved.startCommand, 'npm run worker:queue');
      expect(saved.cpuLimit, 0.5);
      expect(saved.memoryMb, 256);
      expect(saved.diskMb, 1024);
      expect(saved.environment, {
        'DATABASE_URL': 'postgresql://db/one',
        'ANOTHER_KEY': 'another value',
      });
    });

    testWidgets(
      'Workers tab add flow persists environment variables and toggle state',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

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
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-add-button')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('workers-editor-name-field')),
          'Queue worker',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-command-field')),
          'npm run worker:queue',
        );
        await tester.tap(
          find.byKey(const Key('workers-editor-enabled-toggle')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          'DATABASE_URL=postgresql://db/one',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-editor-save-button')));
        await tester.pumpAndSettle();

        final records = await WorkerInstanceRepository(
          database,
        ).listForProject(selectedProject.id);
        expect(records, hasLength(1));
        final saved = records.single;
        expect(saved.enabled, isFalse);
        expect(saved.environment, {'DATABASE_URL': 'postgresql://db/one'});
      },
    );

    testWidgets(
      'Workers editor clears the environment when the box is emptied',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

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
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-add-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workers-editor-name-field')),
          'Queue worker',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-command-field')),
          'npm run worker:queue',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          'DATABASE_URL=postgresql://db/one',
        );
        await tester.pumpAndSettle();
        expect(find.text('1 variable'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          '',
        );
        await tester.pumpAndSettle();
        expect(find.text('1 variable'), findsNothing);

        await tester.tap(find.byKey(const Key('workers-editor-save-button')));
        await tester.pumpAndSettle();

        final records = await WorkerInstanceRepository(
          database,
        ).listForProject(selectedProject.id);
        expect(records.single.environment, isEmpty);
      },
    );

    testWidgets(
      'Workers editor blocks saving while the environment box has an error',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

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
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(
              selectedProjectWithLiveRuntime,
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-add-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workers-editor-name-field')),
          'Queue worker',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-command-field')),
          'npm run worker:queue',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          'GOOD=1\nNOT A VARIABLE',
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Line 2'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('workers-editor-save-button')),
              )
              .onPressed,
          isNull,
        );

        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          'GOOD=1\nFIXED=2',
        );
        await tester.pumpAndSettle();

        expect(find.text('2 variables'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('workers-editor-save-button')),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('Workers editor cancel closes the dialog', (
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
        overrides: [
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithLiveRuntime,
          ),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workers-add-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets(
      'Workers tab removes readiness and database controls from the workspace surface',
      (WidgetTester tester) async {
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

        expect(
          find.byKey(const Key('workers-refresh-status-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('workers-refresh-db-users-button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('workers-refresh-precheck-button')),
          findsNothing,
        );
        expect(find.byKey(const Key('workers-open-web-app-cta')), findsNothing);
        expect(
          find.byKey(const Key('workers-open-database-cta')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('workers-db-users-state-text')),
          findsNothing,
        );
        expect(find.text('SSH ready'), findsNothing);
        expect(find.text('Image ready'), findsNothing);
        expect(find.textContaining('PostgreSQL'), findsNothing);

        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('workers-add-button')))
              .onPressed,
          isNotNull,
        );
        expect(
          find.byKey(const Key('workers-apply-runtime-button')),
          findsNothing,
        );
      },
    );

    testWidgets('Workers tab does not discover database users during bind', (
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
        operationOutcomesByKey: <String, List<Object>>{
          'postgres/project_list': <Object>[Exception('db users exploded')],
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

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      expect(sshService.projectListCalls, 0);
      expect(find.byKey(const Key('workers-overview-card')), findsOneWidget);
    });

    testWidgets(
      'Workers tab add flow resolves id collisions and surfaces save failures',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        var databaseClosed = false;
        addTearDown(() async {
          if (!databaseClosed) {
            await database.close();
          }
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
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-add-button')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('workers-editor-name-field')),
          'Queue worker',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-command-field')),
          'npm run worker:priority',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-cpu-field')),
          '2.5',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-memory-field')),
          '1024',
        );
        await tester.enterText(
          find.byKey(const Key('workers-editor-disk-field')),
          '4096',
        );
        await tester.pumpAndSettle();

        final saveButton = tester.widget<FilledButton>(
          find.byKey(const Key('workers-editor-save-button')),
        );
        expect(saveButton.onPressed, isNotNull);

        await database.close();
        databaseClosed = true;
        await tester.tap(find.byKey(const Key('workers-editor-save-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('workers-error-text')), findsOneWidget);
        expect(
          find.byKey(const Key('worker-row-queue-worker-2')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Workers tab makes no user-list calls when re-entering the tab',
      (WidgetTester tester) async {
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
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        final initialProjectListCalls = sshService.projectListCalls;

        await tester.tap(find.widgetWithText(Tab, 'Web app'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();

        expect(sshService.projectListCalls, initialProjectListCalls);
      },
    );

    testWidgets(
      'Workers workspace keeps environment values inside the worker editor modal',
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
              environment: const {'DATABASE_URL': 'postgresql://db/one'},
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
                  'runtime': {'state': 'running', 'status': 'Up 2s'},
                },
              ],
              'orphans': <dynamic>[],
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
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();

        final row = find.byKey(const Key('worker-row-queue-worker'));
        expect(
          find.descendant(
            of: row,
            matching: find.textContaining('postgresql://db/one'),
          ),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('worker-edit-queue-worker')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('workers-editor-environment-field')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('workers-editor-environment-field')),
              )
              .controller
              ?.text,
          'DATABASE_URL=postgresql://db/one',
        );
      },
    );

    testWidgets(
      'Workers tab edit flow updates worker fields and persists environment edits',
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
                  'runtime': {'state': 'running', 'status': 'Up 2s'},
                },
              ],
              'orphans': <dynamic>[],
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
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('worker-edit-queue-worker')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('workers-editor-name-field')),
          'Queue worker updated',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workers-editor-command-field')),
          'npm run worker:priority',
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('workers-editor-environment-field')),
          'DATABASE_URL=postgresql://db/one',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('workers-editor-save-button')));
        await tester.pumpAndSettle();

        final records = await WorkerInstanceRepository(
          database,
        ).listForProject(selectedProject.id);
        expect(records, hasLength(1));
        final saved = records.single;
        expect(saved.name, 'Queue worker updated');
        expect(saved.startCommand, 'npm run worker:priority');
        expect(saved.environment, {'DATABASE_URL': 'postgresql://db/one'});
      },
    );

    testWidgets('Workers tab toggle and delete flows persist changes', (
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
                'runtime': {'state': 'running', 'status': 'Up 2s'},
              },
            ],
            'orphans': <dynamic>[],
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
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      final row = find.byKey(const Key('worker-row-queue-worker'));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();

      var records = await WorkerInstanceRepository(
        database,
      ).listForProject(selectedProject.id);
      final byId = {for (final record in records) record.id: record};
      expect(byId['queue-worker']?.enabled, isFalse);
      expect(byId['email-worker']?.enabled, isTrue);

      await tester.tap(find.byKey(const Key('worker-delete-queue-worker')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('worker-row-queue-worker')), findsOneWidget);

      await tester.tap(find.byKey(const Key('worker-delete-queue-worker')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('worker-row-queue-worker')), findsNothing);
      records = await WorkerInstanceRepository(
        database,
      ).listForProject(selectedProject.id);
      expect(records, hasLength(1));
      expect(records.single.id, 'email-worker');
    });

    testWidgets('Empty-state add reports the empty-state control', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      final analytics = FakeAnalyticsService();
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
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithLiveRuntime,
          ),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
          appAnalyticsServiceProvider.overrideWithValue(analytics),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();

      // Fully empty: no toolbar mounts, so the empty-state button is the
      // only add action on screen.
      expect(find.byKey(const Key('workers-empty-state-text')), findsOneWidget);
      await tester.tap(find.byKey(const Key('workers-add-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workers-editor-name-field')),
        findsOneWidget,
        reason: 'the tap still opens the editor',
      );
      expect(analytics.controlUses, [
        (control: AppControl.emptyStateAction, tab: null),
      ]);
    });

    testWidgets('Worker applies report the worker event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      await _pumpWorkersWithOneSavedWorker(tester, analytics: analytics);

      await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
      await tester.pumpAndSettle();

      // The success message is a transient snackbar; the durable signal is
      // the apply button hiding once there is nothing left to apply (it
      // stays visible on every failure path).
      expect(
        find.byKey(const Key('workers-apply-runtime-button')),
        findsNothing,
      );
      expect(analytics.workerEvents, [
        (action: WorkerAction.apply, outcome: DataOperationOutcome.success),
      ]);
    });

    testWidgets('Worker apply failures report the worker event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      await _pumpWorkersWithOneSavedWorker(
        tester,
        analytics: analytics,
        applyResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Engine refused the apply.',
        },
      );

      await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
      await tester.pumpAndSettle();

      expect(analytics.workerEvents, [
        (action: WorkerAction.apply, outcome: DataOperationOutcome.failure),
      ]);
    });

    testWidgets('Worker apply throws report the worker event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      await _pumpWorkersWithOneSavedWorker(
        tester,
        analytics: analytics,
        operationOutcomesByKey: <String, List<Object>>{
          'app/workers_apply': <Object>[StateError('ssh unavailable')],
        },
      );

      await tester.tap(find.byKey(const Key('workers-apply-runtime-button')));
      await tester.pumpAndSettle();

      expect(analytics.workerEvents, [
        (action: WorkerAction.apply, outcome: DataOperationOutcome.failure),
      ]);
    });
  }, skip: !sqliteAvailable);
}
