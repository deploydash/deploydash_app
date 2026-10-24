import 'package:flutter_test/flutter_test.dart';

import '_support/project_workspace_harness.dart';

/// project workspace deployment settings.
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

  group('project workspace deployment settings', () {
    testWidgets('Web app env card shows keys only in read-only mode', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => database.close());
      await AppEnvironmentVariableRepository(database).replaceForProject(
        projectId: selectedProject.id,
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime',
            key: 'API_TOKEN',
            value: 's3cr3t',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime',
            key: 'APP_ENV',
            value: 'production',
          ),
        ],
      );

      await pumpProjectWorkspace(
        tester,
        database: database,
        overrides: [
          selectedProjectProvider.overrideWithValue(selectedProject),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
        ],
      );

      expect(find.text('API_TOKEN'), findsOneWidget);
      expect(find.text('APP_ENV'), findsOneWidget);
      expect(find.text('s3cr3t'), findsNothing);
      expect(find.text('production'), findsNothing);
      expect(find.text('Secret'), findsNothing);
      expect(find.textContaining(' changed'), findsNothing);
    });

    testWidgets(
      'Web app env card becomes internally scrollable for many keys',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProject.id,
          rows: List.generate(
            18,
            (index) => AppEnvironmentVariableRecord(
              projectId: selectedProject.id,
              key: 'ENV_KEY_$index',
              value: 'value-$index',
            ),
          ),
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        expect(find.byKey(const Key('app-env-list-scroll')), findsOneWidget);
        expect(find.text('ENV_KEY_0'), findsOneWidget);
        expect(find.text('ENV_KEY_17'), findsOneWidget);
        expect(find.byKey(const Key('env-edit-button')), findsOneWidget);
      },
    );

    testWidgets('Web app env card stays inline for a small number of keys', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await AppEnvironmentVariableRepository(database).replaceForProject(
        projectId: selectedProject.id,
        rows: [
          AppEnvironmentVariableRecord(
            projectId: selectedProject.id,
            key: 'APP_ENV',
            value: 'production',
          ),
          AppEnvironmentVariableRecord(
            projectId: selectedProject.id,
            key: 'APP_KEY',
            value: 'base64:abc123',
          ),
        ],
      );

      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
      );

      expect(find.byKey(const Key('app-env-list-scroll')), findsNothing);
      expect(find.text('APP_ENV'), findsOneWidget);
      expect(find.text('APP_KEY'), findsOneWidget);
      expect(find.byKey(const Key('env-edit-button')), findsOneWidget);
    });

    testWidgets('Deploy progress stays scoped to the project that started it', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final deployCompleter = Completer<void>();
      final sshService = RuntimeWorkflowSshService()
        ..deployRunCompleter = deployCompleter;
      final projectA = projectFixture(
        id: 'project-deploy-a',
        name: 'Project A',
        serverId: serverWithRuntimeCredentials.id,
        primaryDomain: 'project-a.example.com',
      );
      final projectB = projectFixture(
        id: 'project-deploy-b',
        name: 'Project B',
        serverId: serverWithRuntimeCredentials.id,
        primaryDomain: 'project-b.example.com',
      );
      final projectNotifier = StaticProjectListNotifier([projectA, projectB]);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(GitHubReadyGateway()),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerIdProvider.overrideWithValue(
            serverWithRuntimeCredentials.id,
          ),
          selectedServerProvider.overrideWithValue(
            serverWithRuntimeCredentials,
          ),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            testServerConnectionPayload,
          ),
          sshServiceProvider.overrideWithValue(sshService),
        ],
      );
      addTearDown(() async {
        if (!deployCompleter.isCompleted) {
          deployCompleter.complete();
        }
        container.dispose();
        sshService.dispose();
        await database.close();
      });

      container.read(selectedProjectIdProvider.notifier).select(projectA.id);
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

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (sshService.workflowCalls.any(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        )) {
          break;
        }
      }

      expect(find.widgetWithText(FilledButton, 'Deploying...'), findsOneWidget);
      expect(
        find.text('Running web app build and deployment on server...'),
        findsOneWidget,
      );

      container.read(selectedProjectIdProvider.notifier).select(projectB.id);
      await tester.pump();
      await tester.pump();

      expect(find.widgetWithText(FilledButton, 'Deploying...'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Deploy'), findsOneWidget);
      expect(
        find.text('Running web app build and deployment on server...'),
        findsNothing,
      );
      expect(
        find.text(
          'Another project is deploying. Return to that project to watch progress.',
        ),
        findsWidgets,
      );

      deployCompleter.complete();
      await tester.pumpAndSettle();
    });

    testWidgets(
      'Deployment settings runtime switch updates default commands and port',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        await openDeploymentSettingsDialog(tester);

        expect(
          textFieldValue(tester, const Key('deploy-build-command-field')),
          'npm run build',
        );
        expect(
          textFieldValue(tester, const Key('deploy-run-command-field')),
          'npm run start',
        );
        expect(
          textFieldValue(tester, const Key('deploy-app-port-field')),
          '3000',
        );

        await openDeploymentRuntimeMenu(tester);
        await tester.tap(find.text('Python').last);
        await tester.pumpAndSettle();

        expect(
          textFieldValue(tester, const Key('deploy-build-command-field')),
          '',
        );
        expect(
          textFieldValue(tester, const Key('deploy-run-command-field')),
          '',
        );
        expect(
          textFieldValue(tester, const Key('deploy-app-port-field')),
          '8000',
        );
      },
    );

    testWidgets(
      'Deployment settings runtime switch preserves custom commands and port',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        await openDeploymentSettingsDialog(tester);
        await tester.enterText(
          find.byKey(const Key('deploy-build-command-field')),
          'bin/custom-build',
        );
        await tester.enterText(
          find.byKey(const Key('deploy-run-command-field')),
          'bin/custom-start',
        );
        await tester.enterText(
          find.byKey(const Key('deploy-app-port-field')),
          '4567',
        );
        await tester.pumpAndSettle();

        await openDeploymentRuntimeMenu(tester);
        await tester.tap(find.text('Python').last);
        await tester.pumpAndSettle();

        expect(
          textFieldValue(tester, const Key('deploy-build-command-field')),
          'bin/custom-build',
        );
        expect(
          textFieldValue(tester, const Key('deploy-run-command-field')),
          'bin/custom-start',
        );
        expect(
          textFieldValue(tester, const Key('deploy-app-port-field')),
          '4567',
        );
      },
    );

    testWidgets(
      'Deployment settings save persists selected provider with blank commands',
      (WidgetTester tester) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(selectedProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProject,
          projectNotifier: projectNotifier,
        );

        await openDeploymentSettingsDialog(tester);
        await openDeploymentRuntimeMenu(tester);
        await tester.tap(find.text('Python').last);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(projectNotifier.lastProjectId, selectedProject.id);
        expect(
          projectNotifier.lastRepositoryFullName,
          'deploydash/laravel-example-app',
        );
        expect(projectNotifier.lastRailpackProvider, 'python');
        expect(projectNotifier.lastRailpackBuildCommand, '');
        expect(projectNotifier.lastRailpackRunCommand, '');
        expect(projectNotifier.lastAppPort, 8000);
      },
    );

    testWidgets('Deployment settings auto-detect clears explicit provider', (
      WidgetTester tester,
    ) async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(
        selectedProjectWithPythonRuntime,
      );
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProjectWithPythonRuntime,
        projectNotifier: projectNotifier,
      );

      await openDeploymentSettingsDialog(tester);
      await openDeploymentRuntimeMenu(tester);
      await tester.tap(find.text('Auto-detect').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
        projectNotifier.lastProjectId,
        selectedProjectWithPythonRuntime.id,
      );
      expect(projectNotifier.lastRailpackProvider, isNull);
      expect(projectNotifier.lastRailpackBuildCommand, '');
      expect(projectNotifier.lastRailpackRunCommand, '');
    });

    testWidgets(
      'Deployment settings fall back to HTTP challenge when no DNS providers are enabled',
      (WidgetTester tester) async {
        final dnsProject = selectedProject.copyWith(
          tlsChallengeMode: 'dns',
          tlsDnsProvider: 'cloudflare',
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(dnsProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: dnsProject,
          projectNotifier: projectNotifier,
        );

        await openDeploymentSettingsDialog(tester);
        expect(
          find.byKey(const Key('deploy-dns-provider-field')),
          findsNothing,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(projectNotifier.lastTlsChallengeMode, 'http');
        expect(projectNotifier.lastTlsDnsProvider, isNull);
      },
    );

    testWidgets(
      'Deployment settings require choosing a new DNS provider when the saved provider is no longer enabled',
      (WidgetTester tester) async {
        final dnsProject = selectedProject.copyWith(
          tlsChallengeMode: 'dns',
          tlsDnsProvider: 'porkbun',
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(dnsProject);
        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: dnsProject,
          projectNotifier: projectNotifier,
          server: serverWithCloudflareDnsEnabled,
        );

        await openDeploymentSettingsDialog(tester);
        expect(
          find.byKey(const Key('deploy-dns-provider-field')),
          findsOneWidget,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await tester.pumpAndSettle();

        expect(find.text('Choose a DNS provider.'), findsOneWidget);
      },
    );

    test(
      'Deployment settings detect when the selected GitHub repository changed',
      () {
        expect(
          appDeploymentShouldSelectUpdatedRepository(
            currentRepository: 'deploydash/laravel-example-app',
            nextRepository: 'deploydash/amplitude-flutter-desktop',
          ),
          isTrue,
        );
        expect(
          appDeploymentShouldSelectUpdatedRepository(
            currentRepository: 'deploydash/laravel-example-app',
            nextRepository: 'deploydash/laravel-example-app',
          ),
          isFalse,
        );
      },
    );

    testWidgets(
      'Deploy button forwards provider, canonical domain, and only saved env rows',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService();
        final deployProject = selectedProjectWithPythonRuntime.copyWith(
          primaryDomain: 'www.python.buildingregs.app',
          domainRoutingMode: 'redirect_www_to_apex',
        );
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(deployProject);
        final ownerProject = projectFixture(
          id: 'project-shared-sqlite-owner',
          name: 'Shared SQLite owner',
          serverId: serverWithRuntimeCredentials.id,
          primaryDomain: 'sqlite-owner.example.com',
        );
        final projectRepository = ProjectRepository(database);
        await projectRepository.createProject(
          projectRecord(
            ownerProject,
            serverId: serverWithRuntimeCredentials.id,
          ),
        );
        await projectRepository.createProject(
          projectRecord(
            deployProject,
            serverId: serverWithRuntimeCredentials.id,
            isActive: true,
          ),
        );
        final trustGroup = await ProjectNetworkTrustRepository(database)
            .linkProjects(
              serverId: serverWithRuntimeCredentials.id,
              projectIds: [ownerProject.id, deployProject.id],
            );
        const sourceSqlite = ProjectSqliteDatabase(
          id: 'sqlite-shared-catalog',
          projectId: 'project-shared-sqlite-owner',
          name: 'Shared catalog',
          volumeName: 'deploydash_sqlite_shared_catalog',
          mountPath: '/var/lib/deploydash/sqlite',
          fileName: 'catalog.db',
          isPrimary: true,
        );
        await ProjectSqliteDatabaseRepository(database).upsert(sourceSqlite);
        await ProjectSqliteSnapshotRepository(database).upsertPublication(
          sourceDatabase: sourceSqlite,
          consumerProjectId: deployProject.id,
          trustGroupId: trustGroup.id,
        );
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: deployProject.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime-python',
              key: 'APP_ENV',
              value: 'production',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime-python',
              key: 'DATABASE_URL',
              value: 'postgresql://should-not-pass-through',
              secret: true,
            ),
          ],
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: deployProject,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );

        await tester.tap(find.byKey(const Key('github-deploy-button')));
        await tester.pumpAndSettle();

        final runCall = sshService.workflowCalls.firstWhere(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        );
        final params = runCall['params'] as Map<String, dynamic>;
        final settings = params['settings'] as Map<String, dynamic>;
        final runtimeEnv = settings['runtime_env'] as Map<String, dynamic>;

        expect(settings['primary_domain'], 'www.python.buildingregs.app');
        expect(settings['domain_routing_mode'], 'redirect_www_to_apex');
        expect(settings['railpack_provider'], 'python');
        expect(settings['railpack_build_cmd'], isNull);
        expect(settings['railpack_start_cmd'], isNull);
        expect(settings['app_subdirectory'], 'website');
        expect(settings['trust_network_names'], [trustGroup.networkName]);
        expect(settings['sqlite_snapshot_mounts'], hasLength(1));
        expect(runtimeEnv['APP_ENV'], 'production');
        expect(
          runtimeEnv['DATABASE_URL'],
          'postgresql://should-not-pass-through',
        );
        expect(
          find.textContaining('https://python.buildingregs.app'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Deploy throttles rapid automatic resource refreshes', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(selectedProject);
      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: selectedProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();
      expect(sshService.resourceUsageCalls, 1);

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();
      expect(sshService.resourceUsageCalls, 1);
    });

    testWidgets('Deploy button forwards injected postgres DATABASE_URL', (
      WidgetTester tester,
    ) async {
      final sshService = RuntimeWorkflowSshService();
      final deployProject = selectedProjectWithPythonRuntime.copyWith(
        primaryDomain: 'postgres.python.buildingregs.app',
        injectPostgresEnv: true,
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = DialogProjectNotifier(deployProject);
      await AppEnvironmentVariableRepository(database).replaceForProject(
        projectId: deployProject.id,
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'APP_ENV',
            value: 'production',
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_HOST',
            value: 'deploydash_postgres',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_PORT',
            value: '5432',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_NAME',
            value: 'app_db',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_USER',
            value: 'app_user',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_PASSWORD',
            value: 'postgres-secret',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-runtime-python',
            key: 'DATABASE_URL',
            value:
                'postgresql://app_user:postgres-secret@deploydash_postgres:5432/app_db',
            secret: true,
          ),
        ],
      );

      await pumpWorkspaceWithGitHubReady(
        tester,
        database: database,
        project: deployProject,
        projectNotifier: projectNotifier,
        sshService: sshService,
      );

      await tester.tap(find.byKey(const Key('github-deploy-button')));
      await tester.pumpAndSettle();

      final runCall = sshService.workflowCalls.firstWhere(
        (call) => call['workflow_id'] == 'app' && call['operation_id'] == 'run',
      );
      final params = runCall['params'] as Map<String, dynamic>;
      final settings = params['settings'] as Map<String, dynamic>;
      final runtimeEnv = settings['runtime_env'] as Map<String, dynamic>;

      expect(runtimeEnv['APP_ENV'], 'production');
      expect(runtimeEnv['DATABASE_HOST'], 'deploydash_postgres');
      expect(runtimeEnv['DATABASE_PORT'], '5432');
      expect(runtimeEnv['DATABASE_NAME'], 'app_db');
      expect(runtimeEnv['DATABASE_USER'], 'app_user');
      expect(runtimeEnv['DATABASE_PASSWORD'], 'postgres-secret');
      expect(
        runtimeEnv['DATABASE_URL'],
        'postgresql://app_user:postgres-secret@deploydash_postgres:5432/app_db',
      );
    });

    testWidgets(
      'Environment editor save and redeploy persists rows and triggers deploy with current runtime settings',
      (WidgetTester tester) async {
        final sshService = RuntimeWorkflowSshService();
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final projectNotifier = DialogProjectNotifier(
          selectedProjectWithPythonRuntime,
        );
        await AppEnvironmentVariableRepository(database).replaceForProject(
          projectId: selectedProjectWithPythonRuntime.id,
          rows: const [
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime-python',
              key: 'APP_ENV',
              value: 'production',
            ),
            AppEnvironmentVariableRecord(
              projectId: 'project-runtime-python',
              key: 'DATABASE_URL',
              value: 'postgresql://should-not-pass-through',
              secret: true,
            ),
          ],
        );

        await pumpWorkspaceWithGitHubReady(
          tester,
          database: database,
          project: selectedProjectWithPythonRuntime,
          projectNotifier: projectNotifier,
          sshService: sshService,
        );

        await tester.tap(find.byKey(const Key('env-edit-button')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('env-new-key-field')),
          'FEATURE_FLAG',
        );
        await tester.enterText(
          find.byKey(const Key('env-new-value-field')),
          'enabled',
        );
        await tester.tap(find.byKey(const Key('env-add-row-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('env-save-redeploy-button')));
        await tester.pumpAndSettle();

        final savedRows = await AppEnvironmentVariableRepository(
          database,
        ).listForProject(selectedProjectWithPythonRuntime.id);
        expect(savedRows.map((row) => row.key), contains('FEATURE_FLAG'));

        final runCall = sshService.workflowCalls.lastWhere(
          (call) =>
              call['workflow_id'] == 'app' && call['operation_id'] == 'run',
        );
        final params = runCall['params'] as Map<String, dynamic>;
        final settings = params['settings'] as Map<String, dynamic>;
        final runtimeEnv = settings['runtime_env'] as Map<String, dynamic>;

        expect(settings['railpack_build_cmd'], isNull);
        expect(settings['railpack_start_cmd'], isNull);
        expect(settings['app_subdirectory'], 'website');
        expect(runtimeEnv['APP_ENV'], 'production');
        expect(
          runtimeEnv['DATABASE_URL'],
          'postgresql://should-not-pass-through',
        );
        expect(runtimeEnv['FEATURE_FLAG'], 'enabled');
      },
    );

    testWidgets('Environment editor surfaces local persistence failures', (
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
        envRepository: ThrowingAppEnvironmentVariableRepository(),
      );

      await tester.tap(find.byKey(const Key('env-edit-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('env-new-key-field')),
        'FEATURE_FLAG',
      );
      await tester.enterText(
        find.byKey(const Key('env-new-value-field')),
        'enabled',
      );
      await tester.tap(find.byKey(const Key('env-add-row-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('env-save-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Could not save environment variables to local database.'),
        findsOneWidget,
      );
    });
  }, skip: !sqliteAvailable);
}
