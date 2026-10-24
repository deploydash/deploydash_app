import 'package:flutter_test/flutter_test.dart';

import '_support/github_integration_harness.dart';

/// GitHub deploy payload and journal.
///
/// One of five files T-3.6.2 split `github_integration_provider_test.dart`
/// into, along the seams T-3.3.6 split the provider itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithSqlite(
    'deploySelectedRepository applies repository override and fallback routing mode',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository(authToken: 'token_saved');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final engineClient = FakeEngineTaskClient();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final notifier = container.read(gitHubIntegrationProvider.notifier);
      await notifier.deploySelectedRepository(
        primaryDomain: 'blog.example.com',
        branch: 'main',
        appPort: 3000,
        repositoryFullName: ' me/my-blog ',
        domainRoutingMode: '   ',
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.selectedRepositoryFullName, 'me/my-blog');
      expect(projectNotifier.lastDeploymentConfigRepository, 'me/my-blog');
      expect(
        projectNotifier.lastDeploymentConfigDomainRoutingMode,
        selectedProject.domainRoutingMode,
      );
    },
  );

  testWithSqlite(
    'deploy rejects incomplete selection and invalid deployment inputs',
    () async {
      Future<void> expectRejected({
        String? token = 'token_saved',
        Server? server = selectedServer,
        Project? project = selectedProject,
        String? repositoryFullName = 'me/my-blog',
        String primaryDomain = 'blog.example.com',
        String branch = 'main',
        int appPort = 3000,
        String? appSubdirectory,
        required String expectedMessage,
      }) async {
        final database = AppDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWithValue(database),
            gitHubAuthGatewayProvider.overrideWithValue(
              FakeGitHubAuthGateway(),
            ),
            gitHubSecretRepositoryProvider.overrideWithValue(
              FakeGitHubSecretRepository(authToken: token),
            ),
            gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
            projectListProvider.overrideWith(() => FakeProjectListNotifier()),
            selectedServerProvider.overrideWithValue(server),
            serverConnectionPayloadResolverProvider.overrideWithValue(
              selectedServerConnectionPayload,
            ),
            selectedProjectProvider.overrideWithValue(project),
            sshServiceProvider.overrideWithValue(
              SSHService(taskClient: FakeEngineTaskClient()),
            ),
          ],
        );
        try {
          await container
              .read(gitHubIntegrationProvider.notifier)
              .deploySelectedRepository(
                primaryDomain: primaryDomain,
                branch: branch,
                appPort: appPort,
                repositoryFullName: repositoryFullName,
                appSubdirectory: appSubdirectory,
              );

          final state = container.read(gitHubIntegrationProvider);
          expect(state.deployStatus, GitHubDeployStatus.error);
          expect(state.statusMessage, expectedMessage);
        } finally {
          container.dispose();
          await database.close();
        }
      }

      await expectRejected(
        token: null,
        expectedMessage:
            'Connect GitHub and select a repository before deploying.',
      );
      await expectRejected(
        repositoryFullName: null,
        expectedMessage:
            'Connect GitHub and select a repository before deploying.',
      );
      await expectRejected(
        primaryDomain: 'not configured',
        expectedMessage:
            'Primary domain is required and must be a valid FQDN before deploy.',
      );
      await expectRejected(
        branch: 'invalid branch',
        expectedMessage: 'Branch name is invalid.',
      );
      await expectRejected(
        appPort: 0,
        expectedMessage: 'Web app port must be between 1 and 65535.',
      );
      await expectRejected(
        server: null,
        expectedMessage: 'No active server selected for deploy.',
      );
      await expectRejected(
        project: null,
        expectedMessage: 'No project selected for deploy.',
      );
      await expectRejected(
        server: const Server(
          id: 'server-incomplete',
          name: 'Incomplete',
          host: '203.0.113.11',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
        ),
        expectedMessage:
            'Selected server credentials are incomplete. Reconnect server first.',
      );
      await expectRejected(
        appSubdirectory: '../outside-project',
        expectedMessage:
            'App subdirectory is invalid. Use a relative path like "website".',
      );
    },
  );

  testWithSqlite(
    'deploySelectedRepository keeps explicit routing mode and trimmed actor label',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository(authToken: 'token_saved');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final engineClient = FakeEngineTaskClient();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final notifier = container.read(gitHubIntegrationProvider.notifier);
      await notifier.deploySelectedRepository(
        primaryDomain: 'blog.example.com',
        branch: 'main',
        appPort: 3000,
        repositoryFullName: 'me/my-blog',
        domainRoutingMode: ' REDIRECT_WWW_TO_APEX ',
        actorLabel: ' agent-mcp ',
      );

      expect(
        projectNotifier.lastDeploymentConfigDomainRoutingMode,
        'redirect_www_to_apex',
      );
      final historyRows = await container
          .read(appDeploymentHistoryRepositoryProvider)
          .listForProject(selectedProject.id, limit: 1);
      expect(historyRows.single.actor, 'agent-mcp');
      final runtimeSnapshot = await AppReleaseRepository(database)
          .readRuntimeSnapshot(
            projectId: selectedProject.id,
            serverId: selectedServer.id,
          );
      expect(runtimeSnapshot?.healthStatus, 'ready');
    },
  );

  testWithSqlite(
    'deploy records a failed journal when the app task result throws',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final fakeTaskClient = FakeEngineTaskClient(throwAppRunResult: true);
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(state.statusMessage, contains('app run task result unavailable'));
      final journals = await AppReleaseRepository(database).listFailedJournal();
      expect(journals, hasLength(1));
      expect(journals.single.surface, 'app');
      expect(journals.single.operationType, 'run');
      expect(
        journals.single.errorMessage,
        contains('app run task result unavailable'),
      );
    },
  );

  testWithSqlite(
    'successful deploy persists process readiness separately from failed public health',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final engineClient = FakeEngineTaskClient(
        appRunSuccessResult: const {
          'status': 'success',
          'http_url': 'http://blog.example.com',
          'https_url': 'https://blog.example.com',
          'process_readiness': {'status': 'ready'},
          'public_health': {
            'enabled': true,
            'status': 'unhealthy',
            'path': '/',
            'http_status': 500,
            'error': 'The public URL returned HTTP 500.',
          },
        },
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProject.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      expect(deployState.processReadinessStatus, 'ready');
      expect(deployState.publicHealth?.needsAttention, isTrue);
      expect(deployState.statusMessage, contains('public URL check failed'));
      final runtimeSnapshot = await AppReleaseRepository(database)
          .readRuntimeSnapshot(
            projectId: selectedProject.id,
            serverId: selectedServer.id,
          );
      expect(runtimeSnapshot?.healthStatus, 'ready');
      final publicHealth = AppPublicHealthSnapshot.fromJson(
        runtimeSnapshot?.publicHealthJson,
      );
      expect(publicHealth.status, AppPublicHealthStatus.unhealthy);
      expect(publicHealth.httpStatus, 500);
      expect(publicHealth.error, 'The public URL returned HTTP 500.');
      expect(runtimeSnapshot?.publicHealthJson, isNot(contains('response')));
    },
  );

  testWithSqlite(
    'successful deploy without readiness evidence remains unknown',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final engineClient = FakeEngineTaskClient(
        appRunSuccessResult: const {
          'status': 'success',
          'http_url': 'http://blog.example.com',
          'https_url': 'https://blog.example.com',
        },
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProject.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      expect(deployState.processReadinessStatus, 'unknown');
      expect(deployState.publicHealth?.status, AppPublicHealthStatus.unknown);
      final runtimeSnapshot = await AppReleaseRepository(database)
          .readRuntimeSnapshot(
            projectId: selectedProject.id,
            serverId: selectedServer.id,
          );
      expect(runtimeSnapshot?.healthStatus, 'unknown');
    },
  );

  testWithSqlite(
    'deploy surfaces readiness failure summary from backend payload',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAAOLDKEY',
        privateKey: '-----BEGIN PRIVATE KEY-----old',
      );
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: const [
          {
            'status': 'error',
            'msg': 'Candidate release did not pass readiness probes.',
            'readiness_failure_summary':
                'Readiness failed. Last runtime log: Laravel APP_KEY is missing.',
            'runtime_log_excerpt': ['Laravel APP_KEY is missing.'],
            'runtime_log_source': 'failed_candidate',
            'deployment_kind': 'rolling_release',
            'rollback_status': 'reverted_to_previous_live',
            'rollback_from_release_id': 'release-previous',
          },
          {
            'status': 'error',
            'msg': 'Candidate release did not pass readiness probes.',
            'readiness_failure_summary':
                'Readiness failed. Last runtime log: Laravel APP_KEY is missing.',
            'runtime_log_excerpt': ['Laravel APP_KEY is missing.'],
            'runtime_log_source': 'failed_candidate',
            'deployment_kind': 'rolling_release',
            'rollback_status': 'reverted_to_previous_live',
            'rollback_from_release_id': 'release-previous',
          },
        ],
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
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
      notifier.selectRepository('me/my-blog');

      await notifier.deploySelectedRepository(
        primaryDomain: 'example.com',
        branch: 'main',
        appPort: 3000,
      );
      await notifier.deploySelectedRepository(
        primaryDomain: 'example.com',
        branch: 'main',
        appPort: 3000,
        actorLabel: 'release-operator',
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(
        state.statusMessage,
        'Readiness failed. Last runtime log: Laravel APP_KEY is missing.',
      );
      final runtimeLogs = await TerminalLogRepository(database)
          .listRecentLogsForTaskType(
            taskType: 'app_runtime_logs',
            projectId: selectedProject.id,
            serverId: selectedServer.id,
          );
      expect(runtimeLogs, hasLength(2));
      expect(runtimeLogs.first.message, 'Laravel APP_KEY is missing.');
      expect(runtimeLogs.first.source, 'app_runtime_failed_candidate');
      final history = await AppDeploymentHistoryRepository(
        database,
      ).listForProject(selectedProject.id, limit: 2);
      expect(
        history.map((entry) => entry.status),
        containsAll(['failed', 'success']),
      );
      final fallback = history.firstWhere(
        (entry) => entry.deploymentKind == 'auto_fallback',
      );
      expect(fallback.releaseId, 'release-previous');
      expect(fallback.rollbackFromReleaseId, isNull);
      expect(fallback.actor, 'release-operator');
    },
  );

  testWithSqlite(
    'deploy does not append repository hint when retry fails for a different reason',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAAOLDKEY',
        privateKey: '-----BEGIN PRIVATE KEY-----old',
      );
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: const <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'error',
            'msg': 'Repository not found.',
            'failure_evidence': <String, dynamic>{
              'schema_version': 1,
              'phase': 'repository_sync',
              'source': 'failed_operation',
              'completeness': 'diagnostic',
              'lines': <String>['fatal: repository not found'],
              'failed_step_id': 'app_part1_step2',
              'failed_action_id': 'app_part1_step2_action_sync_repository',
              'probe': null,
            },
          },
          <String, dynamic>{
            'status': 'error',
            'msg':
                'composer install failed: php version (8.3.30) does not satisfy that requirement.',
          },
        ],
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
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
      notifier.selectRepository('me/my-blog');

      await notifier.deploySelectedRepository(
        primaryDomain: 'blog.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(gateway.registerCalls, 2);
      expect(fakeTaskClient.appPrepareCalls, 1);
      expect(fakeTaskClient.appRunCalls, 2);
      expect(secrets.deleteCalls, 1);
      expect(state.statusMessage, contains('php version (8.3.30)'));
      expect(state.statusMessage, isNot(contains('Repository clone failed')));
      expect(state.suggestedNextStep, isNull);
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
    },
  );

  testWithSqlite(
    'deploy includes postgres runtime env keys when postgres injection is enabled',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      await AppEnvironmentVariableRepository(database).replaceForProject(
        projectId: selectedProjectWithPostgresEnv.id,
        rows: const [
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'APP_ENV',
            value: 'production',
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_HOST',
            value: 'deploydash_postgres',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_PORT',
            value: '5432',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_NAME',
            value: 'app_db',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_USER',
            value: 'app_user',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_PASSWORD',
            value: 'postgres-secret',
            secret: true,
          ),
          AppEnvironmentVariableRecord(
            projectId: 'project-postgres',
            key: 'DATABASE_URL',
            value:
                'postgresql://app_user:postgres-secret@deploydash_postgres:5432/app_db',
            secret: true,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithPostgresEnv,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
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
      notifier.selectRepository('me/postgres-app');

      await notifier.deploySelectedRepository(
        primaryDomain: 'postgres.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final runSettings = fakeTaskClient.lastRunSettings;
      expect(runSettings, isNotNull);
      final runtimeEnv = runSettings!['runtime_env'] as Map<String, dynamic>;
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
    },
  );

  testWithSqlite(
    'deploy includes sqlite_storage payload when SQLite storage is enabled',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithSqliteStorage,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
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
      notifier.selectRepository('me/my-blog');

      await notifier.deploySelectedRepository(
        primaryDomain: 'sqlite.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final runSettings = fakeTaskClient.lastRunSettings;
      expect(runSettings, isNotNull);
      final sqliteStorage =
          runSettings!['sqlite_storage'] as Map<String, dynamic>?;
      expect(sqliteStorage, isNotNull);
      expect(sqliteStorage!['enabled'], isTrue);
      expect(sqliteStorage['volume_name'], 'deploydash_sqlite_project-sqlite');
      expect(sqliteStorage['mount_path'], '/var/lib/deploydash/sqlite');
      expect(sqliteStorage['file_name'], 'main.db');
    },
  );

  testWithSqlite(
    'deploy forwards explicit Railpack provider without forcing Node commands',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithPythonProvider,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
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
      notifier.selectRepository('me/python-api');

      await notifier.deploySelectedRepository(
        primaryDomain: 'python.example.com',
        branch: 'main',
        appPort: 8000,
      );

      final runSettings = fakeTaskClient.lastRunSettings;
      expect(runSettings, isNotNull);
      expect(runSettings!['railpack_provider'], 'python');
      expect(runSettings['tls_dns_provider'], 'cloudflare');
      expect(runSettings['tls_dns_credentials'], {
        'api_token': 'cloudflare-token',
      });
      expect(runSettings.containsKey('railpack_build_cmd'), isFalse);
      expect(runSettings.containsKey('railpack_start_cmd'), isFalse);
      expect(projectNotifier.lastDeploymentConfigRailpackProvider, 'python');
      expect(projectNotifier.lastDeploymentConfigBuildCommand, isEmpty);
      expect(projectNotifier.lastDeploymentConfigRunCommand, isEmpty);
    },
  );

  testWithSqlite(
    'deploy prefers primary SQLite database record over legacy project fields',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(secrets),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => projectNotifier),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithSqliteStorage,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: fakeTaskClient),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await ProjectSqliteDatabaseRepository(database).upsert(
        const ProjectSqliteDatabase(
          id: 'sqlite-primary',
          projectId: 'project-sqlite',
          name: 'primary',
          volumeName: 'deploydash_sqlite_primary_volume',
          mountPath: '/data/sqlite',
          fileName: 'primary.db',
          isPrimary: true,
        ),
      );

      final notifier = container.read(gitHubIntegrationProvider.notifier);
      await notifier.connectGitHub();
      final authUrl = Uri.parse(
        container.read(gitHubIntegrationProvider).authorizationUrl!,
      );
      final oauthState = authUrl.queryParameters['state']!;
      await notifier.processCallbackUrl(
        'deploydash://callback?code=abc123&state=$oauthState',
      );
      notifier.selectRepository('me/my-blog');

      await notifier.deploySelectedRepository(
        primaryDomain: 'sqlite.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final runSettings = fakeTaskClient.lastRunSettings;
      expect(runSettings, isNotNull);
      final sqliteStorage =
          runSettings!['sqlite_storage'] as Map<String, dynamic>?;
      expect(sqliteStorage, isNotNull);
      expect(sqliteStorage!['enabled'], isTrue);
      expect(sqliteStorage['volume_name'], 'deploydash_sqlite_primary_volume');
      expect(sqliteStorage['mount_path'], '/data/sqlite');
      expect(sqliteStorage['file_name'], 'primary.db');
    },
  );

  testWithSqlite(
    'deploy falls back when the SQLite lookup is unreadable',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final engineClient = FakeEngineTaskClient();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(
            selectedProjectWithSqliteStorage,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
          projectSqliteDatabaseRepositoryProvider.overrideWithValue(
            _ThrowingSqliteDatabaseRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'sqlite.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      // The primary-record lookup failed, so the deploy fell back to the
      // project's saved storage settings and still succeeded.
      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProjectWithSqliteStorage.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      final runSettings = engineClient.lastRunSettings;
      expect(runSettings, isNotNull);
      final sqliteStorage =
          runSettings!['sqlite_storage'] as Map<String, dynamic>?;
      expect(sqliteStorage, isNotNull);
      expect(sqliteStorage!['enabled'], isTrue);
      expect(sqliteStorage['volume_name'], 'deploydash_sqlite_project-sqlite');
    },
  );

  testWithSqlite(
    'deploy proceeds when optional environment rows are unreadable',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final engineClient = FakeEngineTaskClient();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: engineClient),
          ),
          appEnvironmentVariableRepositoryProvider.overrideWithValue(
            _ThrowingEnvironmentVariableRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProject.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      expect(engineClient.lastRunSettings, isNotNull);
      expect(engineClient.lastRunSettings!.containsKey('runtime_env'), isFalse);
    },
  );

  testWithSqlite(
    'deploy records a failed journal when the run monitor throws',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      // The prepare-key monitor runs first and stays quiet; the run monitor
      // throws, which the deployment rethrows as a failed run after journaling.
      var taskStartedCalls = 0;
      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
            onTaskStarted: (taskId, phase) {
              taskStartedCalls += 1;
              if (taskStartedCalls == 2) {
                throw StateError('task monitor unavailable');
              }
            },
          );

      expect(taskStartedCalls, 2);
      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(state.statusMessage, contains('task monitor unavailable'));
      final journals = await AppReleaseRepository(database).listFailedJournal();
      expect(journals, hasLength(1));
      expect(
        journals.single.errorMessage,
        contains('task monitor unavailable'),
      );
    },
  );

  testWithSqlite(
    'successful deploy survives supplementary history failures',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final history = _ThrowingDeploymentHistoryRepository();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
          appDeploymentHistoryRepositoryProvider.overrideWithValue(history),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProject.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      expect(history.appendCalls, 1);
    },
  );

  testWithSqlite(
    'successful deploy survives Exception history failures',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final history = _ThrowingExceptionHistoryRepository();
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
          appDeploymentHistoryRepositoryProvider.overrideWithValue(history),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      final deployState = container
          .read(gitHubIntegrationProvider)
          .deployStateForProject(selectedProject.id);
      expect(deployState.deployStatus, GitHubDeployStatus.success);
      expect(history.appendCalls, 1);
    },
  );

  testWithSqlite(
    'deploy reports failure when the run journal cannot start',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(authToken: 'token_saved'),
          ),
          gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
          projectListProvider.overrideWith(() => FakeProjectListNotifier()),
          selectedServerProvider.overrideWithValue(selectedServer),
          serverConnectionPayloadResolverProvider.overrideWithValue(
            selectedServerConnectionPayload,
          ),
          selectedProjectProvider.overrideWithValue(selectedProject),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
          appReleaseRepositoryProvider.overrideWithValue(
            _ThrowingJournalReleaseRepository(),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      await container
          .read(gitHubIntegrationProvider.notifier)
          .deploySelectedRepository(
            primaryDomain: 'blog.example.com',
            branch: 'main',
            appPort: 3000,
            repositoryFullName: 'me/my-blog',
          );

      // The journal write is the first failure: the outer catch still records
      // the failed outcome in deployment history and reports it.
      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(state.statusMessage, contains('Deployment failed'));
      final history = await AppDeploymentHistoryRepository(
        database,
      ).listForProject(selectedProject.id);
      expect(history.map((entry) => entry.status), contains('failed'));
    },
  );
}

