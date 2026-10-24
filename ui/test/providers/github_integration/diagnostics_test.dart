import 'package:flutter_test/flutter_test.dart';
import 'package:ui/providers/github_deploy_diagnostics.dart';
import 'package:ui/services/app_analytics_service.dart';

import '_support/github_integration_harness.dart';

/// Reads advice through the same project scope used by the deployment UI.
String? _suggestedNextStep(GitHubIntegrationState state, String projectId) =>
    state.suggestedNextStepForProject(projectId);

/// Builds the exact repository boundary needed before access advice is safe.
Map<String, dynamic> _repositoryFailureEvidence(String line) =>
    <String, dynamic>{
      'schema_version': 1,
      'phase': 'repository_sync',
      'source': 'failed_operation',
      'completeness': 'diagnostic',
      'lines': <String>[line],
      'failed_step_id': 'app_part1_step2',
      'failed_action_id': 'app_part1_step2_action_sync_repository',
      'probe': null,
    };

/// GitHub deploy failure diagnostics.
///
/// One of five files T-3.6.2 split `github_integration_provider_test.dart`
/// into, along the seams T-3.3.6 split the provider itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithSqlite(
    'deploy failure shows app subdirectory hint for Railpack detection',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureMessage:
            'Railpack could not determine how to build the app.',
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
          selectedProjectProvider.overrideWithValue(
            selectedProjectNoSubdirectory,
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
        primaryDomain: 'root.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(
        state.statusMessage,
        'Railpack could not determine how to build the app.',
      );
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
      expect(
        _suggestedNextStep(state, selectedProjectNoSubdirectory.id),
        contains('App subdirectory'),
      );
    },
  );

  testWithSqlite(
    'deploy failure shows build command hint for output path mismatch',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureMessage:
            'failed to solve: process "npm run build" did not complete '
            'successfully: cp: cannot create regular file '
            "'.output/server': No such file or directory",
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
      expect(
        state.statusMessage,
        'failed to solve: process "npm run build" did not complete '
        'successfully: cp: cannot create regular file '
        "'.output/server': No such file or directory",
      );
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
      expect(
        _suggestedNextStep(state, selectedProject.id),
        allOf(contains('build script'), contains('.output/server')),
      );
    },
  );

  testWithSqlite(
    'deploy failure surfaces domain ownership conflict hint',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureMessage:
            'Domain ownership conflict: example.com is already managed by '
            'project marketing-site.',
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

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(state.statusMessage, contains('Domain ownership conflict'));
      expect(
        state.statusMessage,
        isNot(contains('Another project already owns')),
      );
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
      expect(
        _suggestedNextStep(state, selectedProject.id),
        contains('Another project already owns'),
      );
    },
  );

  testWithSqlite(
    'deploy failure shows configured subdirectory hint when build detection still fails',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureMessage:
            'Railpack could not determine how to build the app.',
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final projectNotifier = FakeProjectListNotifier();
      final project = selectedProject.copyWith(appSubdirectory: 'apps/web');
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
          selectedProjectProvider.overrideWithValue(project),
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
      expect(
        state.statusMessage,
        'Railpack could not determine how to build the app.',
      );
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
      expect(
        _suggestedNextStep(state, selectedProject.id),
        contains('apps/web'),
      );
    },
  );

  testWithSqlite(
    'deploy failure includes repository access hint when clone access still fails',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'error',
            'msg': 'Repository not found.',
            'failure_evidence': _repositoryFailureEvidence(
              'fatal: repository not found',
            ),
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
      expect(state.statusMessage, 'Repository not found.');
      expect(
        state.deployTimeline.any((line) => line.startsWith('Hint:')),
        isFalse,
      );
      expect(
        _suggestedNextStep(state, selectedProject.id),
        contains('Repository clone failed'),
      );
    },
  );

  group('deploy result mapping', () {
    test('names every canonical provider id', () {
      expect(deployProviderForName('node'), DeployProvider.node);
      expect(deployProviderForName('python'), DeployProvider.python);
      expect(deployProviderForName('php'), DeployProvider.php);
      expect(deployProviderForName('ruby'), DeployProvider.ruby);
      expect(deployProviderForName('golang'), DeployProvider.golang);
      expect(deployProviderForName('java'), DeployProvider.java);
      expect(deployProviderForName('rust'), DeployProvider.rust);
      expect(deployProviderForName('dotnet'), DeployProvider.dotnet);
      expect(deployProviderForName('deno'), DeployProvider.deno);
      expect(deployProviderForName('elixir'), DeployProvider.elixir);
      expect(deployProviderForName('shell'), DeployProvider.shell);
      expect(deployProviderForName('staticfile'), DeployProvider.staticfile);
    });

    test('degrades unknown providers to auto-detect, never a guess', () {
      expect(deployProviderForName(null), DeployProvider.autoDetect);
      expect(deployProviderForName('  PYTHON  '), DeployProvider.python);
      expect(deployProviderForName(''), DeployProvider.autoDetect);
      expect(
        deployProviderForName('future-provider'),
        DeployProvider.autoDetect,
      );
    });

    test('success always resolves to a stabilized success', () {
      expect(
        deployStageForResult(success: true, deployResult: null),
        DeployStage.stabilize,
      );
      expect(
        deployOutcomeForResult(success: true, deployResult: null),
        DeployOutcome.success,
      );
      // The boolean rules even when the payload carries failure codes: the
      // desktop only reaches the success path after the full pipeline passed.
      expect(
        deployStageForResult(
          success: true,
          deployResult: const {'cutover_status': 'live'},
        ),
        DeployStage.stabilize,
      );
      expect(
        deployOutcomeForResult(
          success: true,
          deployResult: const {
            'cutover_status': 'traffic_switch_failed',
            'rollback_status': 'reverted_to_previous_live',
          },
        ),
        DeployOutcome.success,
      );
    });

    test('probe failures stay at the probe stage', () {
      const probeResult = {
        'cutover_status': 'pre_cutover_probe_failed',
        'rollback_status': 'not_required',
      };
      expect(
        deployStageForResult(success: false, deployResult: probeResult),
        DeployStage.probe,
      );
      expect(
        deployOutcomeForResult(success: false, deployResult: probeResult),
        DeployOutcome.failure,
      );
    });

    test('cutover failures split on whether traffic reverted', () {
      const revertedResult = {
        'cutover_status': 'traffic_switch_failed',
        'rollback_status': 'reverted_to_previous_live',
      };
      expect(
        deployStageForResult(success: false, deployResult: revertedResult),
        DeployStage.cutover,
      );
      expect(
        deployOutcomeForResult(success: false, deployResult: revertedResult),
        DeployOutcome.rolledBack,
      );

      const failedResult = {
        'cutover_status': 'traffic_switch_failed',
        'rollback_status': 'not_required',
      };
      expect(
        deployStageForResult(success: false, deployResult: failedResult),
        DeployStage.cutover,
      );
      expect(
        deployOutcomeForResult(success: false, deployResult: failedResult),
        DeployOutcome.failure,
      );
    });

    test('cancellation after the switch reports cancelled at cutover', () {
      const cancelledResult = {
        'cutover_status': 'cancelled_after_traffic_switch',
        'rollback_status': 'reverted_to_previous_live',
      };
      // Cancellation names itself even when a rollback also ran: the user
      // stopped the deploy, the revert was cleanup.
      expect(
        deployStageForResult(success: false, deployResult: cancelledResult),
        DeployStage.cutover,
      );
      expect(
        deployOutcomeForResult(success: false, deployResult: cancelledResult),
        DeployOutcome.cancelled,
      );
    });

    test('stabilization reversions report rolled back at stabilize', () {
      for (final cutoverStatus in [
        'reverted_after_stabilization_failure',
        'reverted_after_unexpected_error',
      ]) {
        final result = {
          'cutover_status': cutoverStatus,
          'rollback_status': 'reverted_to_previous_live',
        };
        expect(
          deployStageForResult(success: false, deployResult: result),
          DeployStage.stabilize,
          reason: cutoverStatus,
        );
        expect(
          deployOutcomeForResult(success: false, deployResult: result),
          DeployOutcome.rolledBack,
          reason: cutoverStatus,
        );
      }
    });

    test('failures before the pipeline report probe failures', () {
      // No result: prepare-key faults, clone failures, and thrown tasks never
      // entered the health-gated pipeline, so the first stage is nearest.
      expect(
        deployStageForResult(success: false, deployResult: null),
        DeployStage.probe,
      );
      expect(
        deployOutcomeForResult(success: false, deployResult: null),
        DeployOutcome.failure,
      );
      expect(
        deployStageForResult(
          success: false,
          deployResult: const <String, dynamic>{},
        ),
        DeployStage.probe,
      );
      expect(
        deployOutcomeForResult(
          success: false,
          deployResult: const {'cutover_status': 'not_started'},
        ),
        DeployOutcome.failure,
      );
      expect(
        deployStageForResult(
          success: false,
          deployResult: const {'cutover_status': 'something_new'},
        ),
        DeployStage.probe,
      );
      expect(
        deployOutcomeForResult(
          success: false,
          deployResult: const {'rollback_status': 'something_new'},
        ),
        DeployOutcome.failure,
      );
    });
  });
}
