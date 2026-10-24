import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../_support/fake_analytics_service.dart';
import '_support/agent_access_harness.dart';

/// Agent Access redeploy tools.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(5);

  group('Agent Access redeploy tools', () {
    test('MCP redeploy rejects a mismatched web_app_id', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final token =
          (await harness.preferencesRepository.read()).agentSessionToken!;
      final arguments = <String, dynamic>{
        'server_id': harness.server!.id,
        'project_id': harness.project!.id,
        'web_app_id': 'wrong-app',
      };

      final preview = await harness.mcpRequest(
        'deploydash_prepare_web_app_redeploy',
        arguments: arguments,
      );
      expect(preview.statusCode, HttpStatus.ok);
      expect(preview.body['can_redeploy'], isFalse);
      expect(
        (preview.body['validation_errors'] as List<dynamic>).cast<String>(),
        contains('web_app_id does not match the selected web app.'),
      );

      final redeploy = await harness.mcpRequest(
        'deploydash_redeploy_web_app',
        bearerToken: token,
        arguments: arguments,
      );
      expect(redeploy.statusCode, HttpStatus.badRequest);
      expect(redeploy.body['error'], 'validation_failed');
      expect(
        (redeploy.body['validation_errors'] as List<dynamic>).cast<String>(),
        contains('web_app_id does not match the selected web app.'),
      );
      final audit = (await harness.auditRepository.listRecent(
        limit: 10,
      )).firstWhere((entry) => entry.toolName == 'redeploy_web_app');
      expect(audit.details, <String, dynamic>{'project_id': 'wrong-app'});
    }, skip: !sqliteAvailable);

    test(
      'runtime logs and redeploy surface upstream failures and start timeout',
      () async {
        final harness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(
            callOnTaskStarted: false,
            finalDeployStatus: GitHubDeployStatus.error,
            finalStatusMessage: 'app/run never started',
          ),
        );
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final token =
            (await harness.preferencesRepository.read()).agentSessionToken!;

        harness.sshService.runtimeResponse = const <String, dynamic>{
          'status': 'error',
          'msg': 'container down',
          'log_tail_lines': 10,
        };
        final runtimeFailure = await harness.request(
          'GET',
          'web-apps/${harness.project!.id}/runtime-logs',
          query: {'server_id': harness.server!.id},
        );
        expect(runtimeFailure.statusCode, HttpStatus.badGateway);
        expect(runtimeFailure.body['status'], 'error');

        harness.sshService.overviewError = StateError('overview blew up');
        final overviewFailure = await harness.request(
          'GET',
          'servers/${harness.server!.id}',
        );
        expect(overviewFailure.statusCode, HttpStatus.badGateway);
        harness.sshService.overviewError = null;

        final redeployStartFailure = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: token,
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(redeployStartFailure.statusCode, HttpStatus.badGateway);
        expect(redeployStartFailure.body['error'], 'redeploy_start_failed');
      },
      skip: !sqliteAvailable,
    );

    test(
      'redeploy immediate failure and missing session branches are covered',
      () async {
        final harness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(
            deployThrows: StateError('deploy failed immediately'),
          ),
        );
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        await harness.preferencesRepository.clearAgentSession();
        final missingSession = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(missingSession.statusCode, HttpStatus.forbidden);
        expect(missingSession.body['error'], 'session_required');

        final token = await harness.service.issueSession(
          duration: const Duration(hours: 1),
        );
        final immediateFailure = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: token,
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(immediateFailure.statusCode, HttpStatus.badGateway);
        expect(immediateFailure.body['error'], 'redeploy_start_failed');
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);

  group('AgentAccessService redeploy that has not reported a task id', () {
    tearDown(() {
      deployDashAgentRedeployTaskIdTimeoutOverrideForTests = null;
    });

    test('is reported as still running, not as a failure', () async {
      // Surface version 2. The deploy runs unawaited; exceeding the window
      // means it has not reported a task id *yet*, not that it failed. The
      // old `502 redeploy_start_failed` told the agent the deploy had not
      // started, and the reasonable response to that is to send it again --
      // starting a second deploy of a customer's app while the first is
      // mid-flight.
      final harness = await createHarness(
        notifier: FakeGitHubIntegrationNotifier(hangsForever: true),
      );
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final prefs = await harness.preferencesRepository.read();
      deployDashAgentRedeployTaskIdTimeoutOverrideForTests = const Duration(
        milliseconds: 20,
      );

      final response = await harness.request(
        'POST',
        'web-apps/${harness.project!.id}/redeploy',
        body: <String, dynamic>{'server_id': harness.server!.id},
        bearerToken: prefs.agentSessionToken,
      );

      expect(response.statusCode, HttpStatus.accepted);
      expect(response.body['status'], 'pending_confirmation');
      expect(response.body['task_id'], isNull);
      expect(response.body['error'], isNull);
      expect(response.body['message'], contains('Do not send it again'));
    }, skip: !sqliteAvailable);

    test('a deploy that really failed to start still says so', () async {
      // The other half. `callOnTaskStarted: false` with the deploy returning
      // normally means it finished without ever starting an app/run task --
      // nothing is in flight, so a retry is the right advice and the answer
      // must stay distinguishable from the pending case above.
      final harness = await createHarness(
        notifier: FakeGitHubIntegrationNotifier(
          callOnTaskStarted: false,
          finalDeployStatus: GitHubDeployStatus.error,
          finalStatusMessage: 'Deploy failed before the run step.',
        ),
      );
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final prefs = await harness.preferencesRepository.read();

      final response = await harness.request(
        'POST',
        'web-apps/${harness.project!.id}/redeploy',
        body: <String, dynamic>{'server_id': harness.server!.id},
        bearerToken: prefs.agentSessionToken,
      );

      expect(response.statusCode, HttpStatus.badGateway);
      expect(response.body['error'], 'redeploy_start_failed');
      expect(response.body['status'], isNull);
    }, skip: !sqliteAvailable);
  });

  group('AgentAccessService redeploy task lookup', () {
    test(
      'a redeploy still reports its task id when history lookup fails',
      () async {
        final ssh = FakeSSHService()
          ..historyEntryFailure = const ConnectionFailure(
            'History unavailable.',
          );
        final harness = await createHarness(sshService: ssh);
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final token =
            (await harness.preferencesRepository.read()).agentSessionToken!;

        final response = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
          },
          bearerToken: token,
        );

        expect(response.statusCode, HttpStatus.accepted);
        expect(response.body['task_id'], 701);
        // The deploy started; only the follow-up lookup failed, so the operation
        // instance id is absent rather than the whole call failing.
        expect(response.body['operation_instance_id'], isNull);
      },
      skip: !sqliteAvailable,
    );
  });

  group('Agent Access redeploy audit privacy', () {
    test(
      'completion audit keeps evidence metadata and drops all text',
      () async {
        final harness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(
            finalDeployStatus: GitHubDeployStatus.error,
            finalStatusMessage:
                'CANARY_STATUS private.example.invalid /srv/private/app',
            finalFailureEvidence: DeployFailureEvidence(
              phase: DeployFailurePhase.build,
              source: DeployFailureSource.failedOperation,
              completeness: DeployFailureCompleteness.diagnostic,
              lines: const <String>[
                'CANARY_EVIDENCE ENV_TOKEN=synthetic-value',
              ],
            ),
          ),
        );
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final token =
            (await harness.preferencesRepository.read()).agentSessionToken!;

        final response = await harness.mcpRequest(
          'deploydash_redeploy_web_app',
          bearerToken: token,
          arguments: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(response.statusCode, HttpStatus.accepted);

        await Future<void>.delayed(const Duration(milliseconds: 25));
        final audits = await harness.auditRepository.listRecent(limit: 20);
        final completion = audits.singleWhere(
          (entry) =>
              entry.summary == 'Web app redeploy finished with an error.',
        );
        expect(completion.details, <String, dynamic>{
          'project_id': harness.project!.id,
          'server_id': harness.server!.id,
          'task_id': 701,
          'deploy_status': 'error',
          'failure_phase': 'build',
          'failure_source': 'failed_operation',
          'failure_completeness': 'diagnostic',
        });
        final encoded = jsonEncode(
          audits.map((entry) => entry.details).toList(),
        );
        expect(encoded, isNot(contains('CANARY_STATUS')));
        expect(encoded, isNot(contains('CANARY_EVIDENCE')));
        expect(encoded, isNot(contains('private.example.invalid')));
        expect(encoded, isNot(contains('/srv/private/app')));
        expect(encoded, isNot(contains('ENV_TOKEN')));
        expect(encoded, isNot(contains('synthetic-value')));
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);

  group('Agent Access redeploy analytics', () {
    test(
      'started redeploys report success with the handoff duration',
      () async {
        final analytics = FakeAnalyticsService();
        debugOverrideAppAnalyticsService(analytics);
        addTearDown(() => debugOverrideAppAnalyticsService(null));
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final token =
            (await harness.preferencesRepository.read()).agentSessionToken!;

        final response = await harness.mcpRequest(
          'deploydash_redeploy_web_app',
          bearerToken: token,
          arguments: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(response.statusCode, HttpStatus.accepted);

        expect(analytics.agentRedeployEvents, [
          (outcome: DataOperationOutcome.success, durationSeconds: 0),
        ]);
      },
      skip: !sqliteAvailable,
    );

    test('unconfirmed redeploys report acceptance, not failure', () async {
      deployDashAgentRedeployTaskIdTimeoutOverrideForTests = const Duration(
        milliseconds: 20,
      );
      addTearDown(
        () => deployDashAgentRedeployTaskIdTimeoutOverrideForTests = null,
      );
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final harness = await createHarness(
        notifier: FakeGitHubIntegrationNotifier(
          callOnTaskStarted: false,
          hangsForever: true,
        ),
      );
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final token =
          (await harness.preferencesRepository.read()).agentSessionToken!;

      final response = await harness.mcpRequest(
        'deploydash_redeploy_web_app',
        bearerToken: token,
        arguments: <String, dynamic>{
          'server_id': harness.server!.id,
          'project_id': harness.project!.id,
          'web_app_id': harness.project!.id,
        },
      );
      expect(response.statusCode, HttpStatus.accepted);
      expect(response.body['status'], 'pending_confirmation');

      expect(analytics.agentRedeployEvents, [
        (outcome: DataOperationOutcome.success, durationSeconds: 0),
      ]);
    }, skip: !sqliteAvailable);

    test('start failures report the failure', () async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final harness = await createHarness(
        notifier: FakeGitHubIntegrationNotifier(
          deployThrows: StateError('deploy failed immediately'),
        ),
      );
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final token =
          (await harness.preferencesRepository.read()).agentSessionToken!;

      final response = await harness.mcpRequest(
        'deploydash_redeploy_web_app',
        bearerToken: token,
        arguments: <String, dynamic>{
          'server_id': harness.server!.id,
          'project_id': harness.project!.id,
          'web_app_id': harness.project!.id,
        },
      );
      expect(response.statusCode, HttpStatus.badGateway);

      expect(analytics.agentRedeployEvents, [
        (outcome: DataOperationOutcome.failure, durationSeconds: 0),
      ]);
    }, skip: !sqliteAvailable);

    test('validation rejects report nothing', () async {
      final analytics = FakeAnalyticsService();
      debugOverrideAppAnalyticsService(analytics);
      addTearDown(() => debugOverrideAppAnalyticsService(null));
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final token =
          (await harness.preferencesRepository.read()).agentSessionToken!;

      final response = await harness.mcpRequest(
        'deploydash_redeploy_web_app',
        bearerToken: token,
        arguments: <String, dynamic>{
          'server_id': harness.server!.id,
          'project_id': harness.project!.id,
          'web_app_id': 'wrong-app',
        },
      );
      expect(response.statusCode, HttpStatus.badRequest);

      expect(analytics.agentRedeployEvents, isEmpty);
    }, skip: !sqliteAvailable);
  }, skip: !sqliteAvailable);
}