/// Release repository whose journal creation always fails, proving a fault
/// before the run starts still lands in the outer failure report.
class _ThrowingJournalReleaseRepository implements AppReleaseRepository {
  @override
  Future<List<AppReleaseRecord>> listReleasesForScope({
    required String projectId,
    required String serverId,
  }) async {
    return const [];
  }

  @override
  Future<void> replaceReleasesForScope({
    required String projectId,
    required String serverId,
    required List<AppReleaseRecord> releases,
  }) async {}

  @override
  Future<void> upsertRelease(AppReleaseRecord record) async {}

  @override
  Future<AppRuntimeSnapshotRecord?> readRuntimeSnapshot({
    required String projectId,
    required String serverId,
  }) async {
    return null;
  }

  @override
  Future<void> upsertRuntimeSnapshot(AppRuntimeSnapshotRecord record) async {}

  @override
  Future<WorkerRuntimeSnapshotRecord?> readWorkerRuntimeSnapshot({
    required String projectId,
    required String serverId,
  }) async {
    return null;
  }

  @override
  Future<void> upsertWorkerRuntimeSnapshot(
    WorkerRuntimeSnapshotRecord record,
  ) async {}

  @override
  Future<ProjectWorkspaceImportStateRecord?> readImportState({
    required String projectId,
    required String serverId,
  }) async {
    return null;
  }

