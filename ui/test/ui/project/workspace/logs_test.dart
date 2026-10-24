import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace logs tab.
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

  group('project workspace logs tab', () {
    testWidgets('Log tab renders runtime and deployment tabs', (
      WidgetTester tester,
    ) async {
      await pumpProjectWorkspace(tester);
      await openProjectWorkspaceDestination(tester, 'log');

      expect(find.byKey(const Key('app-log-card')), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Web app runtime'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Deployment log'), findsOneWidget);
      expect(find.byKey(const Key('runtime-log-empty-state')), findsOneWidget);
      expect(find.text('No runtime logs yet'), findsOneWidget);
    });

    testWidgets('Runtime logs support filtering and clear action', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await seedLogs(
        database,
        rows:
            <
              ({
                DateTime createdAt,
                String message,
                String renderedLine,
                String source,
                String? taskType,
              })
            >[
              (
                renderedLine: '[srv 10:00:00] runtime alpha',
                message: 'runtime alpha',
                source: 'app_runtime',
                taskType: 'app_runtime_logs',
                createdAt: DateTime(2026, 2, 20, 10, 0, 0),
              ),
              (
                renderedLine: '[srv 10:00:01] runtime beta',
                message: 'runtime beta',
                source: 'app_runtime',
                taskType: 'app_runtime_logs',
                createdAt: DateTime(2026, 2, 20, 10, 0, 1),
              ),
              (
                renderedLine: '[srv 10:00:01] Connecting to server over SSH',
                message: 'Connecting to server over SSH',
                source: 'terminal',
                taskType: 'app_runtime_logs',
                createdAt: DateTime(2026, 2, 20, 10, 0, 1),
              ),
              (
                renderedLine: '[srv 10:00:02] deployment gamma',
                message: 'deployment gamma',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 0, 2),
              ),
            ],
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(RuntimeWorkflowSshService()),
        ],
      );
      await openProjectWorkspaceDestination(tester, 'log');
      expect(find.widgetWithText(Tab, 'Web app runtime'), findsOneWidget);

      expect(find.textContaining('runtime alpha'), findsOneWidget);
      expect(find.textContaining('runtime beta'), findsOneWidget);
      expect(
        find.textContaining('Connecting to server over SSH'),
        findsNothing,
      );

      await tester.enterText(find.byKey(const Key('log-filter-field')), 'beta');
      await tester.pumpAndSettle();
      expect(find.textContaining('runtime alpha'), findsNothing);
      expect(find.textContaining('runtime beta'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('log-filter-field')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('runtime alpha'), findsOneWidget);
      expect(find.textContaining('runtime beta'), findsOneWidget);
      expect(
        find.textContaining('Connecting to server over SSH'),
        findsNothing,
      );
    });

    testWidgets('Deployment logs support filtering and clear action', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async {
        await database.close();
      });
      await seedLogs(
        database,
        rows:
            <
              ({
                DateTime createdAt,
                String message,
                String renderedLine,
                String source,
                String? taskType,
              })
            >[
              (
                renderedLine: '[srv 10:09:58] Starting web app deploy.',
                message: 'Starting web app deploy.',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 9, 58),
              ),
              (
                renderedLine: '[srv 10:09:59] old deploy failed',
                message: 'old deploy failed',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 9, 59),
              ),
              (
                renderedLine: '[srv 10:10:00] Starting web app deploy.',
                message: 'Starting web app deploy.',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 10, 0),
              ),
              (
                renderedLine:
                    '[srv 10:10:01] __DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=secret',
                message:
                    '__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=secret',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 10, 1),
              ),
              (
                renderedLine: '[srv 10:10:02] deploy success',
                message: 'Deploy summary: succeeded',
                source: 'app_deploy',
                taskType: 'app_deploy',
                createdAt: DateTime(2026, 2, 20, 10, 10, 2),
              ),
            ],
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(serverWithDatabaseEnabled),
          sshServiceProvider.overrideWithValue(RuntimeWorkflowSshService()),
        ],
      );
      await openProjectWorkspaceDestination(tester, 'log');
      await tester.tap(find.widgetWithText(Tab, 'Deployment log'));
      await tester.pumpAndSettle();

      expect(find.textContaining('deploy success'), findsOneWidget);
      expect(find.textContaining('old deploy failed'), findsNothing);
      expect(
        find.textContaining('REPOSITORY_HOST_KEY_CONFIRMATION'),
        findsNothing,
      );
      expect(find.text('Latest deployment succeeded'), findsOneWidget);
      expect(
        find.byKey(const Key('deployment-log-latest-outcome')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('deployment-log-filter-field')),
        'success',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Starting web app deploy'), findsNothing);
      expect(find.textContaining('deploy success'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('deployment-log-filter-field')),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('deploy success'), findsOneWidget);
      expect(find.textContaining('old deploy failed'), findsNothing);
    });

    testWidgets('Runtime fetch and live stream toggle update runtime status', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      await pumpProjectWorkspace(
        tester,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      await openProjectWorkspaceDestination(tester, 'log');

      expect(sshService.runtimeLogCalls, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Fetch runtime logs'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Runtime logs captured.'), findsWidgets);
      expect(find.textContaining('app booted'), findsOneWidget);
      expect(find.textContaining('request finished'), findsOneWidget);
      expect(find.textContaining('runtime-event-alpha'), findsNothing);
      expect(find.textContaining('runtime-event-beta'), findsNothing);
      expect(find.textContaining('Connecting to'), findsNothing);
      expect(sshService.runtimeLogCalls, 1);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.text('Keeping app activity up to date...'), findsOneWidget);
      expect(find.textContaining('Next refresh in'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(find.text('Runtime log streaming paused.'), findsOneWidget);
      expect(find.textContaining('Next refresh in'), findsNothing);
    });
  }, skip: !sqliteAvailable);
}
