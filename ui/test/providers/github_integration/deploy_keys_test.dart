import 'package:flutter_test/flutter_test.dart';
import 'package:ui/models/deploy_failure_evidence.dart';
import 'package:ui/providers/github_deploy_diagnostics.dart';

import '_support/github_integration_harness.dart';

/// GitHub deploy key dance and host-key trust.
///
/// One of five files T-3.6.2 split `github_integration_provider_test.dart`
/// into, along the seams T-3.3.6 split the provider itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generic repository wrappers cannot authorize key rotation', () {
    expect(
      isRepositoryCloneAccessFailure(
        failureMessage: 'Failed action: Sync repository',
        timeline: const <String>[],
      ),
      isFalse,
    );
  });

  test('hard access text without structured ownership cannot rotate a key', () {
    expect(
      isRepositoryCloneAccessFailure(
        failureMessage: 'Permission denied (publickey).',
        timeline: const <String>[],
      ),
      isFalse,
    );
  });

  test('structured repository failures still require hard access evidence', () {
    expect(
      isRepositoryCloneAccessFailure(
        failureMessage: 'Failed action: Sync repository',
        timeline: const <String>['git exited with status 128'],
        failureEvidence: DeployFailureEvidence(
          phase: DeployFailurePhase.repositorySync,
          source: DeployFailureSource.failedOperation,
          completeness: DeployFailureCompleteness.diagnostic,
          lines: const <String>['git exited with status 128'],
          failedStepId: 'app_part1_step2',
          failedActionId: 'app_part1_step2_action_sync_repository',
        ),
      ),
      isFalse,
    );
  });

  test('structured repository failures accept hard timeline evidence', () {
    expect(
      isRepositoryCloneAccessFailure(
        failureMessage: 'Failed action: Sync repository',
        timeline: const <String>['Permission denied (publickey).'],
        failureEvidence: DeployFailureEvidence(
          phase: DeployFailurePhase.repositorySync,
          source: DeployFailureSource.failedOperation,
          completeness: DeployFailureCompleteness.diagnostic,
          lines: const <String>['Permission denied (publickey).'],
          failedStepId: 'app_part1_step2',
          failedActionId: 'app_part1_step2_action_sync_repository',
        ),
      ),
      isTrue,
    );
  });

  testWithSqlite('deploy runs key dance timeline to completion', () async {
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
      railpackBuildCommand: 'yarn build',
      railpackRunCommand: 'yarn start',
    );

    final state = container.read(gitHubIntegrationProvider);
    expect(state.deployStatus, GitHubDeployStatus.success);
    expect(
      state.deployStatusForProject(selectedProject.id),
      GitHubDeployStatus.success,
    );
    expect(
      state.statusMessage,
      contains('App runtime logs are in the Log screen.'),
    );
    expect(state.deployTimeline.length, greaterThanOrEqualTo(4));
    expect(
      state.deployTimelineForProject(selectedProject.id).length,
      greaterThanOrEqualTo(4),
    );
    expect(
      state.deployStatusForProject('other-project'),
      GitHubDeployStatus.idle,
    );
    expect(state.activeDeployProjectId, isNull);
    expect(state.activeDeployRepositoryFullName, isNull);
    expect(state.canDeployForProject(selectedProject.id), isTrue);
    expect(gateway.registerCalls, 1);
    expect(fakeTaskClient.appPrepareCalls, 1);
    expect(fakeTaskClient.appRunCalls, 1);
    final runSettings = fakeTaskClient.lastRunSettings;
    expect(runSettings, isNotNull);
    expect(runSettings!['railpack_node_mode'], 'auto');
    expect(
      runSettings['domain_routing_mode'],
      selectedProject.domainRoutingMode,
    );
    expect(runSettings['railpack_build_cmd'], 'yarn build');
    expect(runSettings['railpack_start_cmd'], 'yarn start');
    expect(runSettings['app_subdirectory'], 'website');
    final storedKey = await secrets.readDeployKey('me/my-blog');
    expect(storedKey, isNotNull);
    expect(storedKey!.publicKey, 'ssh-ed25519 AAAATESTKEY');
    expect(storedKey.privateKey, '-----BEGIN PRIVATE KEY-----test');
    expect(projectNotifier.lastDeploymentConfigProjectId, selectedProject.id);
    expect(
      projectNotifier.lastDeploymentConfigDomainRoutingMode,
      selectedProject.domainRoutingMode,
    );
    expect(projectNotifier.lastDeploymentConfigRepository, 'me/my-blog');
    expect(projectNotifier.lastDeploymentConfigBranch, 'main');
    expect(projectNotifier.lastDeploymentConfigPort, 3000);
    expect(projectNotifier.lastDeploymentConfigBuildCommand, 'yarn build');
    expect(projectNotifier.lastDeploymentConfigRunCommand, 'yarn start');
    expect(projectNotifier.lastDeploymentConfigAppSubdirectory, 'website');
    expect(projectNotifier.lastDeployStateProjectId, selectedProject.id);
    expect(projectNotifier.lastDeployStateCommit, isNotEmpty);
    expect(projectNotifier.lastDeployStateDeployedAt, isNotNull);
  });

  testWithSqlite(
    'deploy keeps repeated task heartbeat lines in timeline',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        appRunPollResponses: const [
          {
            'status': 'success',
            'done': false,
            'events': [
              {
                'type': 'task_heartbeat',
                'level': 'info',
                'message': 'Task is still running.',
                'data': {'elapsed_seconds': 8, 'quiet_seconds': 8},
              },
            ],
          },
          {
            'status': 'success',
            'done': false,
            'events': [
              {
                'type': 'task_heartbeat',
                'level': 'info',
                'message': 'Task is still running.',
                'data': {'elapsed_seconds': 16, 'quiet_seconds': 16},
              },
            ],
          },
          {
            'status': 'success',
            'done': true,
            'events': <Map<String, dynamic>>[],
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
      expect(
        state.deployTimeline.where((line) => line == 'Task is still running.'),
        hasLength(2),
      );
    },
  );

  testWithSqlite(
    'a superseding deploy aborts the stale run after every asynchronous stage',
    () async {
      for (final stage in ['prepare', 'register', 'run']) {
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
            selectedProjectProvider.overrideWithValue(selectedProject),
            sshServiceProvider.overrideWithValue(
              SSHService(taskClient: fakeTaskClient),
            ),
          ],
        );
        try {
          final notifier = container.read(gitHubIntegrationProvider.notifier);
          void startReplacement() {
            unawaited(
              notifier.deploySelectedRepository(
                primaryDomain: 'replacement.example.com',
                branch: 'replacement',
                appPort: 3001,
                repositoryFullName: 'me/worker-api',
              ),
            );
          }

          switch (stage) {
            case 'prepare':
              fakeTaskClient.onPrepareKeyResult = startReplacement;
              break;
            case 'register':
              gateway.onRegisterDeployKey = startReplacement;
              break;
            case 'run':
              fakeTaskClient.onAppRunResult = startReplacement;
              break;
          }

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
          for (var attempt = 0; attempt < 20; attempt += 1) {
            if (container.read(gitHubIntegrationProvider).deployStatus ==
                GitHubDeployStatus.success) {
              break;
            }
            await Future<void>.delayed(Duration.zero);
          }

          final state = container.read(gitHubIntegrationProvider);
          expect(state.deployStatus, GitHubDeployStatus.success);
          expect(state.activeDeployProjectId, isNull);
          expect(state.activeDeployRepositoryFullName, isNull);
          expect(fakeTaskClient.appPrepareCalls, greaterThanOrEqualTo(2));
        } finally {
          container.dispose();
          await database.close();
        }
      }
    },
  );

  testWithSqlite(
    'deploy retries once with fresh key when stored key cannot clone repository',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAAOLDKEY',
        privateKey: '-----BEGIN PRIVATE KEY-----old',
      );
      final fakeTaskClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 1,
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
      expect(state.deployStatus, GitHubDeployStatus.success);
      expect(
        state.statusMessage,
        contains('App runtime logs are in the Log screen.'),
      );
      expect(gateway.registerCalls, 2);
      expect(fakeTaskClient.appPrepareCalls, 1);
      expect(fakeTaskClient.appRunCalls, 2);
      expect(secrets.deleteCalls, 1);
      expect(
        state.deployTimeline.any(
          (line) => line.contains('rotating key and retrying once'),
        ),
        isTrue,
      );
      final storedKey = await secrets.readDeployKey('me/my-blog');
      expect(storedKey, isNotNull);
      expect(storedKey!.publicKey, 'ssh-ed25519 AAAATESTKEY');
      expect(storedKey.privateKey, '-----BEGIN PRIVATE KEY-----test');
    },
  );

  testWithSqlite(
    'deploy stops after one key rotation when repository access still fails',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      await secrets.saveDeployKey(
        repositoryFullName: 'me/my-blog',
        publicKey: 'ssh-ed25519 AAAAOLDKEY',
        privateKey: '-----BEGIN PRIVATE KEY-----old',
      );
      const repositoryFailure = <String, dynamic>{
        'status': 'error',
        'msg': 'Permission denied (publickey).',
        'failure_evidence': <String, dynamic>{
          'schema_version': 1,
          'phase': 'repository_sync',
          'source': 'failed_operation',
          'completeness': 'diagnostic',
          'lines': <String>['Permission denied (publickey).'],
          'failed_step_id': 'app_part1_step2',
          'failed_action_id': 'app_part1_step2_action_sync_repository',
          'probe': null,
        },
      };
      final fakeTaskClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 2,
        appRunFailureResults: const <Map<String, dynamic>>[
          repositoryFailure,
          repositoryFailure,
        ],
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
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
      await notifier.processCallbackUrl(
        'deploydash://callback?code=abc123&state='
        '${authUrl.queryParameters['state']!}',
      );
      notifier.selectRepository('me/my-blog');

      await notifier.deploySelectedRepository(
        primaryDomain: 'blog.example.com',
        branch: 'main',
        appPort: 3000,
      );

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(fakeTaskClient.appRunCalls, 2);
      expect(secrets.deleteCalls, 1);
      expect(gateway.registerCalls, 2);
      expect(
        state.deployTimeline.where(
          (line) => line.contains('rotating key and retrying once'),
        ),
        hasLength(1),
      );
    },
  );

  testWithSqlite(
    'deploy pauses for repository host key confirmation and retries with trust policy',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 1,
        appRunFailureResults: const [
          {
            'status': 'error',
            'code': 'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
            'msg':
                'Confirm the repository SSH identity before Deploy Dash clones this app.',
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

      var state = container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatus,
        GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
      );
      final confirmation = state
          .deployStateForProject(selectedProject.id)
          .repositoryHostKeyConfirmation;
      expect(confirmation, isNotNull);
      expect(confirmation!.host, 'github.com');
      expect(confirmation.trustPolicy, 'accept_new');

      await notifier.trustRepositoryHostKeyAndRetry(selectedProject.id);

      state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.success);
      expect(
        state
            .deployStateForProject(selectedProject.id)
            .repositoryHostKeyConfirmation,
        isNull,
      );
      expect(fakeTaskClient.appRunCalls, 2);
      final runSettings = fakeTaskClient.lastRunSettings;
      expect(runSettings, isNotNull);
      expect(runSettings!['repository_host_key_policy'], 'accept_new');
      expect(
        runSettings['accepted_repository_host_key_fingerprint'],
        'SHA256:newfingerprint',
      );
      expect(runSettings['primary_domain'], 'blog.example.com');
      expect(runSettings['branch'], 'main');
      expect(runSettings['app_port'], 3000);
    },
  );

  testWithSqlite(
    'trusted repository host key prompt does not loop when retry asks again',
    () async {
      const confirmationResult = {
        'status': 'error',
        'code': 'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
        'msg':
            'Confirm the repository SSH identity before Deploy Dash clones this app.',
        'repository_host_key_confirmation_required': true,
        'repository_host_key_confirmation': {
          'host': 'github.com',
          'port': '22',
          'reason': 'missing',
          'previous_fingerprint': '',
          'scanned_fingerprint': 'SHA256:newfingerprint',
        },
      };
      final gateway = FakeGitHubAuthGateway();
      final fakeTaskClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 2,
        appRunFailureResults: const [confirmationResult, confirmationResult],
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(),
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

      var state = container.read(gitHubIntegrationProvider);
      expect(
        state.deployStatus,
        GitHubDeployStatus.awaitingRepositoryHostKeyConfirmation,
      );

      await notifier.trustRepositoryHostKeyAndRetry(selectedProject.id);

      state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(
        state.statusMessage,
        contains('still could not save the trusted GitHub SSH identity'),
      );
      expect(
        state
            .deployStateForProject(selectedProject.id)
            .repositoryHostKeyConfirmation,
        isNull,
      );
      expect(fakeTaskClient.appRunCalls, 2);
    },
  );

  testWithSqlite(
    'deploy host key confirmation can be cancelled without retrying',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final fakeTaskClient = FakeEngineTaskClient(
        appRunFailuresBeforeSuccess: 1,
        appRunFailureResults: const [
          {
            'status': 'error',
            'code': 'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
            'msg':
                'Confirm the repository SSH identity before Deploy Dash clones this app.',
            'repository_host_key_confirmation_required': true,
            'repository_host_key_confirmation': {
              'host': 'github.com',
              'port': '22',
              'reason': 'changed',
              'previous_fingerprint': 'SHA256:oldfingerprint',
              'scanned_fingerprint': 'SHA256:newfingerprint',
            },
          },
        ],
      );
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          gitHubAuthGatewayProvider.overrideWithValue(gateway),
          gitHubSecretRepositoryProvider.overrideWithValue(
            FakeGitHubSecretRepository(),
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
      notifier.cancelRepositoryHostKeyConfirmation(selectedProject.id);

      final state = container.read(gitHubIntegrationProvider);
      expect(state.deployStatus, GitHubDeployStatus.error);
      expect(
        state.statusMessage,
        contains('GitHub SSH identity was not trusted'),
      );
      expect(
        state
            .deployStateForProject(selectedProject.id)
            .repositoryHostKeyConfirmation,
        isNull,
      );
      expect(fakeTaskClient.appRunCalls, 1);
    },
  );

  testWithSqlite(
    'deploy does not rotate stored key for non-repository deployment errors',
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
        appRunFailureMessage:
            'Domain ownership conflict: example.com is already managed.',
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
      expect(gateway.registerCalls, 1);
      expect(fakeTaskClient.appPrepareCalls, 0);
      expect(fakeTaskClient.appRunCalls, 1);
      expect(secrets.deleteCalls, 0);
      final historyRows = await AppDeploymentHistoryRepository(
        database,
      ).listForProject(selectedProject.id, limit: 1);
      expect(historyRows.single.status, 'failed');
      expect(historyRows.single.commit, 'unknown');
    },
  );

  testWithSqlite(
    'deploy fails cleanly when server key preparation fails',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        prepareKeyFailureMessage: 'Unable to prepare deploy key.',
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
      expect(state.statusMessage, 'Unable to prepare deploy key.');
    },
  );

  testWithSqlite(
    'deploy fails cleanly when prepared key material is incomplete',
    () async {
      final gateway = FakeGitHubAuthGateway();
      final secrets = FakeGitHubSecretRepository();
      final fakeTaskClient = FakeEngineTaskClient(
        prepareKeyMissingMaterial: true,
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
        'Server deploy key prepared, but key material was incomplete.',
      );
    },
  );
}
