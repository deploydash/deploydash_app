import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace shell.
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

  group('project workspace shell', () {
    test('Database action feedback is scoped, normalized, and clearable', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(
        projectDatabaseActionFeedbackProvider.notifier,
      );

      expect(
        container
            .read(projectDatabaseActionFeedbackProvider)
            .forScope(
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
            ),
        isNull,
      );
      notifier.showFailure(
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        message: '  SQL restore failed.  ',
        details: '  psql failed  ',
        title: '  SQL restore failed  ',
      );

      final feedback = container
          .read(projectDatabaseActionFeedbackProvider)
          .forScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          );
      expect(feedback?.message, 'SQL restore failed.');
      expect(feedback?.details, 'psql failed');
      expect(feedback?.title, 'SQL restore failed');
      expect(
        container
            .read(projectDatabaseActionFeedbackProvider)
            .forScope(
              projectId: 'other-project',
              serverId: serverWithDatabaseEnabled.id,
            ),
        isNull,
      );

      notifier.showFailure(
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        message: '  next failure  ',
        details: ' ',
        title: ' ',
      );
      final normalizedEmptyFeedback = container
          .read(projectDatabaseActionFeedbackProvider)
          .forScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          );
      expect(normalizedEmptyFeedback?.details, isNull);
      expect(normalizedEmptyFeedback?.title, isNull);

      notifier.showFailure(
        projectId: '',
        serverId: serverWithDatabaseEnabled.id,
        message: 'ignored',
      );
      notifier.showFailure(
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
        message: ' ',
      );
      expect(
        container
            .read(projectDatabaseActionFeedbackProvider)
            .forScope(
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
            )
            ?.message,
        'next failure',
      );

      notifier.clear(
        projectId: selectedProject.id,
        serverId: serverWithDatabaseEnabled.id,
      );
      notifier.clear(projectId: '', serverId: serverWithDatabaseEnabled.id);
      expect(
        container
            .read(projectDatabaseActionFeedbackProvider)
            .forScope(
              projectId: selectedProject.id,
              serverId: serverWithDatabaseEnabled.id,
            ),
        isNull,
      );
    });

    testWidgets('ProjectWorkspace renders nine tabs', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      expect(find.byKey(const Key('project-workspace-nav-web-app')), findsOne);
      expect(find.text('Workers'), findsAtLeastNWidgets(1));
      expect(find.byKey(const Key('project-workspace-nav-database')), findsOne);
      expect(find.byKey(const Key('project-workspace-nav-email')), findsOne);
      expect(find.byKey(const Key('project-workspace-nav-domain')), findsOne);
      expect(find.byKey(const Key('project-workspace-nav-backup')), findsOne);
      expect(
        find.byKey(const Key('project-workspace-nav-scheduler')),
        findsOne,
      );
      expect(find.byKey(const Key('project-workspace-nav-log')), findsOne);
      expect(find.byKey(const Key('project-workspace-nav-settings')), findsOne);
      expect(find.text('Current web app'), findsOneWidget);

      await tester.tap(find.byKey(const Key('project-workspace-nav-database')));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSemantics(
              find.byKey(const Key('project-workspace-nav-database')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(
              find.byKey(const Key('project-workspace-nav-web-app')),
            )
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      expect(
        find.byKey(
          const Key('project-workspace-nav-database-selection-marker'),
        ),
        findsOneWidget,
      );
      expect(
        find.text('Manage project databases, users, and connection details.'),
        findsNothing,
      );
    });

    testWidgets('ProjectWorkspace reports a contextual destination selection', (
      WidgetTester tester,
    ) async {
      final selectedDestinationIds = <String>[];
      await pumpProjectWorkspace(
        tester,
        child: ProjectWorkspace(
          onDestinationSelected: selectedDestinationIds.add,
        ),
      );

      await tester.tap(find.byKey(const Key('project-workspace-nav-database')));
      await tester.pumpAndSettle();

      expect(selectedDestinationIds, ['database']);
    });

    testWidgets(
      'ProjectWorkspace imports pending server state once into local catalogs',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        await AppReleaseRepository(database).upsertImportState(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          status: 'pending',
        );
        final backupRepository = BackupRepository(database);
        await backupRepository.upsertDestination(
          const BackupDestinationRecord(
            id: 'dest-import',
            projectId: 'project-runtime',
            serverId: 'server-database-enabled',
            name: 'S3',
            type: BackupDestinationType.s3,
            config: {'bucket': 'deploydash-backups'},
          ),
        );
        await backupRepository.upsertPolicy(
          const BackupPolicyRecord(
            id: 'policy-import',
            projectId: 'project-runtime',
            serverId: 'server-database-enabled',
            name: 'Daily',
            destinationId: 'dest-import',
            databaseName: 'dd_regs_v3_app',
            scheduleMode: 'daily_once',
            time1Hhmm: '02:00',
            managedTaskId: 'task-import',
          ),
        );
        await WorkerInstanceRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: const [
            WorkerInstanceRecord(
              id: 'worker-import',
              projectId: 'project-runtime',
              name: 'Indexer',
              startCommand: 'npm run worker',
            ),
          ],
        );
        await SchedulerTaskRepository(database).upsertTask(
          const SchedulerTaskRecord(
            id: 'task-import',
            projectId: 'project-runtime',
            name: 'Import task',
            targetType: 'host',
            command: 'echo imported',
            scheduleType: 'every_minutes',
            intervalValue: 15,
          ),
        );
        final sshService = WorkspaceImportWorkflowSshService();

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

        expect(sshService.countCalls('postgres', 'project_list'), 1);
        expect(sshService.countCalls('app', 'list_releases'), 1);
        // One from the pending-state import. The Backup tab adds a second
        // when it is opened further down this test (G-42).
        expect(sshService.countCalls('postgres', 'backup_artifact_list'), 1);
        expect(sshService.countCalls('app', 'workers_status'), 1);
        expect(sshService.countCalls('scheduler', 'task_status'), 1);

        final appRepository = AppReleaseRepository(database);
        final importState = await appRepository.readImportState(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        );
        expect(importState?.status, 'imported');
        final managedRepository = ProjectManagedDatabaseRepository(database);
        expect(
          (await managedRepository.listDatabasesForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          )).map((row) => row.databaseName),
          ['dd_regs_v3_app'],
        );
        expect(
          (await managedRepository.listUsersForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          )).map((row) => row.username),
          ['dd_regs_user'],
        );
        expect(
          (await appRepository.listReleasesForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          )).map((row) => row.releaseId),
          ['release-import-live'],
        );
        expect(
          (await backupRepository.listArtifactsForScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          )).map((row) => row.remotePath),
          ['s3://deploydash/backups/dd_regs_v3_app.sql.gz'],
        );
        expect(
          (await SchedulerTaskRepository(
            database,
          ).listTasksForProject(selectedProject.id)).single.lastKnownState,
          'active',
        );
        expect(
          (await appRepository.readWorkerRuntimeSnapshot(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          ))?.snapshotJson,
          contains('Indexer'),
        );

        final callsAfterImport = sshService.workflowCalls.length;
        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Workers'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Backup'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Scheduler'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(Tab, 'Web app'));
        await tester.pumpAndSettle();

        // The import itself still runs once -- moving between tabs does not
        // re-run it. The one new call is the Backup tab fetching its artifact
        // list when it opens, which is G-42: the list used to render whatever
        // the previous visit left behind. Asserting which call was added, not
        // just that the count moved.
        expect(sshService.workflowCalls, hasLength(callsAfterImport + 1));
        expect(
          sshService.workflowCalls
              .skip(callsAfterImport)
              .map((call) => call['operation_id'])
              .toList(),
          ['backup_artifact_list'],
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets('ProjectWorkspace makes a failed import retryable', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      await AppReleaseRepository(database).upsertImportState(
        projectId: selectedProject.id,
        serverId: serverWithRuntimeCredentials.id,
        status: 'pending',
      );
      final sshService = FailingWorkspaceImportWorkflowSshService(
        StateError('release inventory unavailable'),
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

      expect(
        find.text(
          'Could not import the latest project state. Saved local state is still available.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('release inventory unavailable'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Retry import'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Retry import'));
      await tester.pumpAndSettle();

      expect(sshService.failedReleaseInventoryAttempts, 2);
    });

    testWidgets('ProjectWorkspace makes failed local repair retryable', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      final releases = ThrowingAppReleaseRepository(
        StateError('journal replay unavailable'),
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          appReleaseRepositoryProvider.overrideWithValue(releases),
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
        ],
      );

      expect(
        find.text(
          'Could not finish repairing saved project state. Saved local state is still available.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('journal replay unavailable'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Retry repair'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Retry repair'));
      await tester.pumpAndSettle();

      expect(releases.remoteSuccessJournalReads, 2);
    });

    testWidgets(
      'ProjectWorkspace replays remote-success database journal locally',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        final appRepository = AppReleaseRepository(database);
        final journal = await appRepository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          surface: 'database',
          operationType: 'project_create_database',
          request: const <String, dynamic>{'database_name': 'journaled_db'},
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{'database_name': 'journaled_db'},
        );
        final sshService = WorkspaceImportWorkflowSshService();

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        expect(sshService.workflowCalls, isEmpty);
        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
        expect(
          (await ProjectManagedDatabaseRepository(
                database,
              ).listDatabasesForScope(
                projectId: selectedProject.id,
                serverId: serverWithDatabaseEnabled.id,
              ))
              .map((row) => row.databaseName),
          ['journaled_db'],
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets(
      'ProjectWorkspace replays remote-success backup restore journals into the database catalog',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        final appRepository = AppReleaseRepository(database);
        final journal = await appRepository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          surface: 'backup',
          operationType: 'restore_run_now',
          request: const <String, dynamic>{
            'engine': 'postgres',
            'policy_id': 'restore-policy',
            'artifact_id': 'restore-artifact',
            'target_database_name': 'restored_after_restart',
          },
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{
            'status': 'success',
            'msg': 'PostgreSQL restore completed.',
            'database_name': 'restored_after_restart',
            'target_database_name': 'dd_runtime_restored_after_restart',
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(
              WorkspaceImportWorkflowSshService(),
            ),
          ],
        );

        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
        expect(
          (await ProjectManagedDatabaseRepository(
                database,
              ).listDatabasesForScope(
                projectId: selectedProject.id,
                serverId: serverWithDatabaseEnabled.id,
              ))
              .map((row) => row.databaseName),
          ['restored_after_restart'],
        );
      },
      skip: !sqliteAvailable,
    );

    testWidgets(
      'ProjectWorkspace replays remote-success backup cleanup journals as cleanup runs',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => database.close());
        final appRepository = AppReleaseRepository(database);
        final journal = await appRepository.createJournalEntry(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          surface: 'backup',
          operationType: 'backup_backlog_cleanup',
          request: const <String, dynamic>{
            'engine': 'postgres',
            'policy_id': 'cleanup-policy',
            'managed_task_id': 'backup-task-cleanup-replay',
          },
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{
            'status': 'success',
            'msg': 'Backup backlog cleaned up.',
          },
        );

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            selectedProjectProvider.overrideWithValue(selectedProject),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(
              WorkspaceImportWorkflowSshService(),
            ),
          ],
        );

        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
        final runs = await BackupRepository(database).listRunsForScope(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        );
        expect(runs, hasLength(1));
        expect(runs.single.operationType, BackupOperationType.cleanup);
        expect(runs.single.policyId, 'cleanup-policy');
        expect(runs.single.status, 'success');
      },
      skip: !sqliteAvailable,
    );

    testWidgets('Database workspace hides removed Milvus references', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();

      expect(find.text('Milvus'), findsNothing);
    });

    testWidgets('ProjectWorkspace switches through tab content', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('database-sqlite-card')), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Workers'));
      await tester.pumpAndSettle();
      expect(find.text('Workers'), findsAtLeastNWidgets(1));
      expect(
        find.byKey(const Key('workers-missing-selection-message')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(Tab, 'Email'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('email-unavailable-state')), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Domain'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('domain-unavailable-state')), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Backup'));
      await tester.pumpAndSettle();
      expect(find.text('Backups'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Scheduler'));
      await tester.pumpAndSettle();
      expect(find.text('Scheduler'), findsAtLeastNWidgets(1));
      await openProjectWorkspaceDestination(tester, 'log');
      expect(find.text('Logs'), findsOneWidget);
      expect(find.text('Deployment log'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Project settings'), findsOneWidget);
    });

    testWidgets(
      'Changing server resets managed engine and section to valid choices',
      (WidgetTester tester) async {
        final serverCatalog = MutableServerCatalogNotifier(
          ServerCatalogState(
            isLoading: false,
            onboardingComplete: true,
            servers: const <Server>[serverWithDatabaseEnabled],
            selectedServerId: serverWithDatabaseEnabled.id,
            onboardingStep: 'connected',
          ),
        );
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
            serverCatalogProvider.overrideWith(() => serverCatalog),
            selectedProjectProvider.overrideWithValue(selectedProject),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );
        await tester.tap(find.widgetWithText(Tab, 'Database'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
        await tester.pumpAndSettle();

        serverCatalog.setSelectedServer(serverWithServicesDisabled);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('database-type-sqlite-tab')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('database-sqlite-card')), findsOneWidget);
      },
    );

    testWidgets('Disabled service tab shows enable services call-to-action', (
      WidgetTester tester,
    ) async {
      var openedServices = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedServerProvider.overrideWithValue(
              serverWithServicesDisabled,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ProjectWorkspace(
                onOpenServerServices: () {
                  openedServices = true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(Tab, 'Email'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('email-unavailable-state')), findsOneWidget);
      expect(
        find.byKey(const Key('email-enable-services-button')),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(Tab, 'Domain'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('domain-unavailable-state')), findsOneWidget);
      expect(
        find.byKey(const Key('domain-enable-services-button')),
        findsNothing,
      );

      await tester.tap(find.widgetWithText(Tab, 'Database'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('database-type-postgres-tab')));
      await tester.pumpAndSettle();

      expect(
        find.text('Database service is disabled for this server.'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('database-open-server-services-button')),
      );
      await tester.pumpAndSettle();
      expect(openedServices, isTrue);
    });
  }, skip: !sqliteAvailable);
}
