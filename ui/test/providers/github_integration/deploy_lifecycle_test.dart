import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/app_user_attribute.dart';
import 'package:ui/models/result.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../_support/fake_analytics_service.dart';
import '_support/github_integration_harness.dart';

/// [SSHService] whose `run` operation throws, while every other operation
/// delegates to the real implementation over the fake task client.
///
/// Drives the deploy's task-throw path: the run journal is marked failed and
/// the run rethrows into the deploy's outer catch. Pre-existing behavior
/// (the journal assertions live in `deploy_payload_test.dart`); this double
/// exists to keep the deploy anchor at full coverage and to pin the funnel's
/// exception-path row.
class _ThrowingRunSSHService extends SSHService {
  _ThrowingRunSSHService({required EngineTaskClient taskClient})
    : super(taskClient: taskClient);

  @override
  Future<Result<Map<String, dynamic>>> runWorkflow({
    required String workflowId,
    required String operationId,
    Map<String, dynamic>? connection,
    Map<String, dynamic>? params,
    void Function(Map<String, dynamic> event)? onEvent,
    void Function(int taskId)? onTaskStarted,
    bool serializePerHost = true,
  }) {
    if (operationId == 'run') {
      throw StateError('app run task unavailable');
    }
    return super.runWorkflow(
      workflowId: workflowId,
      operationId: operationId,
      connection: connection,
      params: params,
      onEvent: onEvent,
      onTaskStarted: onTaskStarted,
      serializePerHost: serializePerHost,
    );
  }
}

/// Preferences whose milestone write always fails.
///
/// Drives the first-deploy milestone's fault path: the timestamp write must
/// never fail a deploy that already succeeded.
class _ThrowingMilestonePreferences extends AppPreferencesRepository {
  _ThrowingMilestonePreferences(super.database);

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {
    throw StateError('milestone store unavailable');
  }
}

/// Preferences whose milestone write always fails with a plain [Exception],
/// proving the milestone guard contains operational faults of either shape.
class _ThrowingExceptionMilestonePreferences
    extends _ThrowingMilestonePreferences {
  _ThrowingExceptionMilestonePreferences(super.database);

  @override
  Future<void> recordAnalyticsMilestone(
    AppUserAttribute attribute, {
    DateTime? reachedAt,
  }) async {
    throw Exception('milestone store unavailable');
  }
}

