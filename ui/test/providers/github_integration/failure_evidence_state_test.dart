import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../_support/fake_analytics_service.dart';
import '_support/github_integration_harness.dart';

/// Builds complete version-one evidence so provider tests vary only lifecycle.
Map<String, dynamic> _failureEvidence({required String line}) =>
    <String, dynamic>{
      'schema_version': 1,
      'phase': 'build',
      'source': 'failed_operation',
      'completeness': 'diagnostic',
      'lines': <String>[line],
      'failed_step_id': 'release',
      'failed_action_id': 'build',
      'probe': null,
    };

/// Creates the smallest real provider boundary with encrypted journal storage.
({
  ProviderContainer container,
  AppDatabase database,
  FakeEngineTaskClient engineClient,
})
_providerHarness({
  required FakeEngineTaskClient engineClient,
  Project project = selectedProject,
  TerminalLogRepository? terminalRepository,
  AppDatabase? appDatabase,
  AppAnalyticsService? analytics,
}) {
  final database =
      appDatabase ?? AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(database),
      gitHubAuthGatewayProvider.overrideWithValue(FakeGitHubAuthGateway()),
      gitHubSecretRepositoryProvider.overrideWithValue(
        FakeGitHubSecretRepository(authToken: 'token'),
      ),
      gitHubInteractionStepDelayProvider.overrideWithValue(Duration.zero),
      projectListProvider.overrideWith(() => FakeProjectListNotifier()),
      selectedServerProvider.overrideWithValue(selectedServer),
      serverConnectionPayloadResolverProvider.overrideWithValue(
        selectedServerConnectionPayload,
      ),
      selectedProjectProvider.overrideWithValue(project),
      sshServiceProvider.overrideWithValue(
        SSHService(taskClient: engineClient),
      ),
      if (terminalRepository != null)
        terminalLogRepositoryProvider.overrideWithValue(terminalRepository),
      appAnalyticsServiceProvider.overrideWithValue(
        analytics ?? FakeAnalyticsService(),
      ),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await database.close();
  });
  return (container: container, database: database, engineClient: engineClient);
}

/// Runs one deploy through the same notifier entrypoint used by local users.
Future<void> _deploy(
  ProviderContainer container, {
  Project project = selectedProject,
  String repository = 'me/my-blog',
  String actorLabel = 'local-ui',
}) {
  return container
      .read(gitHubIntegrationProvider.notifier)
      .deploySelectedRepository(
        primaryDomain: project.primaryDomain,
        branch: project.deployBranch,
        appPort: project.appPort,
        repositoryFullName: repository,
        selectedProjectOverride: project,
        actorLabel: actorLabel,
      );
}