  @override
  Future<void> upsertImportState({
    required String projectId,
    required String serverId,
    required String status,
    DateTime? startedAt,
    DateTime? finishedAt,
    String? errorMessage,
  }) async {}

  @override
  Future<ProjectManagedOperationJournalRecord> createJournalEntry({
    required String projectId,
    required String serverId,
    required String surface,
    required String operationType,
    Map<String, dynamic>? request,
  }) async {
    throw StateError('journal unavailable');
  }

  @override
  Future<void> updateJournalStatus({
    required String id,
    required String status,
    Map<String, dynamic>? result,
    String? errorMessage,
    bool sanitizeResult = true,
  }) async {}

  @override
  Future<List<ProjectManagedOperationJournalRecord>> listRemoteSuccessJournal({
    int limit = 100,
  }) async {
    return const [];
  }

  @override
  Future<List<ProjectManagedOperationJournalRecord>> listFailedJournal({
    int limit = 100,
  }) async {
    return const [];
  }

  /// Keeps restart recovery inert for this journal-creation failure fake.
  @override
  Future<ProjectManagedOperationJournalRecord?>
  readLatestFailedJournalForOperation({
    required String projectId,
    required String serverId,
    required String surface,
    required String operationType,
  }) async {
    return null;
  }
}

/// Deployment-history repository whose writes always fail, proving a
/// supplementary-store fault cannot change the deploy outcome.
class _ThrowingDeploymentHistoryRepository
    implements AppDeploymentHistoryRepository {
  var appendCalls = 0;

  @override
  Future<void> append({
    required String projectId,
    required String status,
    String? releaseId,
    String deploymentKind = 'deploy',
    String? rollbackFromReleaseId,
    required DateTime deployedAt,
    required int durationSeconds,
    required String actor,
    required String branch,
    required String commit,
  }) async {
    appendCalls += 1;
    throw StateError('history unavailable');
  }

  @override
  Future<List<AppDeploymentHistoryRecord>> listForProject(
    String projectId, {
    int limit = 5,
  }) async {
    return const [];
  }

  @override
  Future<int> countSuccessfulDeploysSince(DateTime cutoff) async {
    throw StateError('history unavailable');
  }
}