/// Deploy lifecycle funnel: every deploy resolution reports exactly one
/// `trackDeployEvent` at the health-gated outcome point, and success also
/// records the first-deploy activation attribute.
///
/// One of the files beside `github_integration_provider_test.dart`'s split:
/// the hook lives in `persistDeployOutcome`, the single funnel every outcome
/// path runs through, so these tests drive whole deploys rather than units.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({
    ProviderContainer container,
    FakeAnalyticsService analytics,
    AppDatabase database,
  })
  pumpDeployContainer({
    required FakeEngineTaskClient engineClient,
    Project project = selectedProjectWithPythonProvider,
    SSHService? sshService,
    AppPreferencesRepository? preferencesRepository,
  }) {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final analytics = FakeAnalyticsService();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        appPreferencesRepositoryProvider.overrideWithValue(
          preferencesRepository ?? AppPreferencesRepository(database),
        ),
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
        selectedProjectProvider.overrideWithValue(project),
        sshServiceProvider.overrideWithValue(
          sshService ?? SSHService(taskClient: engineClient),
        ),
        appAnalyticsServiceProvider.overrideWithValue(analytics),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    return (container: container, analytics: analytics, database: database);
  }

  Future<void> runDeploy(
    ProviderContainer container, {
    required String primaryDomain,
    required int appPort,
    String? actorLabel,
  }) async {
    final notifier = container.read(gitHubIntegrationProvider.notifier);
    await notifier.deploySelectedRepository(
      primaryDomain: primaryDomain,
      branch: 'main',
      appPort: appPort,
      repositoryFullName: 'me/python-api',
      actorLabel: actorLabel,
    );
  }

  testWithSqlite('successful deploy reports a stabilized success', () async {
    final harness = pumpDeployContainer(
      engineClient: FakeEngineTaskClient(
        appRunSuccessResult: const {
          'status': 'success',
          'http_url': 'http://python.example.com',
          'https_url': 'https://python.example.com',
          'cutover_status': 'live',
          'rollback_status': 'not_required',
          'process_readiness': {'status': 'ready'},
          'public_health': {
            'enabled': true,
            'status': 'healthy',
            'path': '/',
            'http_status': 200,
          },
        },
      ),
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );

    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.provider, DeployProvider.python);
    expect(event.routingMode, 'single_host');
    expect(event.stage, DeployStage.stabilize);
    expect(event.outcome, DeployOutcome.success);
    expect(event.durationSeconds, isNotNull);
    expect(event.durationSeconds!, greaterThanOrEqualTo(0));
    expect(harness.analytics.userAttributes, [
      (attribute: AppUserAttribute.hasFirstDeploySucceeded, value: 'true'),
      (attribute: AppUserAttribute.deploysPerWeekBucket, value: '1'),
    ]);
    expect(harness.analytics.controlUses, [
      (control: AppControl.deployPressed, tab: null),
    ]);
  });

  testWithSqlite(
    'successful deploy stands when the milestone store fails',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final harness = pumpDeployContainer(
        engineClient: FakeEngineTaskClient(
          appRunSuccessResult: const {
            'status': 'success',
            'http_url': 'http://python.example.com',
            'https_url': 'https://python.example.com',
            'cutover_status': 'live',
            'rollback_status': 'not_required',
            'process_readiness': {'status': 'ready'},
            'public_health': {
              'enabled': true,
              'status': 'healthy',
              'path': '/',
              'http_status': 200,
            },
          },
        ),
        preferencesRepository: _ThrowingMilestonePreferences(database),
      );

      await runDeploy(
        harness.container,
        primaryDomain: 'python.example.com',
        appPort: 8000,
      );

      expect(harness.analytics.deployEvents, hasLength(1));
      expect(
        harness.analytics.deployEvents.single.outcome,
        DeployOutcome.success,
      );
      final state = harness.container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.success);
    },
  );

  testWithSqlite(
    'successful deploy stands when the milestone store throws',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final harness = pumpDeployContainer(
        engineClient: FakeEngineTaskClient(
          appRunSuccessResult: const {
            'status': 'success',
            'http_url': 'http://python.example.com',
            'https_url': 'https://python.example.com',
            'cutover_status': 'live',
            'rollback_status': 'not_required',
            'process_readiness': {'status': 'ready'},
            'public_health': {
              'enabled': true,
              'status': 'healthy',
              'path': '/',
              'http_status': 200,
            },
          },
        ),
        preferencesRepository: _ThrowingExceptionMilestonePreferences(database),
      );

      await runDeploy(
        harness.container,
        primaryDomain: 'python.example.com',
        appPort: 8000,
      );

      expect(harness.analytics.deployEvents, hasLength(1));
      expect(
        harness.analytics.deployEvents.single.outcome,
        DeployOutcome.success,
      );
      final state = harness.container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.success);
    },
  );

  testWithSqlite('a second deploy in the week raises the bucket', () async {
    final harness = pumpDeployContainer(engineClient: FakeEngineTaskClient());

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );
    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8001,
    );

    expect(harness.analytics.userAttributes.last, (
      attribute: AppUserAttribute.deploysPerWeekBucket,
      value: '2',
    ));
  });

  testWithSqlite(
    'agent redeploys report the outcome but not a press',
    () async {
      final harness = pumpDeployContainer(engineClient: FakeEngineTaskClient());

      await runDeploy(
        harness.container,
        primaryDomain: 'python.example.com',
        appPort: 8000,
        actorLabel: 'agent-mcp',
      );

      // The outcome funnel still fires: only the press is agent-excluded.
      expect(harness.analytics.deployEvents, hasLength(1));
      expect(
        harness.analytics.deployEvents.single.outcome,
        DeployOutcome.success,
      );
      expect(harness.analytics.controlUses, isEmpty);
    },
  );

  testWithSqlite(
    'host-key trust retry reports a single press for both invocations',
    () async {
      final harness = pumpDeployContainer(
        engineClient: FakeEngineTaskClient(
          appRunFailuresBeforeSuccess: 1,
          appRunFailureResults: const [
            {
              'status': 'error',
              'code': 'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
              'msg': 'Confirm the repository SSH identity before cloning.',
              'repository_host_key_confirmation_required': true,
              'repository_host_key_confirmation': {
                'host': 'github.com',
                'port': '22',
                'reason': 'missing',
                'previous_fingerprint': '',
                'scanned_fingerprint': 'SHA256:newfingerprint',
              },
            },
          ],
        ),
      );

      await runDeploy(
        harness.container,
        primaryDomain: 'python.example.com',
        appPort: 8000,
      );
      var state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatus,
        GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
      );

      final notifier = harness.container.read(
        gitHubIntegrationProvider.notifier,
      );
      await notifier.trustRepositoryHostKeyAndRetry('project-python');

      state = harness.container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.success);
      // One user press: the trust retry is a continuation, not a press.
      expect(harness.analytics.controlUses, [
        (control: AppControl.deployPressed, tab: null),
      ]);
    },
  );

  testWithSqlite('cutover failure with revert reports rolled back', () async {
    final harness = pumpDeployContainer(
      engineClient: FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: const [
          {
            'status': 'error',
            'msg': 'Switch live traffic to candidate release failed.',
            'cutover_status': 'traffic_switch_failed',
            'rollback_status': 'reverted_to_previous_live',
            'rollback_from_release_id': 'release-previous',
          },
        ],
      ),
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );

    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.provider, DeployProvider.python);
    expect(event.routingMode, 'single_host');
    expect(event.stage, DeployStage.cutover);
    expect(event.outcome, DeployOutcome.rolledBack);
    expect(harness.analytics.userAttributes, isEmpty);
  });

  testWithSqlite('cancelled cutover reports cancelled', () async {
    final harness = pumpDeployContainer(
      engineClient: FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: const [
          {
            'status': 'error',
            'msg': 'Deploy cancelled.',
            'cutover_status': 'cancelled_after_traffic_switch',
            'rollback_status': 'reverted_to_previous_live',
          },
        ],
      ),
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );

    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.stage, DeployStage.cutover);
    expect(event.outcome, DeployOutcome.cancelled);
    expect(harness.analytics.userAttributes, isEmpty);
  });

  testWithSqlite('probe failure reports a probe failure', () async {
    final harness = pumpDeployContainer(
      engineClient: FakeEngineTaskClient(
        failAppRun: true,
        appRunFailureResults: const [
          {
            'status': 'error',
            'msg': 'Candidate release did not pass readiness probes.',
            'cutover_status': 'pre_cutover_probe_failed',
            'rollback_status': 'not_required',
          },
        ],
      ),
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );

    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.stage, DeployStage.probe);
    expect(event.outcome, DeployOutcome.failure);
    expect(harness.analytics.userAttributes, isEmpty);
  });

  testWithSqlite('a throwing run task reports a probe failure', () async {
    final engineClient = FakeEngineTaskClient();
    final harness = pumpDeployContainer(
      engineClient: engineClient,
      sshService: _ThrowingRunSSHService(taskClient: engineClient),
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'python.example.com',
      appPort: 8000,
    );

    final state = harness.container.read(gitHubIntegrationProvider);
    expect(state.deployStatus, GitHubDeployStatus.error);
    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.provider, DeployProvider.python);
    expect(event.stage, DeployStage.probe);
    expect(event.outcome, DeployOutcome.failure);
    expect(harness.analytics.userAttributes, isEmpty);
  });

  testWithSqlite('auto-detect deploys report auto-detect', () async {
    final harness = pumpDeployContainer(
      engineClient: FakeEngineTaskClient(),
      project: selectedProject,
    );

    await runDeploy(
      harness.container,
      primaryDomain: 'blog.example.com',
      appPort: 3000,
    );

    expect(harness.analytics.deployEvents, hasLength(1));
    final event = harness.analytics.deployEvents.single;
    expect(event.provider, DeployProvider.autoDetect);
    expect(event.outcome, DeployOutcome.success);
    expect(harness.analytics.userAttributes, [
      (attribute: AppUserAttribute.hasFirstDeploySucceeded, value: 'true'),
      (attribute: AppUserAttribute.deploysPerWeekBucket, value: '1'),
    ]);
  });
}
