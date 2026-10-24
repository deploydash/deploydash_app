import 'package:flutter_test/flutter_test.dart';

import '_support/github_integration_harness.dart';

/// GitHub API gateway and branch listing.
///
/// One of five files T-3.6.2 split `github_integration_provider_test.dart`
/// into, along the seams T-3.3.6 split the provider itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithSqlite(
    'listRepositoryBranches returns branches from gateway',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository(authToken: 'token_saved');
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

      final branches = await container
          .read(gitHubIntegrationProvider.notifier)
          .listRepositoryBranches('me/my-blog');

      expect(branches, ['main', 'staging']);
    },
  );

  test(
    'SystemGitHubAuthGateway fetchBranches paginates trims and sorts',
    () async {
      final gateway = SystemGitHubAuthGateway(
        protocolLinkIngress: NoopProtocolLinkIngress(),
      );
      final client = FakeHttpClient(
        responses: <FakeHttpClientResponseSpec>[
          FakeHttpClientResponseSpec(
            statusCode: 200,
            body: [
              {'name': 'staging'},
              {'name': ' main '},
              {'ignored': true},
              'skip-me',
            ],
            headers: {
              'link':
                  '<https://api.github.com/repos/me/my-blog/branches?page=2>; rel="next"',
            },
          ),
          FakeHttpClientResponseSpec(
            statusCode: 200,
            body: [
              {'name': 'release'},
              {'name': 'main'},
            ],
          ),
        ],
      );

      final branches = await HttpOverrides.runZoned(
        () => gateway.fetchBranches(
          accessToken: 'token-123',
          repositoryFullName: ' me/my-blog ',
        ),
        createHttpClient: (_) => client,
      );

      expect(branches, ['main', 'release', 'staging']);
      expect(client.requestedUrls, hasLength(2));
      expect(client.closed, isTrue);
    },
  );

  test(
    'SystemGitHubAuthGateway fetchBranches validates repository and API payloads',
    () async {
      final gateway = SystemGitHubAuthGateway(
        protocolLinkIngress: NoopProtocolLinkIngress(),
      );

      await expectLater(
        () => gateway.fetchBranches(
          accessToken: 'token-123',
          repositoryFullName: 'not valid',
        ),
        throwsA(isA<StateError>()),
      );

      final errorClient = FakeHttpClient(
        responses: <FakeHttpClientResponseSpec>[
          FakeHttpClientResponseSpec(
            statusCode: 401,
            body: {'message': 'Bad credentials'},
          ),
        ],
      );
      await expectLater(
        () => HttpOverrides.runZoned(
          () => gateway.fetchBranches(
            accessToken: 'token-123',
            repositoryFullName: 'me/my-blog',
          ),
          createHttpClient: (_) => errorClient,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('Bad credentials'),
          ),
        ),
      );

      final badPayloadClient = FakeHttpClient(
        responses: <FakeHttpClientResponseSpec>[
          FakeHttpClientResponseSpec(
            statusCode: 200,
            body: {'unexpected': true},
          ),
        ],
      );
      await expectLater(
        () => HttpOverrides.runZoned(
          () => gateway.fetchBranches(
            accessToken: 'token-123',
            repositoryFullName: 'me/my-blog',
          ),
          createHttpClient: (_) => badPayloadClient,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('was not a list'),
          ),
        ),
      );
    },
  );

  testWithSqlite(
    'listRepositoryBranches throws when GitHub token is unavailable',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository(authToken: null);
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

      await expectLater(
        () => container
            .read(gitHubIntegrationProvider.notifier)
            .listRepositoryBranches('me/my-blog'),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('Reconnect GitHub first'),
          ),
        ),
      );
    },
  );
}
