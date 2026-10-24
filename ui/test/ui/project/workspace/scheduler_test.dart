import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace scheduler tab.
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

  group('project workspace scheduler tab', () {
    testWidgets('Scheduler blocks new custom jobs before a live app release', (
      WidgetTester tester,
    ) async {
      final selectedDestinationIds = <String>[];
      await pumpProjectWorkspace(
        tester,
        child: ProjectWorkspace(
          onDestinationSelected: selectedDestinationIds.add,
        ),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
        ],
      );

      await tester.tap(
        find.byKey(const Key('project-workspace-nav-scheduler')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('scheduler-app-runtime-required-callout')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('scheduler-add-task-button')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('scheduler-empty-state')), findsOneWidget);
      expect(
        find.byKey(const Key('scheduler-add-task-button')),
        findsOneWidget,
      );
      expect(
        find.text('No built-in schedules are registered yet.'),
        findsNothing,
      );
      expect(find.text('No recent activity yet.'), findsNothing);

      await tester.tap(
        find.byKey(const Key('project-open-web-app-tab-button')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-tab-scroll')), findsOneWidget);
      expect(selectedDestinationIds, ['scheduler', 'web-app']);
    });

    testWidgets('Scheduler tab creates and runs a custom task', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });

      final sshService = SchedulerWorkflowSshService();
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

      await tester.tap(find.widgetWithText(Tab, 'Scheduler'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('scheduler-editor-name-field')),
        'Queue health check',
      );
      await tester.enterText(
        find.byKey(const Key('scheduler-editor-command-field')),
        'php -v',
      );
      await tester.enterText(
        find.byKey(const Key('scheduler-editor-interval-field')),
        '5',
      );

      await tester.tap(find.byKey(const Key('scheduler-editor-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Queue health check'), findsOneWidget);
      expect(find.text('php -v'), findsOneWidget);
      expect(sshService.upsertCalls, greaterThan(0));
      expect(sshService.lastUpsertSettings?['command'], 'php -v');
      final savedTasks = await SchedulerTaskRepository(
        database,
      ).listTasksForProject(selectedProject.id);
      expect(savedTasks.single.command, 'php -v');

      await tester.tap(
        find.byKey(const Key('scheduler-run-now-queue-health-check')),
      );
      await tester.pumpAndSettle();

      expect(sshService.runNowCalls, greaterThan(0));
      expect(sshService.lastRunNowSettings?['command'], 'php -v');
      expect(sshService.lastRunNowSettings?['target_type'], 'web_app');
      final statusTasks = sshService.lastStatusSettings?['tasks'];
      expect(statusTasks, isA<List<dynamic>>());
      final statusTask =
          (statusTasks as List<dynamic>).single as Map<String, dynamic>;
      expect(statusTask['command'], 'php -v');
      expect(statusTask['target_type'], 'web_app');
      final runs = await SchedulerTaskRepository(
        database,
      ).listRunsForProject(selectedProject.id);
      final completedRun = runs.singleWhere((run) => run.status == 'completed');
      expect(completedRun.message, 'PHP 8.3.1');
      final afterRunTasks = await SchedulerTaskRepository(
        database,
      ).listTasksForProject(selectedProject.id);
      expect(afterRunTasks.single.lastKnownMessage, 'success');
      expect(afterRunTasks.single.lastRunAt, isNotNull);
    });

    testWidgets(
      'Scheduler editor keeps footer actions visible while scrolling',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async {
          await database.close();
        });

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
            sshServiceProvider.overrideWithValue(SchedulerWorkflowSshService()),
          ],
        );

        await tester.tap(find.widgetWithText(Tab, 'Scheduler'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('scheduler-add-task-button')));
        await tester.pumpAndSettle();

        final saveButton = find.byKey(
          const Key('scheduler-editor-save-button'),
        );
        expect(saveButton, findsOneWidget);
        final initialSaveTop = tester.getTopLeft(saveButton).dy;

        await tester.drag(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(SingleChildScrollView),
          ),
          const Offset(0, -500),
        );
        await tester.pumpAndSettle();

        expect(saveButton, findsOneWidget);
        expect(tester.getTopLeft(saveButton).dy, initialSaveTop);
      },
    );

    testWidgets('Scheduler run now failure shows actionable details', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await SchedulerTaskRepository(database).upsertTask(
        const SchedulerTaskRecord(
          id: 'queue-health-check',
          projectId: 'project-runtime',
          name: 'Queue health check',
          targetType: 'web_app',
          command: 'php -v',
          scheduleType: 'every_minutes',
          intervalValue: 5,
        ),
      );

      final sshService = SchedulerWorkflowSshService(
        runNowResponse: const <String, dynamic>{
          'status': 'error',
          'msg': 'Start scheduler task service failed.',
          'details': 'systemd reported exit code 127: php was not found.',
        },
      );
      final terminalLines = <String>['Deploy summary: failed • old deploy'];
      await pumpProjectWorkspace(
        tester,
        database: database,
        child: ProjectWorkspace(
          initialTabIndex: 6,
          onTerminalLine:
              (line, {source = 'scheduler', taskType, detail = false}) {
                terminalLines.add(line);
              },
        ),
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );

      await tester.tap(find.widgetWithText(Tab, 'Scheduler'));
      await tester.pumpAndSettle();
      expect(find.text('php -v'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('scheduler-run-now-queue-health-check')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Scheduled job did not start'), findsOneWidget);
      expect(
        find.textContaining('systemd reported exit code 127'),
        findsWidgets,
      );
      expect(find.text('Start scheduler task service failed.'), findsNothing);

      await tester.tap(
        find.byKey(const Key('scheduler-action-error-ok-button')),
      );
      await tester.pumpAndSettle();

      final runs = await SchedulerTaskRepository(
        database,
      ).listRunsForProject(selectedProject.id);
      expect(runs.single.status, 'failed');
      expect(runs.single.message, contains('systemd reported exit code 127'));
      expect(await AppReleaseRepository(database).listFailedJournal(), isEmpty);
      expect(
        terminalLines.last,
        contains('Scheduled job "Queue health check" did not start:'),
      );
      expect(terminalLines.last, contains('php was not found'));
      expect(terminalLines.last, isNot(contains('old deploy')));
    });

    testWidgets('Scheduler failed run journal replays after restart', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await SchedulerTaskRepository(database).upsertTask(
        const SchedulerTaskRecord(
          id: 'queue-health-check',
          projectId: 'project-runtime',
          name: 'Queue health check',
          targetType: 'web_app',
          command: 'php -v',
          scheduleType: 'every_minutes',
          intervalValue: 5,
        ),
      );
      final appRepository = AppReleaseRepository(database);
      final journal = await appRepository.createJournalEntry(
        projectId: selectedProject.id,
        serverId: serverWithRuntimeCredentials.id,
        surface: 'scheduler',
        operationType: 'task_run_now',
        request: const <String, dynamic>{
          'workflow_id': 'scheduler',
          'operation_id': 'task_run_now',
          'task_id': 'queue-health-check',
        },
      );
      await appRepository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: const <String, dynamic>{
          'status': 'error',
          'msg': 'systemd reported exit code 127: php was not found.',
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
          sshServiceProvider.overrideWithValue(SchedulerWorkflowSshService()),
        ],
      );

      final runs = await SchedulerTaskRepository(
        database,
      ).listRunsForProject(selectedProject.id);
      expect(runs.single.status, 'failed');
      expect(runs.single.message, contains('php was not found'));
      expect(await appRepository.listFailedJournal(), isEmpty);
    });
  }, skip: !sqliteAvailable);
}