/// Deployment-history repository whose bucket read always fails with a plain
/// [Exception], proving the weekly-bucket refresh contains operational faults
/// of either shape while the deploy still stands.
class _ThrowingExceptionHistoryRepository
    extends _ThrowingDeploymentHistoryRepository {
  @override
  Future<int> countSuccessfulDeploysSince(DateTime cutoff) async {
    throw Exception('history unavailable');
  }
}

/// SQLite database repository whose reads always fail, proving the deploy
/// falls back to the project's saved storage settings.
class _ThrowingSqliteDatabaseRepository
    implements ProjectSqliteDatabaseRepository {
  @override
  Future<List<ProjectSqliteDatabase>> listForProject(String projectId) async {
    throw StateError('sqlite store unavailable');
  }

  @override
  Future<ProjectSqliteDatabase?> readPrimaryForProject(String projectId) async {
    throw StateError('sqlite store unavailable');
  }

  @override
  Future<void> upsert(ProjectSqliteDatabase record) async {}

  @override
  Future<void> setPrimary({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {}

  @override
  Future<void> updateRuntimeMetadata({
    required String projectId,
    required String sqliteDatabaseId,
    bool? volumeExists,
    String? volumeMountpoint,
    int? volumeSizeBytes,
    DateTime? checkedAt,
  }) async {}

  @override
  Future<void> delete({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {}
}

/// Environment-variable repository whose reads always fail, proving optional
/// local input degrades to an empty environment instead of blocking deploys.
class _ThrowingEnvironmentVariableRepository
    implements AppEnvironmentVariableRepository {
  @override
  Future<List<AppEnvironmentVariableRecord>> listForProject(
    String projectId,
  ) async {
    throw StateError('environment unavailable');
  }

  @override
  Future<void> replaceForProject({
    required String projectId,
    required List<AppEnvironmentVariableRecord> rows,
  }) async {}
}
