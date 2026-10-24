import 'package:flutter_test/flutter_test.dart';
import 'package:ui/providers/scheduler_task_provider.dart';
import 'package:ui/providers/worker_instance_provider.dart';

import '_support/project_workspace_harness.dart';

/// project workspace settings tab.
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

  group('project workspace settings tab', () {
    testWidgets('Settings tab uses red destructive styling', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);

      await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();

      final deleteIcon = tester.widget<Icon>(
        find.byKey(const Key('settings-delete-icon')),
      );
      final deleteText = tester.widget<Text>(
        find.byKey(const Key('settings-delete-text')),
      );

      expect(deleteIcon.color, YaruColors.red);
      expect(deleteText.style?.color, YaruColors.red);
      expect(find.byKey(const Key('settings-delete-button')), findsOneWidget);
    });

    testWidgets('Settings tab deletes project and runs teardown workflows', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      final projectRepository = ProjectRepository(database);
      await projectRepository.createProject(
        Project(
          id: selectedProject.id,
          name: selectedProject.name,
          type: selectedProject.type,
          gitUrl: selectedProject.gitUrl,
          primaryDomain: selectedProject.primaryDomain,
          repositoryFullName: selectedProject.repositoryFullName,
          appSubdirectory: selectedProject.appSubdirectory,
          deployBranch: selectedProject.deployBranch,
          appPort: selectedProject.appPort,
          railpackBuildCommand: selectedProject.railpackBuildCommand,
          railpackRunCommand: selectedProject.railpackRunCommand,
          railpackNodeMode: selectedProject.railpackNodeMode,
          tlsChallengeMode: selectedProject.tlsChallengeMode,
          tlsDnsProvider: selectedProject.tlsDnsProvider,
          tlsDnsCredentials: selectedProject.tlsDnsCredentials,
          appDisconnected: selectedProject.appDisconnected,
          isActive: true,
        ),
      );

      final schedulerRepository = SchedulerTaskRepository(database);
      await schedulerRepository.upsertTask(
        SchedulerTaskRecord(
          id: 'custom-task-1',
          projectId: selectedProject.id,
          name: 'Custom task',
          targetType: 'host',
          command: 'echo ok',
          scheduleType: 'every_minutes',
          intervalValue: 5,
          managedByService: false,
        ),
      );
      await schedulerRepository.upsertTask(
        SchedulerTaskRecord(
          id: 'managed-task-1',
          projectId: selectedProject.id,
          sourceType: 'service',
          managedByService: true,
          name: 'Managed backup task',
          targetType: 'host',
          command: 'Managed backup',
          scheduleType: 'daily_at',
          dailyTime: '02:00',
        ),
      );

      final backupRepository = BackupRepository(database);
      await backupRepository.upsertPolicy(
        BackupPolicyRecord(
          id: 'daily-main',
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
          name: 'Daily Main',
          destinationId: 'dest-1',
          databaseName: 'dd_regs_v3_app',
          scheduleMode: 'daily_once',
          time1Hhmm: '02:00',
          managedTaskId: 'managed-task-1',
        ),
      );
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

      final sshService = ProjectDeleteWorkflowSshService();
      addTearDown(sshService.dispose);
      await ServerCredentialRepository(database).write(
        reference: serverWithDatabaseEnabled.credentialReference,
        sshPassword: 'postgres-password',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();

      // D-53 characterization: load the in-memory provider states so the
      // post-delete forget assertions below are non-vacuous.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectWorkspace)),
      );
      await container
          .read(projectSchedulerProvider.notifier)
          .loadProject(selectedProject.id);
      await container
          .read(projectBackupProvider.notifier)
          .loadScope(
            projectId: selectedProject.id,
            serverId: serverWithDatabaseEnabled.id,
          );
      await container
          .read(projectWorkerInstancesProvider.notifier)
          .loadProject(selectedProject.id);
      expect(
        container
            .read(projectSchedulerProvider)
            .tasksForProject(selectedProject.id),
        isNotEmpty,
      );
      expect(
        container
            .read(projectBackupProvider)
            .scopes
            .keys
            .any((key) => key.startsWith('${selectedProject.id}::')),
        isTrue,
      );
      expect(
        container.read(projectWorkerInstancesProvider)[selectedProject.id],
        isNotNull,
      );
      expect(container.read(selectedProjectIdProvider), isNotEmpty);

      await tester.tap(find.byKey(const Key('settings-delete-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings-delete-confirm-dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('settings-delete-confirm-input')),
        selectedProject.name,
      );
      await tester.tap(
        find.byKey(const Key('settings-delete-confirm-checkbox')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
      await tester.pumpAndSettle();

      final remainingProjects = await projectRepository.listProjects();
      expect(remainingProjects, isEmpty);
      expect(
        await schedulerRepository.listTasksForProject(selectedProject.id),
        isEmpty,
      );
      expect(
        await backupRepository.listPoliciesForScope(
          projectId: selectedProject.id,
          serverId: serverWithDatabaseEnabled.id,
        ),
        isEmpty,
      );

      expect(sshService.countCalls('app', 'disconnect'), 1);
      expect(sshService.countCalls('postgres', 'backup_policy_delete'), 1);
      expect(sshService.countCalls('scheduler', 'task_delete'), 1);
      expect(sshService.countCalls('postgres', 'project_delete'), 2);
      final deleteCalls = sshService.callLog
          .where(
            (call) =>
                call['workflow_id'] == 'postgres' &&
                call['operation_id'] == 'project_delete',
          )
          .toList(growable: false);
      final dryRunParams = deleteCalls[0]['params'] as Map<String, dynamic>;
      expect(dryRunParams['dry_run'], isTrue);
      final executeParams = deleteCalls[1]['params'] as Map<String, dynamic>;
      expect(executeParams['dry_run'], isFalse);
      final executeSettings = executeParams['settings'] as Map<String, dynamic>;
      expect(executeSettings['confirmed_databases'], isEmpty);
      expect(executeSettings['confirmed_users'], isEmpty);

      // D-53 characterization: delete forgets the project's in-memory
      // provider states and clears the explicit selection.
      expect(
        container
            .read(projectSchedulerProvider)
            .tasksForProject(selectedProject.id),
        isEmpty,
      );
      expect(
        container
            .read(projectBackupProvider)
            .scopes
            .keys
            .any((key) => key.startsWith('${selectedProject.id}::')),
        isFalse,
      );
      expect(
        container.read(projectWorkerInstancesProvider)[selectedProject.id],
        isNull,
      );
      expect(container.read(selectedProjectIdProvider), isEmpty);
    });

    testWidgets('Settings tab clears explicit selection and requests Home', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      final projectRepository = ProjectRepository(database);
      await projectRepository.createProject(
        Project(
          id: selectedProject.id,
          name: selectedProject.name,
          type: selectedProject.type,
          gitUrl: selectedProject.gitUrl,
          primaryDomain: selectedProject.primaryDomain,
          repositoryFullName: selectedProject.repositoryFullName,
          appSubdirectory: selectedProject.appSubdirectory,
          deployBranch: selectedProject.deployBranch,
          appPort: selectedProject.appPort,
          railpackBuildCommand: selectedProject.railpackBuildCommand,
          railpackRunCommand: selectedProject.railpackRunCommand,
          railpackNodeMode: selectedProject.railpackNodeMode,
          tlsChallengeMode: selectedProject.tlsChallengeMode,
          tlsDnsProvider: selectedProject.tlsDnsProvider,
          tlsDnsCredentials: selectedProject.tlsDnsCredentials,
          appDisconnected: selectedProject.appDisconnected,
          isActive: true,
        ),
      );
      await projectRepository.createProject(
        const Project(
          id: 'project-secondary',
          name: 'Secondary App',
          type: 'Web app',
          gitUrl: 'https://github.com/example/secondary',
          primaryDomain: 'secondary.example.com',
          deployBranch: 'main',
          appPort: 3000,
          railpackBuildCommand: 'npm run build',
          railpackRunCommand: 'npm run start',
          railpackNodeMode: 'auto',
          tlsChallengeMode: 'http',
          appDisconnected: false,
          isActive: false,
        ),
      );

      var openedHome = false;
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: ProjectWorkspace(
          onProjectDeleted: (outcome) {
            openedHome = true;
          },
        ),
        overrides: [
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
        ],
      );

      await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-delete-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('settings-delete-confirm-input')),
        selectedProject.name,
      );
      await tester.tap(
        find.byKey(const Key('settings-delete-confirm-checkbox')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProjectWorkspace)),
      );
      expect(openedHome, isTrue);
      expect(container.read(selectedProjectIdProvider), isEmpty);

      final remainingProjects = await projectRepository.listProjects();
      expect(remainingProjects.map((project) => project.id), [
        'project-secondary',
      ]);
    });

    testWidgets('Settings tab delete failure keeps current settings view', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      final sshService = ProjectDeleteWorkflowSshService();
      addTearDown(sshService.dispose);
      await ServerCredentialRepository(database).write(
        reference: serverWithDatabaseEnabled.credentialReference,
        sshPassword: 'postgres-password',
      );
      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectListProvider.overrideWith(DeleteFailureProjectNotifier.new),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-delete-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('settings-delete-confirm-input')),
        selectedProject.name,
      );
      await tester.tap(
        find.byKey(const Key('settings-delete-confirm-checkbox')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-delete-confirm-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings-delete-button')), findsOneWidget);
      expect(
        find.byKey(const Key('settings-delete-error-text')),
        findsOneWidget,
      );
    });

    testWidgets('Settings tab delete dialog cancel leaves project untouched', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          projectListProvider.overrideWith(DeleteSuccessProjectNotifier.new),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
        ],
      );

      await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
      await tester.tap(find.widgetWithText(Tab, 'Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('settings-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings-delete-confirm-dialog')),
        findsNothing,
      );
      expect(find.byKey(const Key('settings-delete-button')), findsOneWidget);
    });

    testWidgets(
      'Settings tab stops deletion when project selection changes during confirmation',
      (WidgetTester tester) async {
        final sshService = ProjectDeleteWorkflowSshService();
        addTearDown(sshService.dispose);
        await pumpProjectWorkspace(
          tester,
          overrides: [
            selectedProjectProvider.overrideWith(
              (ref) => ref.watch(mutableSelectedProjectProvider),
            ),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProjectWorkspace)),
        );

        await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
        await tester.tap(find.widgetWithText(Tab, 'Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-delete-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-delete-confirm-input')),
          selectedProject.name,
        );
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-checkbox')),
        );
        await tester.pumpAndSettle();

        container
            .read(mutableSelectedProjectProvider.notifier)
            .select(
              const Project(
                id: 'project-other',
                name: 'Other App',
                type: 'Web app',
                gitUrl: '',
                primaryDomain: 'other.example.com',
              ),
            );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Project selection changed before deletion started',
          ),
          findsOneWidget,
        );
        expect(sshService.callLog, isEmpty);
      },
    );

    testWidgets(
      'Settings tab preserves cleanup recovery when no server is selected',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

        ProjectDeletionOutcome? deletionOutcome;
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: ProjectWorkspace(
            onProjectDeleted: (outcome) => deletionOutcome = outcome,
          ),
          overrides: [
            projectListProvider.overrideWith(DeleteSuccessProjectNotifier.new),
            selectedServerProvider.overrideWithValue(null),
          ],
        );

        await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
        await tester.tap(find.widgetWithText(Tab, 'Settings'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('settings-delete-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-delete-confirm-input')),
          selectedProject.name,
        );
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-checkbox')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-button')),
        );
        await tester.pumpAndSettle();

        expect(deletionOutcome?.completed, isFalse);
        expect(deletionOutcome?.messages.single, contains('not available'));
        final recovery = await ProjectDeletionRecoveryRepository(
          database,
        ).getRecovery(selectedProject.id);
        expect(recovery, isNotNull);
        expect(recovery?.status, 'cleanup_failed');
        expect(recovery?.steps.single.id, 'connection');
      },
    );

    testWidgets(
      'Settings tab warns when SSH key server has no key path configured',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            projectListProvider.overrideWith(DeleteSuccessProjectNotifier.new),
            selectedServerProvider.overrideWithValue(
              serverWithMissingSshKeyPath,
            ),
          ],
        );

        await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
        await tester.tap(find.widgetWithText(Tab, 'Settings'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('settings-delete-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-delete-confirm-input')),
          selectedProject.name,
        );
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-checkbox')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('This server connection needs to be reconnected'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Settings tab uses SSH key connection payload and fallback warning message',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

        final sshService = DeleteFallbackMessageSshService();
        addTearDown(sshService.dispose);
        await ServerCredentialRepository(database).write(
          reference: serverWithSshKeyEnabled.credentialReference,
          privateKey:
              '-----BEGIN OPENSSH PRIVATE KEY-----\n'
              'test-private-key\n'
              '-----END OPENSSH PRIVATE KEY-----',
        );
        await pumpProjectWorkspace(
          tester,
          database: database,
          overrides: [
            projectListProvider.overrideWith(DeleteSuccessProjectNotifier.new),
            selectedServerProvider.overrideWithValue(serverWithSshKeyEnabled),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
        await tester.tap(find.widgetWithText(Tab, 'Settings'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('settings-delete-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-delete-confirm-input')),
          selectedProject.name,
        );
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-checkbox')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-button')),
        );
        await tester.pumpAndSettle();

        final disconnectCall = sshService.callLog.firstWhere(
          (call) =>
              call['workflow_id'] == 'app' &&
              call['operation_id'] == 'disconnect',
        );
        final connection = disconnectCall['connection'] as Map<String, dynamic>;
        expect(
          connection['private_key'],
          '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          'test-private-key\n'
          '-----END OPENSSH PRIVATE KEY-----',
        );
        expect(connection.containsKey('key_path'), isFalse);
        expect(connection.containsKey('password'), isFalse);
        final recovery = await ProjectDeletionRecoveryRepository(
          database,
        ).getRecovery(selectedProject.id);
        final appStep = recovery?.steps.singleWhere(
          (step) => step.id == 'app_runtime',
        );
        expect(appStep?.status, ProjectDeletionStepStatus.failed);
        expect(appStep?.message, 'Cleanup did not finish.');
      },
    );

    testWidgets(
      'Settings tab persists backup and scheduler discovery failures',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

        final sshService = ProjectDeleteWorkflowSshService();
        addTearDown(sshService.dispose);
        await ServerCredentialRepository(database).write(
          reference: serverWithDatabaseEnabled.credentialReference,
          sshPassword: 'postgres-password',
        );
        ProjectDeletionOutcome? deletionOutcome;
        await pumpProjectWorkspace(
          tester,
          database: database,
          child: ProjectWorkspace(
            onProjectDeleted: (outcome) => deletionOutcome = outcome,
          ),
          overrides: [
            projectListProvider.overrideWith(DeleteSuccessProjectNotifier.new),
            selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
            backupRepositoryProvider.overrideWithValue(
              ThrowingBackupRepository(database),
            ),
            schedulerTaskRepositoryProvider.overrideWithValue(
              ThrowingSchedulerTaskRepository(database),
            ),
            sshServiceProvider.overrideWithValue(sshService),
          ],
        );

        await tester.ensureVisible(find.widgetWithText(Tab, 'Settings'));
        await tester.tap(find.widgetWithText(Tab, 'Settings'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-delete-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-delete-confirm-input')),
          selectedProject.name,
        );
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-checkbox')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('settings-delete-confirm-button')),
        );
        await tester.pumpAndSettle();

        expect(deletionOutcome?.completed, isFalse);
        expect(
          deletionOutcome?.messages.join('\n'),
          allOf(
            contains('backup scope exploded'),
            contains('scheduler load exploded'),
          ),
        );
        final recovery = await ProjectDeletionRecoveryRepository(
          database,
        ).getRecovery(selectedProject.id);
        expect(
          recovery?.steps
              .where((step) => step.status == ProjectDeletionStepStatus.failed)
              .map((step) => step.id),
          containsAll(<String>['load_backup_plans', 'load_scheduler_tasks']),
        );
      },
    );
  }, skip: !sqliteAvailable);
}
