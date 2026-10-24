import 'package:flutter_test/flutter_test.dart';

import '_support/github_integration_harness.dart';

/// GitHub OAuth session and repository selection.
///
/// One of five files T-3.6.2 split `github_integration_provider_test.dart`
/// into, along the seams T-3.3.6 split the provider itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithSqlite(
    'connect + callback transitions to connected with repositories',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
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
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final notifier = container.read(gitHubIntegrationProvider.notifier);
      expect(
        container.read(gitHubIntegrationProvider).connectStatus,
        GitHubConnectStatus.disconnected,
      );

      await notifier.connectGitHub();
      final authUrl = Uri.parse(
        container.read(gitHubIntegrationProvider).authorizationUrl!,
      );
      final oauthState = authUrl.queryParameters['state']!;
      expect(
        container.read(gitHubIntegrationProvider).connectStatus,
        GitHubConnectStatus.awaitingCallback,
      );

      await notifier.processCallbackUrl(
        'deploydash://callback?code=abc123&state=$oauthState',
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.connectStatus, GitHubConnectStatus.connected);
      expect(state.repositories, isNotEmpty);
      expect(state.selectedRepositoryFullName, isNull);
      expect(await secrets.readAuthToken(), 'token_abc123');
    },
  );

  testWithSqlite('connect reports error when browser launch fails', () async {
    final gateway = FakeGitHubAuthGateway(openAuthorizationUrlResult: false);
    final secrets = FakeGitHubSecretRepository();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = AppPreferencesRepository(database);
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
          SSHService(taskClient: FakeEngineTaskClient()),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    final notifier = container.read(gitHubIntegrationProvider.notifier);
    await notifier.connectGitHub();

    final state = container.read(gitHubIntegrationProvider);
    expect(state.connectStatus, GitHubConnectStatus.error);
    expect(state.statusMessage, contains('Could not open browser'));
    expect((await preferences.read()).gitHubPendingOauthState, isNull);
  });

  testWithSqlite(
    'callback state mismatch clears pending oauth state and reports error',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final preferences = AppPreferencesRepository(database);
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
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final notifier = container.read(gitHubIntegrationProvider.notifier);
      await notifier.connectGitHub();
      await notifier.processCallbackUrl(
        'deploydash://callback?code=abc123&state=wrong-state',
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.connectStatus, GitHubConnectStatus.error);
      expect(state.statusMessage, contains('OAuth state mismatch'));
      expect((await preferences.read()).gitHubPendingOauthState, isNull);
    },
  );

  testWithSqlite(
    'callback without authorization code clears pending oauth state',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final preferences = AppPreferencesRepository(database);
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
            SSHService(taskClient: FakeEngineTaskClient()),
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
        'deploydash://callback?state=$oauthState',
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.connectStatus, GitHubConnectStatus.error);
      expect(
        state.statusMessage,
        contains('Missing GitHub authorization code'),
      );
      expect((await preferences.read()).gitHubPendingOauthState, isNull);
    },
  );

  testWithSqlite(
    'callback token exchange failure clears pending state and auth token',
    () async {
      final gateway = FakeGitHubAuthGateway(
        exchangeCodeError: StateError('GitHub exchange failed'),
      );
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveAuthToken('old-token');
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final preferences = AppPreferencesRepository(database);
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
            SSHService(taskClient: FakeEngineTaskClient()),
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

      final state = container.read(gitHubIntegrationProvider);
      expect(state.connectStatus, GitHubConnectStatus.error);
      expect(state.statusMessage, contains('GitHub exchange failed'));
      expect((await preferences.read()).gitHubPendingOauthState, isNull);
      expect(await secrets.readAuthToken(), isNull);
    },
  );

  testWithSqlite(
    'restores GitHub session and prefers project repository selection',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveAuthToken('token_saved');
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
            selectedProjectWithPreferredRepository,
          ),
          sshServiceProvider.overrideWithValue(
            SSHService(taskClient: FakeEngineTaskClient()),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      container.read(gitHubIntegrationProvider);
      for (int i = 0; i < 50; i += 1) {
        final status = container.read(gitHubIntegrationProvider).connectStatus;
        if (status == GitHubConnectStatus.connected ||
            status == GitHubConnectStatus.error) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final state = container.read(gitHubIntegrationProvider);
      expect(state.connectStatus, GitHubConnectStatus.connected);
      expect(state.repositories, isNotEmpty);
      expect(state.selectedRepositoryFullName, 'me/worker-api');
    },
  );

  testWithSqlite('processes initial callback link after cold launch', () async {
    final gateway = FakeGitHubAuthGateway();
    final secrets = FakeGitHubSecretRepository();
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final preferences = AppPreferencesRepository(database);
    const oauthState = 'deploydash_oauth_state_coldstart';
    await preferences.setGitHubPendingOauthState(oauthState);
    gateway.initialCallbackUri = Uri.parse(
      'deploydash://callback?code=abc123&state=$oauthState',
    );
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
          SSHService(taskClient: FakeEngineTaskClient()),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    container.read(gitHubIntegrationProvider);
    for (int i = 0; i < 50; i += 1) {
      final status = container.read(gitHubIntegrationProvider).connectStatus;
      if (status == GitHubConnectStatus.connected ||
          status == GitHubConnectStatus.error) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    final state = container.read(gitHubIntegrationProvider);
    expect(state.connectStatus, GitHubConnectStatus.connected);
    expect(state.repositories, isNotEmpty);
    expect(await secrets.readAuthToken(), 'token_abc123');
    expect((await preferences.read()).gitHubPendingOauthState, isNull);
  });

  testWithSqlite('repository selection can be cleared with null', () async {
    final gateway = FakeGitHubAuthGateway();
    final secrets = FakeGitHubSecretRepository();
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
          SSHService(taskClient: FakeEngineTaskClient()),
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
    expect(
      container.read(gitHubIntegrationProvider).selectedRepositoryFullName,
      'me/my-blog',
    );

    notifier.selectRepository(null);
    expect(
      container.read(gitHubIntegrationProvider).selectedRepositoryFullName,
      isNull,
    );
  });

  testWithSqlite('repository selection is scoped by project project', () async {
    final gateway = FakeGitHubAuthGateway();
    final secrets = FakeGitHubSecretRepository();
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
          SSHService(taskClient: FakeEngineTaskClient()),
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

    notifier.selectRepository('me/project-a', projectId: 'project-a');
    notifier.selectRepository('me/project-b', projectId: 'project-b');
    notifier.selectRepository(null, projectId: 'project-a');

    final state = container.read(gitHubIntegrationProvider);
    expect(state.selectedRepositoryForProject('project-a'), isNull);
    expect(state.selectedRepositoryForProject('project-b'), 'me/project-b');
    expect(
      state.deployStateForProject('project-b').selectedRepositoryFullName,
      'me/project-b',
    );
  });
}
