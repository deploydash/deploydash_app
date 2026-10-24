import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../_support/fake_analytics_service.dart';
import '_support/github_integration_harness.dart';

/// GitHub OAuth connect funnel: every flow reports `started` once, then
/// exactly one of `completed` / `failed`.
///
/// Callback-shaped input that is not an attempt (an unparseable URL, a
/// callback for no known flow) reports nothing -- the funnel counts attempts
/// and outcomes, mirroring the unlock gate's form-validation silence. A
/// restored token session is not a flow either.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({
    ProviderContainer container,
    FakeGitHubAuthGateway gateway,
    FakeGitHubSecretRepository secrets,
    FakeAnalyticsService analytics,
    AppDatabase database,
  })
  pumpOAuthContainer({
    bool openAuthorizationUrlResult = true,
    Object? exchangeCodeError,
    Uri? initialCallbackUri,
    String? authToken,
    Project? project,
  }) {
    final gateway = FakeGitHubAuthGateway(
      openAuthorizationUrlResult: openAuthorizationUrlResult,
      exchangeCodeError: exchangeCodeError,
    );
    gateway.initialCallbackUri = initialCallbackUri;
    final secrets = FakeGitHubSecretRepository(authToken: authToken);
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final analytics = FakeAnalyticsService();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        gitHubAuthGatewayProvider.overrideWithValue(gateway),
        gitHubSecretRepositoryProvider.overrideWithValue(secrets),
        gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
        projectListProvider.overrideWith(() => FakeProjectListNotifier()),
        selectedServerProvider.overrideWithValue(selectedServer),
        serverConnectionPayloadResolverProvider.overrideWithValue(
          selectedServerConnectionPayload,
        ),
        selectedProjectProvider.overrideWithValue(project ?? selectedProject),
        sshServiceProvider.overrideWithValue(
          SSHService(taskClient: FakeEngineTaskClient()),
        ),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    return (
      container: container,
      gateway: gateway,
      secrets: secrets,
      analytics: analytics,
      database: database,
    );
  }

  Future<String> connectAndReadState(
    GitHubIntegrationNotifier notifier,
    ProviderContainer container,
  ) async {
    await notifier.connectGitHub();
    final authUrl = Uri.parse(
      container.read(gitHubIntegrationProvider).authorizationUrl!,
    );
    return authUrl.queryParameters['state']!;
  }

  testWithSqlite('connect emits started once', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.connectGitHub();

    expect(harness.analytics.oauthStages, [GitHubOAuthStage.started]);
  });

  testWithSqlite('browser launch failure emits started then failed', () async {
    final harness = pumpOAuthContainer(openAuthorizationUrlResult: false);

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.connectGitHub();

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.error,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.failed,
    ]);
    // No connect, no milestone.
    expect(harness.analytics.userAttributes, isEmpty);
  });

  testWithSqlite('state mismatch emits started then failed', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.connectGitHub();
    await notifier.processCallbackUrl(
      'deploydash://callback?code=abc123&state=wrong-state',
    );

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.error,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.failed,
    ]);
  });

  testWithSqlite('missing code emits started then failed', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    final oauthState = await connectAndReadState(notifier, harness.container);
    await notifier.processCallbackUrl(
      'deploydash://callback?state=$oauthState',
    );

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.error,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.failed,
    ]);
  });

  testWithSqlite('exchange failure emits started then failed', () async {
    final harness = pumpOAuthContainer(
      exchangeCodeError: StateError('GitHub exchange failed'),
    );

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    final oauthState = await connectAndReadState(notifier, harness.container);
    await notifier.processCallbackUrl(
      'deploydash://callback?code=abc123&state=$oauthState',
    );

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.error,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.failed,
    ]);
  });

  testWithSqlite(
    'successful flow emits started then completed exactly once',
    () async {
      final harness = pumpOAuthContainer();

      final notifier = harness.container.read(
        gitHubIntegrationProvider.notifier,
      );
      final oauthState = await connectAndReadState(notifier, harness.container);
      const callback = 'deploydash://callback?code=abc123&state=';
      await notifier.processCallbackUrl('$callback$oauthState');
      // A retried or double-delivered callback must not complete twice.
      await notifier.processCallbackUrl('$callback$oauthState');

      expect(
        harness.container.read(gitHubIntegrationProvider).connectStatus,
        GitHubConnectStatus.connected,
      );
      expect(harness.analytics.oauthStages, [
        GitHubOAuthStage.started,
        GitHubOAuthStage.completed,
      ]);
      // First connect is an activation milestone alongside the funnel event.
      expect(harness.analytics.userAttributes, [
        (attribute: AppUserAttribute.hasConnectedGitHub, value: 'true'),
      ]);
    },
  );

  testWithSqlite('cold-launch recovery counts as started', () async {
    const oauthState = 'deploydash_oauth_state_coldstart';
    final harness = pumpOAuthContainer(
      initialCallbackUri: Uri.parse(
        'deploydash://callback?code=abc123&state=$oauthState',
      ),
    );
    final preferences = AppPreferencesRepository(harness.database);
    await preferences.setGitHubPendingOauthState(oauthState);

    harness.container.read(gitHubIntegrationProvider);
    for (var i = 0; i < 50; i += 1) {
      final status = harness.container
          .read(gitHubIntegrationProvider)
          .connectStatus;
      if (status == GitHubConnectStatus.connected ||
          status == GitHubConnectStatus.error) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.connected,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.completed,
    ]);
  });

  testWithSqlite('invalid callback URL reports nothing', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.processCallbackUrl('http://[::1');

    expect(
      harness.container.read(gitHubIntegrationProvider).statusMessage,
      contains('Invalid callback URL'),
    );
    expect(harness.analytics.oauthStages, isEmpty);
  });

  testWithSqlite('callback for no known flow reports nothing', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.processCallbackUrl(
      'deploydash://callback?code=abc123&state=unknown-state',
    );

    expect(harness.analytics.oauthStages, isEmpty);
  });

  testWithSqlite('stored session restore reports nothing', () async {
    final harness = pumpOAuthContainer(authToken: 'token_saved');

    harness.container.read(gitHubIntegrationProvider);
    for (var i = 0; i < 50; i += 1) {
      final status = harness.container
          .read(gitHubIntegrationProvider)
          .connectStatus;
      if (status == GitHubConnectStatus.connected ||
          status == GitHubConnectStatus.error) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.connected,
    );
    expect(harness.analytics.oauthStages, isEmpty);
  });

  testWithSqlite('retry after failure starts a second flow', () async {
    final harness = pumpOAuthContainer();

    final notifier = harness.container.read(gitHubIntegrationProvider.notifier);
    await notifier.connectGitHub();
    await notifier.processCallbackUrl(
      'deploydash://callback?code=abc123&state=wrong-state',
    );
    final oauthState = await connectAndReadState(notifier, harness.container);
    await notifier.processCallbackUrl(
      'deploydash://callback?code=abc123&state=$oauthState',
    );

    expect(
      harness.container.read(gitHubIntegrationProvider).connectStatus,
      GitHubConnectStatus.connected,
    );
    expect(harness.analytics.oauthStages, [
      GitHubOAuthStage.started,
      GitHubOAuthStage.failed,
      GitHubOAuthStage.started,
      GitHubOAuthStage.completed,
    ]);
  });
}