/// Proves typed failure evidence follows the deploy run and project lifecycle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWithSqlite(
    'failed deploy stores typed evidence and the next success clears it',
    () async {
      final harness = _providerHarness(
        engineClient: FakeEngineTaskClient(
          appRunFailuresBeforeSuccess: 1,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_OPERATION_FAILED',
              'msg': 'Build failed.',
              'failure_evidence': _failureEvidence(line: 'compiler failed'),
            },
          ],
        ),
      );

      await _deploy(harness.container);

      var state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.failureEvidenceForProject(selectedProject.id)?.lines,
        <String>['compiler failed'],
      );
      expect(state.failureEvidence?.lines, <String>['compiler failed']);
      expect(state.failureEvidenceForProject('other-project'), isNull);

      var clearedBeforeRemoteRun = false;
      final gateway =
          harness.container.read(gitHubAuthGatewayProvider)
              as FakeGitHubAuthGateway;
      gateway.onRegisterDeployKey = () {
        clearedBeforeRemoteRun =
            harness.container
                .read(gitHubIntegrationProvider)
                .failureEvidenceForProject(selectedProject.id) ==
            null;
      };
      await _deploy(harness.container);

      state = harness.container.read(gitHubIntegrationProvider);
      expect(clearedBeforeRemoteRun, isTrue);
      expect(
        state.deployStatusForProject(selectedProject.id),
        GitHubDeployStatus.success,
      );
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);
      expect(state.failureEvidence, isNull);
    },
  );

  testWithSqlite(
    'failure analytics contains metadata but no diagnostic or app text',
    () async {
      final analytics = FakeAnalyticsService();
      final harness = _providerHarness(
        analytics: analytics,
        engineClient: FakeEngineTaskClient(
          failAppRun: true,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_OPERATION_FAILED',
              'msg': 'Build failed for private.example.invalid.',
              'failure_evidence': _failureEvidence(
                line:
                    'CANARY_EVIDENCE_TEXT command=/srv/private/build.sh ENV_TOKEN=synthetic',
              ),
            },
          ],
        ),
      );

      await _deploy(harness.container);

      final failureEvent = analytics.trackedEvents.singleWhere(
        (event) => event.eventName == 'deploy_failure_evidence',
      );
      expect(failureEvent.props, <String, dynamic>{
        'phase': 'build',
        'source': 'failed_operation',
        'completeness': 'diagnostic',
        'line_count_bucket': '1_3',
        'actor': 'local_user',
      });
      final encoded = jsonEncode(<Map<String, Object?>>[
        for (final event in analytics.trackedEvents)
          <String, Object?>{
            'event_name': event.eventName,
            'properties': event.props,
          },
      ]);
      expect(encoded, isNot(contains('CANARY_EVIDENCE_TEXT')));
      expect(encoded, isNot(contains('private.example.invalid')));
      expect(encoded, isNot(contains('/srv/private/build.sh')));
      expect(encoded, isNot(contains('ENV_TOKEN')));
      expect(encoded, isNot(contains('synthetic')));
    },
  );

  testWithSqlite(
    'agent deploy publishes the same evidence state with an agent actor',
    () async {
      final analytics = FakeAnalyticsService();
      final harness = _providerHarness(
        analytics: analytics,
        engineClient: FakeEngineTaskClient(
          failAppRun: true,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_OPERATION_FAILED',
              'msg': 'Build failed.',
              'failure_evidence': _failureEvidence(line: 'compiler failed'),
            },
          ],
        ),
      );

      await _deploy(harness.container, actorLabel: 'agent-mcp');

      final state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.failureEvidenceForProject(selectedProject.id)?.lines,
        <String>['compiler failed'],
      );
      expect(
        analytics.trackedEvents
            .singleWhere(
              (event) => event.eventName == 'deploy_failure_evidence',
            )
            .props,
        containsPair('actor', 'agent'),
      );
    },
  );

  testWithSqlite(
    'prepare failures retain typed evidence without inventing journal state',
    () async {
      final harness = _providerHarness(
        engineClient: FakeEngineTaskClient(
          prepareKeyFailureResult: <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_OPERATION_FAILED',
            'msg': 'Deploy key preparation failed.',
            'failure_evidence': _failureEvidence(line: 'ssh-keygen failed'),
          },
        ),
      );

      await _deploy(harness.container);

      final state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.failureEvidenceForProject(selectedProject.id)?.lines,
        <String>['ssh-keygen failed'],
      );
      expect(
        await AppReleaseRepository(harness.database).listFailedJournal(),
        isEmpty,
      );
    },
  );

  testWithSqlite(
    'confirmation and cancellation never synthesize failure evidence',
    () async {
      final confirmationHarness = _providerHarness(
        engineClient: FakeEngineTaskClient(
          appRunFailuresBeforeSuccess: 1,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
              'msg': 'Confirm the repository SSH identity.',
              'repository_host_key_confirmation_required': true,
              'repository_host_key_confirmation': <String, dynamic>{
                'host': 'github.com',
                'port': '22',
                'reason': 'missing',
                'previous_fingerprint': '',
                'scanned_fingerprint': 'SHA256:synthetic',
              },
              'failure_evidence': _failureEvidence(
                line: 'must not become confirmation evidence',
              ),
            },
          ],
        ),
      );

      await _deploy(confirmationHarness.container);

      var state = confirmationHarness.container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatusForProject(selectedProject.id),
        GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
      );
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);

      final cancellationHarness = _providerHarness(
        engineClient: FakeEngineTaskClient(
          failAppRun: true,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_TASK_CANCELLED',
              'msg': 'Deploy cancelled.',
              'failure_evidence': _failureEvidence(
                line: 'must not become cancellation evidence',
              ),
            },
          ],
        ),
      );

      await _deploy(cancellationHarness.container);

      state = cancellationHarness.container.read(gitHubIntegrationProvider);
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);
    },
  );

  testWithSqlite(
    'project mirroring never leaks another project evidence',
    () async {
      const otherProject = Project(
        id: 'project-other',
        name: 'Other',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'other.example.com',
        deployBranch: 'main',
        appPort: 3000,
      );
      final harness = _providerHarness(
        engineClient: FakeEngineTaskClient(
          failAppRun: true,
          appRunFailureResults: <Map<String, dynamic>>[
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_OPERATION_FAILED',
              'msg': 'First failed.',
              'failure_evidence': _failureEvidence(line: 'first project'),
            },
            <String, dynamic>{
              'status': 'error',
              'code': 'ENGINE_OPERATION_FAILED',
              'msg': 'Second failed.',
              'failure_evidence': _failureEvidence(line: 'second project'),
            },
          ],
        ),
      );

      await _deploy(harness.container);
      await _deploy(
        harness.container,
        project: otherProject,
        repository: 'me/other',
      );

      final notifier = harness.container.read(
        gitHubIntegrationProvider.notifier,
      );
      notifier.mirrorProjectDeployState(selectedProject.id);
      var state = harness.container.read(gitHubIntegrationProvider);
      expect(state.failureEvidence?.lines, <String>['first project']);
      expect(state.failureEvidenceForProject(otherProject.id)?.lines, <String>[
        'second project',
      ]);

      notifier.mirrorProjectDeployState(otherProject.id);
      state = harness.container.read(gitHubIntegrationProvider);
      expect(state.failureEvidence?.lines, <String>['second project']);
      expect(
        state.failureEvidenceForProject(selectedProject.id)?.lines,
        <String>['first project'],
      );
    },
  );

  testWithSqlite(
    'late failure from an invalidated run cannot replace a newer success',
    () async {
      final engineClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 1,
        appRunFailureResults: <Map<String, dynamic>>[
          <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_OPERATION_FAILED',
            'msg': 'Stale deploy failed.',
            'failure_evidence': _failureEvidence(line: 'stale failure'),
          },
        ],
      );
      final harness = _providerHarness(engineClient: engineClient);
      final notifier = harness.container.read(
        gitHubIntegrationProvider.notifier,
      );
      Future<void>? replacement;
      engineClient.onAppRunResult = () {
        replacement = notifier.deploySelectedRepository(
          primaryDomain: 'replacement.example.com',
          branch: 'replacement',
          appPort: 3001,
          repositoryFullName: 'me/replacement',
          selectedProjectOverride: selectedProject,
        );
      };

      await _deploy(harness.container);
      await replacement;

      final state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatusForProject(selectedProject.id),
        GitHubDeployStatus.success,
      );
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);
    },
  );

  testWithSqlite(
    'restore rejects invalid scopes and failed journals without results',
    () async {
      final harness = _providerHarness(engineClient: FakeEngineTaskClient());
      final notifier = harness.container.read(
        gitHubIntegrationProvider.notifier,
      );

      await notifier.restoreLatestDeployFailure(
        projectId: ' ',
        server: selectedServer,
      );
      await notifier.restoreLatestDeployFailure(
        projectId: selectedProject.id,
        server: const Server(
          id: ' ',
          name: 'Invalid',
          host: '203.0.113.10',
          port: 22,
          sshUser: 'root',
          authMethod: ServerAuthMethod.password,
        ),
      );

      final ownJournal = await AppReleaseRepository(harness.database)
          .createJournalEntry(
            projectId: selectedProject.id,
            serverId: selectedServer.id,
            surface: 'app',
            operationType: 'run',
          );
      await AppReleaseRepository(
        harness.database,
      ).updateJournalStatus(id: ownJournal.id, status: 'failed');
      await notifier.restoreLatestDeployFailure(
        projectId: selectedProject.id,
        server: selectedServer,
      );

      expect(
        harness.container
            .read(gitHubIntegrationProvider)
            .failureEvidenceForProject(selectedProject.id),
        isNull,
      );
    },
  );

  testWithSqlite(
    'boundary-only evidence restores without creating terminal rows',
    () async {
      final harness = _providerHarness(engineClient: FakeEngineTaskClient());
      final repository = AppReleaseRepository(harness.database);
      final journal = await repository.createJournalEntry(
        projectId: selectedProject.id,
        serverId: selectedServer.id,
        surface: 'app',
        operationType: 'run',
      );
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: <String, dynamic>{
          'status': 'error',
          'msg': 'Build stopped without output.',
          'failure_evidence': <String, dynamic>{
            'schema_version': 1,
            'phase': 'build',
            'source': 'none',
            'completeness': 'boundary_only',
            'lines': <String>[],
            'failed_step_id': 'release',
            'failed_action_id': 'build',
            'probe': null,
          },
        },
      );

      await harness.container
          .read(gitHubIntegrationProvider.notifier)
          .restoreLatestDeployFailure(
            projectId: selectedProject.id,
            server: selectedServer,
          );

      expect(
        harness.container
            .read(gitHubIntegrationProvider)
            .failureEvidenceForProject(selectedProject.id)
            ?.lines,
        isEmpty,
      );
      expect(
        await TerminalLogRepository(harness.database).listRecentLogsForScope(
          projectId: selectedProject.id,
          serverId: selectedServer.id,
        ),
        isEmpty,
      );
    },
  );

  testWithSqlite(
    'in-memory success prevents a later failed journal from restoring',
    () async {
      final harness = _providerHarness(engineClient: FakeEngineTaskClient());
      await _deploy(harness.container);
      final repository = AppReleaseRepository(harness.database);
      final journal = await repository.createJournalEntry(
        projectId: selectedProject.id,
        serverId: selectedServer.id,
        surface: 'app',
        operationType: 'run',
      );
      await repository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: <String, dynamic>{
          'status': 'error',
          'msg': 'Stale failure.',
          'failure_evidence': _failureEvidence(line: 'stale compiler output'),
        },
      );

      await harness.container
          .read(gitHubIntegrationProvider.notifier)
          .restoreLatestDeployFailure(
            projectId: selectedProject.id,
            server: selectedServer,
          );

      final state = harness.container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatusForProject(selectedProject.id),
        GitHubDeployStatus.success,
      );
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);
    },
  );

  testWithSqlite(
    'success racing terminal persistence prevents stale state publication',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final journalRepository = AppReleaseRepository(database);
      final journal = await journalRepository.createJournalEntry(
        projectId: selectedProject.id,
        serverId: selectedServer.id,
        surface: 'app',
        operationType: 'run',
      );
      await journalRepository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: <String, dynamic>{
          'status': 'error',
          'msg': 'Racing failure.',
          'failure_evidence': _failureEvidence(line: 'racing output'),
        },
      );
      late ProviderContainer container;
      var callbackRan = false;
      final terminalRepository = _CallbackTerminalLogRepository(
        database,
        () async {
          callbackRan = true;
          await _deploy(container);
        },
      );
      final harness = _providerHarness(
        engineClient: FakeEngineTaskClient(),
        terminalRepository: terminalRepository,
        appDatabase: database,
      );
      container = harness.container;

      await container
          .read(gitHubIntegrationProvider.notifier)
          .restoreLatestDeployFailure(
            projectId: selectedProject.id,
            server: selectedServer,
          );

      final state = container.read(gitHubIntegrationProvider);
      expect(callbackRan, isTrue);
      expect(
        state.deployStatusForProject(selectedProject.id),
        GitHubDeployStatus.success,
      );
      expect(state.failureEvidenceForProject(selectedProject.id), isNull);
    },
  );

  testWithSqlite(
    'disposing during terminal persistence stops recovery publication',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final journalRepository = AppReleaseRepository(database);
      final journal = await journalRepository.createJournalEntry(
        projectId: selectedProject.id,
        serverId: selectedServer.id,
        surface: 'app',
        operationType: 'run',
      );
      await journalRepository.updateJournalStatus(
        id: journal.id,
        status: 'failed',
        result: <String, dynamic>{
          'status': 'error',
          'msg': 'Failure before disposal.',
          'failure_evidence': _failureEvidence(line: 'persist then dispose'),
        },
      );
      late ProviderContainer container;
      final terminalRepository = _CallbackTerminalLogRepository(
        database,
        () async => container.dispose(),
      );
      final harness = _providerHarness(
        engineClient: FakeEngineTaskClient(),
        terminalRepository: terminalRepository,
        appDatabase: database,
      );
      container = harness.container;

      await container
          .read(gitHubIntegrationProvider.notifier)
          .restoreLatestDeployFailure(
            projectId: selectedProject.id,
            server: selectedServer,
          );

      expect(
        await TerminalLogRepository(database).listRecentLogsForScope(
          projectId: selectedProject.id,
          serverId: selectedServer.id,
        ),
        hasLength(1),
      );
    },
  );
}

/// Adds a deterministic state change at the persistence await boundary.
final class _CallbackTerminalLogRepository extends TerminalLogRepository {
  _CallbackTerminalLogRepository(super.database, this._onAppend);

  final Future<void> Function() _onAppend;

  /// Runs the injected race only after the evidence batch is durable.
  @override
  Future<void> appendLogBatchOnce({
    required List<({String message, String renderedLine})> lines,
    required String projectId,
    required String serverId,
    required String serverLabel,
    required String source,
    required String taskType,
    required DateTime createdAt,
  }) async {
    await super.appendLogBatchOnce(
      lines: lines,
      projectId: projectId,
      serverId: serverId,
      serverLabel: serverLabel,
      source: source,
      taskType: taskType,
      createdAt: createdAt,
    );
    await _onAppend();
  }
}
