import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../../_support/fake_analytics_service.dart';
import '_support/project_workspace_harness.dart';

/// project workspace one-off commands and resources.
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

  group('project workspace one-off commands and resources', () {
    testWidgets(
      'Run one-off command forwards runtime connection and parameters',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..execResponse = <String, dynamic>{
            'status': 'success',
            'msg': 'One-off app command completed.',
            'exit_code': 0,
            'stdout_lines': <String>['Applying migrations'],
            'stderr_lines': <String>[],
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        await tester.enterText(
          find.byKey(const Key('app-oneoff-timeout-field')),
          '900',
        );
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        expect(sshService.execCalls, 1);
        final execCall = sshService.workflowCalls.lastWhere(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'exec',
        );
        final connection = execCall['connection'] as Map<String, dynamic>;
        final params = execCall['params'] as Map<String, dynamic>;
        expect(connection['host'], serverWithRuntimeCredentials.host);
        expect(connection['password'], 'super-secret');
        expect(params['command'], 'npm run db:migrate');
        expect(params['timeout_seconds'], 900);
        expect(find.textContaining('Applying migrations'), findsOneWidget);
        expect(
          find.textContaining('workflow plumbing before command output'),
          findsNothing,
        );
        expect(find.text('One-off app command completed.'), findsOneWidget);
        expect(find.text('Exit code: 0'), findsOneWidget);
      },
    );

    testWidgets(
      'Resource usage refresh persists stats and handles SQLite metadata',
      (WidgetTester tester) async {
        final sqliteProject = selectedProject.copyWith(
          sqliteStorageEnabled: true,
          sqliteVolumeName: null,
          sqliteMountPath: '/var/lib/deploydash/sqlite',
          sqliteFileName: 'main.db',
        );
        final sshService = RuntimeWorkflowSshService()
          ..resourceUsageResponse = <String, dynamic>{
            'status': 'success',
            'resource_usage': <String, dynamic>{
              'Container': 'abc123',
              'Name': 'deploydash_app_buildingregs',
              'CPUPerc': '0.20%',
              'MemPerc': '8.00%',
              'MemUsage': '96MiB / 1GiB',
            },
            'sqlite_storage': <String, dynamic>{
              'enabled': true,
              'volume_name': 'deploydash_sqlite_regs-v3',
              'mount_path': '/var/lib/deploydash/sqlite',
              'file_name': 'main.db',
              'database_path': '/var/lib/deploydash/sqlite/main.db',
              'database_url': 'sqlite:////var/lib/deploydash/sqlite/main.db',
              'volume_exists': true,
              'volume_mountpoint': '/var/lib/docker/volumes/runtime/_data',
              'volume_size_bytes': 4096,
              'checked_at': '2026-09-01T12:00:00Z',
            },
            'container_status': <String, dynamic>{
              'present': true,
              'docker_state': 'running',
              'running': true,
              'health': 'healthy',
              'effective_status': 'ready',
            },
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(sqliteProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: sqliteProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        var snapshot = await AppReleaseRepository(database).readRuntimeSnapshot(
          projectId: sqliteProject.id,
          serverId: serverWithRuntimeCredentials.id,
        );
        expect(snapshot?.resourceUsageJson, contains('0.20%'));
        expect(snapshot?.healthStatus, 'ready');

        sshService.resourceUsageResponse = <String, dynamic>{
          'status': 'success',
          'resource_usage': <String, dynamic>{
            'Container': 'abc123',
            'Name': 'deploydash_app_buildingregs',
            'CPUPerc': '0.25%',
          },
          'sqlite_storage': <String, dynamic>{
            'enabled': true,
            'volume_name': 'deploydash_sqlite_regs-v3',
            'mount_path': '/var/lib/deploydash/sqlite',
            'file_name': 'main.db',
            'database_path': '/var/lib/deploydash/sqlite/main.db',
            'database_url': 'sqlite:////var/lib/deploydash/sqlite/main.db',
            'volume_exists': 'unknown',
            'volume_mountpoint': '/var/lib/docker/volumes/runtime/_data',
            'volume_size_bytes': '8192',
          },
          'container_status': <String, dynamic>{
            'present': true,
            'docker_state': 'running',
            'running': true,
            'health': 'unhealthy',
            'effective_status': 'unhealthy',
            'readiness': <String, dynamic>{
              'status': 'unhealthy',
              'detail': 'HTTP probe failed',
            },
          },
        };
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        snapshot = await AppReleaseRepository(database).readRuntimeSnapshot(
          projectId: sqliteProject.id,
          serverId: serverWithRuntimeCredentials.id,
        );
        expect(snapshot?.resourceUsageJson, contains('0.25%'));
        expect(snapshot?.healthStatus, 'unhealthy');
        expect(sshService.resourceUsageCalls, 2);
      },
    );

    testWidgets('Resource usage refresh handles backend failures', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..resourceUsageResponse = const <String, dynamic>{
          'status': 'error',
          'msg': 'stats failed',
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(sshService.resourceUsageCalls, 1);
      expect(
        await AppReleaseRepository(database).readRuntimeSnapshot(
          projectId: selectedProject.id,
          serverId: serverWithRuntimeCredentials.id,
        ),
        isNull,
      );

      sshService
        ..resourceUsageError = Exception('stats exploded')
        ..resourceUsageResponse = const <String, dynamic>{'status': 'success'};
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(sshService.resourceUsageCalls, 2);
    });

    testWidgets('Staticfile runtime disables one-off command execution', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(
        selectedProject.copyWith(railpackProvider: 'staticfile'),
      );
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject.copyWith(railpackProvider: 'staticfile'),
        projectNotifier: projectNotifier,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));

      expect(
        find.text(
          'One-off commands are not available for staticfile web apps.',
        ),
        findsOneWidget,
      );
      final runButton = tester.widget<FilledButton>(
        find.byKey(const Key('app-oneoff-run-button')),
      );
      expect(runButton.onPressed, isNull);
    });

    testWidgets('Running command button switches to cancellation action', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..execCompleter = Completer<void>();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pump();

      expect(find.text('Cancel running command'), findsOneWidget);
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(sshService.cancelledTaskIds, contains(sshService.execTaskId));
      expect(find.text('Command cancelled.'), findsWidgets);
    });

    testWidgets(
      'One-off command card does not fetch live container state on load',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..resourceUsageResponse = const <String, dynamic>{
            'status': 'success',
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.pumpAndSettle();

        expect(sshService.resourceUsageCalls, 0);
        expect(
          find.textContaining('Deploy or reconnect the web app'),
          findsNothing,
        );
        final runButton = tester.widget<FilledButton>(
          find.byKey(const Key('app-oneoff-run-button')),
        );
        expect(runButton.onPressed, isNotNull);
      },
    );

    testWidgets(
      'Failed one-off command shows exit code, history, and persists app_exec logs',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..execResponse = const <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_RUNTIME_ERROR',
            'msg': 'One-off app command failed with exit code 1.',
            'exit_code': 1,
            'stdout_lines': <String>['Applying migrations'],
            'stderr_lines': <String>['Migration failed'],
          };
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        expect(
          find.text('One-off app command failed with exit code 1.'),
          findsWidgets,
        );
        expect(find.textContaining('Applying migrations'), findsOneWidget);
        expect(find.textContaining('stderr: Migration failed'), findsOneWidget);
        expect(
          find.textContaining('workflow plumbing before command output'),
          findsNothing,
        );
        expect(find.text('Exit code: 1'), findsOneWidget);
        expect(
          find.byKey(const Key('app-oneoff-history-entry-0')),
          findsOneWidget,
        );
        expect(find.text('Recent maintenance commands'), findsOneWidget);
        expect(find.text('npm run db:migrate'), findsWidgets);
        expect(
          find.text(
            'One-off app command failed with exit code 1. (exit code: 1)',
          ),
          findsOneWidget,
        );

        final logs = await TerminalLogRepository(
          database,
        ).listRecentLogsForTaskType(taskType: 'app_exec');
        expect(logs, isNotEmpty);
        expect(
          logs.any((entry) => entry.message == r'$ npm run db:migrate'),
          isTrue,
        );
        expect(
          logs.any(
            (entry) =>
                entry.message == 'Applying migrations' ||
                entry.message == 'stderr: Migration failed' ||
                entry.message == 'One-off app command failed with exit code 1.',
          ),
          isTrue,
        );
        expect(
          logs.any(
            (entry) =>
                entry.message == 'workflow plumbing before command output',
          ),
          isFalse,
        );
      },
    );

    testWidgets('Run button becomes a cancel action while command is running', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..execCompleter = Completer<void>();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pump();

      final runButton = tester.widget<FilledButton>(
        find.byKey(const Key('app-oneoff-run-button')),
      );
      expect(runButton.onPressed, isNotNull);
      expect(find.text('Cancel running command'), findsOneWidget);
      expect(sshService.execCalls, 1);

      sshService.execCompleter!.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('Python web apps can run one-off commands', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(
        selectedProjectWithPythonRuntime,
      );
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProjectWithPythonRuntime,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'python manage.py migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(sshService.execCalls, 1);
      final execCall = sshService.workflowCalls.lastWhere(
        (call) =>
            call['workflow_id'] == 'app' && call['operation_id'] == 'exec',
      );
      final params = execCall['params'] as Map<String, dynamic>;
      expect(params['command'], 'python manage.py migrate');
    });

    testWidgets('One-off runs route the workflow branch and port', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(
        selectedProjectWithPythonRuntime,
      );
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProjectWithPythonRuntime,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'python manage.py migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      // The workflow-call tails carry branch + guarded port + repository +
      // domain as one record; the branch pin kills a branch/domain swap, and
      // the port pin kills a fallback swap. Defaults: branch 'main', and
      // the fixture's valid 8000 passes through untouched.
      final execCall = sshService.workflowCalls.lastWhere(
        (call) =>
            call['workflow_id'] == 'app' && call['operation_id'] == 'exec',
      );
      final params = execCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      expect(settings['branch'], 'main');
      expect(settings['app_port'], 8000);
    });

    testWidgets(
      'Run one-off command shows snackbar when no server is selected',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final deployedProject = selectedProject.copyWith(
          lastDeployCommit: 'abc123',
        );
        final projectNotifier = DialogProjectNotifier(deployedProject);
        final serverCatalogNotifier = MutableServerCatalogNotifier(
          ServerCatalogState(
            isLoading: false,
            onboardingComplete: true,
            servers: <Server>[serverWithRuntimeCredentials],
            selectedServerId: serverWithRuntimeCredentials.id,
            onboardingStep: 'connected',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            gitHubAuthGatewayProvider.overrideWithValue(GitHubReadyGateway()),
            gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
            projectListProvider.overrideWith(() => projectNotifier),
            selectedProjectProvider.overrideWithValue(deployedProject),
            serverCatalogProvider.overrideWith(() => serverCatalogNotifier),
            sshServiceProvider.overrideWithValue(RuntimeWorkflowSshService()),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        final notifier = container.read(gitHubIntegrationProvider.notifier);
        await notifier.connectGitHub();
        final authUrl = Uri.parse(
          container.read(gitHubIntegrationProvider).authorizationUrl!,
        );
        final oauthState = authUrl.queryParameters['state']!;
        await notifier.processCallbackUrl(
          'deploydash://callback?code=abc123&state=$oauthState',
        );
        notifier.selectRepository('deploydash/laravel-example-app');

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
          ),
        );
        await tester.pumpAndSettle();

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        serverCatalogNotifier.setSelectedServer(null);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('No active server selected'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Run one-off command shows snackbar when server credentials are incomplete',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final deployedProject = selectedProject.copyWith(
          lastDeployCommit: 'abc123',
        );
        final projectNotifier = DialogProjectNotifier(deployedProject);
        final serverCatalogNotifier = MutableServerCatalogNotifier(
          ServerCatalogState(
            isLoading: false,
            onboardingComplete: true,
            servers: <Server>[serverWithRuntimeCredentials],
            selectedServerId: serverWithRuntimeCredentials.id,
            onboardingStep: 'connected',
          ),
        );
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            gitHubAuthGatewayProvider.overrideWithValue(GitHubReadyGateway()),
            gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
            projectListProvider.overrideWith(() => projectNotifier),
            selectedProjectProvider.overrideWithValue(deployedProject),
            serverCatalogProvider.overrideWith(() => serverCatalogNotifier),
            sshServiceProvider.overrideWithValue(RuntimeWorkflowSshService()),
          ],
        );
        addTearDown(() async {
          container.dispose();
          await database.close();
        });
        final notifier = container.read(gitHubIntegrationProvider.notifier);
        await notifier.connectGitHub();
        final authUrl = Uri.parse(
          container.read(gitHubIntegrationProvider).authorizationUrl!,
        );
        final oauthState = authUrl.queryParameters['state']!;
        await notifier.processCallbackUrl(
          'deploydash://callback?code=abc123&state=$oauthState',
        );
        notifier.selectRepository('deploydash/laravel-example-app');

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1920, 1080);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: Scaffold(body: ProjectWorkspace())),
          ),
        );
        await tester.pumpAndSettle();

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        serverCatalogNotifier.setSelectedServer(serverWithMissingSshKeyPath);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        expect(
          find.text('Selected server credentials are incomplete.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Run one-off command validates blank command inline', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Enter a command to run inside the app container.'),
        findsOneWidget,
      );
    });

    testWidgets('Run one-off command validates timeout inline', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.enterText(
        find.byKey(const Key('app-oneoff-timeout-field')),
        '0',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Timeout must be between 1 and 3600 seconds.'),
        findsOneWidget,
      );
    });

    testWidgets('Run one-off command surfaces thrown execution exceptions', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService()
        ..execError = Exception('exec exploded');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Command failed: Exception: exec exploded'),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('app-oneoff-history-entry-0')),
        findsOneWidget,
      );
    });

    testWidgets(
      'Cancellation action reports failure when cancellation is rejected',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService()
          ..execCompleter = Completer<void>()
          ..execCancelReturnValue = false;
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
          seedLiveRelease: true,
        );

        await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
        await tester.enterText(
          find.byKey(const Key('app-oneoff-command-field')),
          'npm run db:migrate',
        );
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pump();

        expect(find.text('Cancel running command'), findsOneWidget);
        await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
        await tester.pumpAndSettle();

        expect(
          find.text('Could not cancel the running command.'),
          findsOneWidget,
        );
        sshService.execCompleter!.complete();
      },
    );

    testWidgets('Completed one-off commands report the terminal event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final sshService = RuntimeWorkflowSshService()
        ..execResponse = <String, dynamic>{
          'status': 'success',
          'msg': 'One-off app command completed.',
          'exit_code': 0,
          'stdout_lines': <String>['Applying migrations'],
          'stderr_lines': <String>[],
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(analytics.terminalCommandEvents, [DataOperationOutcome.success]);
    });

    testWidgets('Failed one-off commands report the terminal event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final sshService = RuntimeWorkflowSshService()
        ..execResponse = <String, dynamic>{
          'status': 'error',
          'msg': 'Command failed.',
        };
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(analytics.terminalCommandEvents, [DataOperationOutcome.failure]);
    });

    testWidgets('One-off command errors report the terminal event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final sshService = RuntimeWorkflowSshService()
        ..execError = StateError('ssh unavailable');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(analytics.terminalCommandEvents, [DataOperationOutcome.failure]);
    });

    testWidgets('Cancelled one-off commands report the terminal event', (
      WidgetTester tester,
    ) async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final sshService = RuntimeWorkflowSshService()..execCancelled = true;
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
        seedLiveRelease: true,
      );

      await expandAppDisclosure(tester, const Key('app-oneoff-command-card'));
      await tester.enterText(
        find.byKey(const Key('app-oneoff-command-field')),
        'npm run db:migrate',
      );
      await tester.tap(find.byKey(const Key('app-oneoff-run-button')));
      await tester.pumpAndSettle();

      expect(analytics.terminalCommandEvents, [DataOperationOutcome.failure]);
    });
  }, skip: !sqliteAvailable);
}
