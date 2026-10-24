import 'package:flutter_test/flutter_test.dart';
import 'package:ui/services/app_analytics_service.dart';

import '../../_support/fake_analytics_service.dart';
import '_support/agent_access_harness.dart';

/// Agent Access read tools.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(4);

  group('Agent Access read tools', () {
    test('status and read endpoints return expected payloads', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess(
        permissionMode: agentAccessPermissionRedeploy,
        issueSession: true,
      );
      final prefs = await harness.preferencesRepository.read();
      final token = prefs.agentSessionToken!;

      final statusResponse = await harness.request('GET', 'status');
      expect(statusResponse.statusCode, HttpStatus.ok);
      expect(statusResponse.body['enabled'], isTrue);
      expect(
        statusResponse.body['permission_mode'],
        agentAccessPermissionRedeploy,
      );
      expect(statusResponse.body['server_running'], isTrue);
      expect(statusResponse.body['has_active_session'], isTrue);
      expect(statusResponse.body.containsKey('session_token'), isFalse);
      expect(statusResponse.body['recent_actions'], isA<List<dynamic>>());
      expect(statusResponse.body['running_tasks'], isA<List<dynamic>>());
      expect(statusResponse.body['recent_task_results'], isA<List<dynamic>>());

      final serversResponse = await harness.request('GET', 'servers');
      expect(serversResponse.statusCode, HttpStatus.ok);
      expect(
        ((serversResponse.body['servers'] as List<dynamic>).single
            as Map<String, dynamic>)['host'],
        '203.0.113.10',
      );

      final overviewResponse = await harness.request(
        'GET',
        'servers/${harness.server!.id}',
      );
      expect(overviewResponse.statusCode, HttpStatus.ok);
      expect(
        (overviewResponse.body['metrics']
            as Map<String, dynamic>)['cpu_percent'],
        12,
      );

      final projectsResponse = await harness.request('GET', 'projects');
      expect(projectsResponse.statusCode, HttpStatus.ok);
      expect(projectsResponse.body['projects'], isA<List<dynamic>>());

      final webAppsResponse = await harness.request('GET', 'web-apps');
      expect(webAppsResponse.statusCode, HttpStatus.ok);
      expect((webAppsResponse.body['web_apps'] as List<dynamic>), hasLength(1));

      final detailsResponse = await harness.request(
        'GET',
        'web-apps/${harness.project!.id}',
      );
      expect(detailsResponse.statusCode, HttpStatus.ok);
      expect(
        (detailsResponse.body['web_app']
            as Map<String, dynamic>)['repository_full_name'],
        'me/blog',
      );
      expect(detailsResponse.body['runtime_options'], isA<List<dynamic>>());
      expect(
        detailsResponse.body['hostname_behavior_options'],
        deployDashHostnameBehaviorOptions,
      );

      final sourceResponse = await harness.mcpRequest(
        'deploydash_get_web_app_source',
        arguments: <String, dynamic>{'web_app_id': harness.project!.id},
      );
      expect(sourceResponse.statusCode, HttpStatus.ok);
      expect(
        (sourceResponse.body['source'] as Map<String, dynamic>)['branch'],
        'main',
      );

      final webAppStatusResponse = await harness.mcpRequest(
        'deploydash_get_web_app_status',
        arguments: <String, dynamic>{'web_app_id': harness.project!.id},
      );
      expect(webAppStatusResponse.statusCode, HttpStatus.ok);
      expect(
        (webAppStatusResponse.body['status']
            as Map<String, dynamic>)['latest_deploy'],
        isA<Map<String, dynamic>>(),
      );

      final deployLogsResponse = await harness.request(
        'GET',
        'web-apps/${harness.project!.id}/deploy-logs',
        query: {'limit': '5'},
      );
      expect(deployLogsResponse.statusCode, HttpStatus.ok);
      final deployLogLines =
          (deployLogsResponse.body['deploy_logs'] as List<dynamic>)
              .cast<Map<String, dynamic>>()
              .map((entry) => entry['message'])
              .toList(growable: false);
      expect(
        deployLogLines,
        <String>['Deploy started', 'Deploy finished'],
        reason:
            'only this project\u2019s deploy lines, and no other '
            'project\u2019s, may appear under this web_app_id',
      );

      final missingDeployLogsResponse = await harness.request(
        'GET',
        'web-apps/missing-web-app/deploy-logs',
      );
      expect(missingDeployLogsResponse.statusCode, HttpStatus.notFound);
      expect(missingDeployLogsResponse.body, <String, dynamic>{
        'error': 'unknown_web_app',
        'message': 'web_app_id does not match a saved web app.',
      });

      final missingDeployHistoryResponse = await harness.request(
        'GET',
        'web-apps/missing-web-app/deploy-history',
      );
      expect(missingDeployHistoryResponse.statusCode, HttpStatus.notFound);
      expect(missingDeployHistoryResponse.body['error'], 'unknown_web_app');

      final missingRuntimeLogsResponse = await harness.request(
        'GET',
        'web-apps/missing-web-app/runtime-logs',
        query: {'server_id': harness.server!.id},
      );
      expect(missingRuntimeLogsResponse.statusCode, HttpStatus.notFound);
      expect(missingRuntimeLogsResponse.body['error'], 'unknown_web_app');

      final workflowsResponse = await harness.mcpRequest(
        'deploydash_list_workflows',
      );
      expect(workflowsResponse.statusCode, HttpStatus.ok);
      expect(
        workflowsResponse.body['action_tools'],
        contains('deploydash_redeploy_web_app'),
      );

      final deployHistoryResponse = await harness.request(
        'GET',
        'web-apps/${harness.project!.id}/deploy-history',
        query: {'limit': '3'},
      );
      expect(deployHistoryResponse.statusCode, HttpStatus.ok);
      expect(
        ((deployHistoryResponse.body['deploy_history'] as List<dynamic>).single
            as Map<String, dynamic>)['actor'],
        'agent-mcp',
      );

      final runtimeLogsResponse = await harness.request(
        'GET',
        'web-apps/${harness.project!.id}/runtime-logs',
        query: {'server_id': harness.server!.id, 'tail_lines': '50'},
      );
      expect(runtimeLogsResponse.statusCode, HttpStatus.ok);
      expect(runtimeLogsResponse.body['events'], ['line one', 'line two']);
      final runtimeCall = harness.sshService.runWorkflowCalls.last;
      expect(runtimeCall.workflowId, 'app');
      expect(runtimeCall.operationId, 'runtime_logs');

      final repositoriesResponse = await harness.request(
        'GET',
        'github/repositories',
      );
      expect(repositoriesResponse.statusCode, HttpStatus.ok);
      expect(repositoriesResponse.body['github_connected'], isTrue);
      expect(
        (repositoriesResponse.body['repositories'] as List<dynamic>).length,
        2,
      );

      final branchesResponse = await harness.request(
        'GET',
        'github/repository-branches',
        query: {'repository_full_name': 'me/blog'},
      );
      expect(branchesResponse.statusCode, HttpStatus.ok);
      expect(branchesResponse.body['branches'], ['main', 'staging']);

      final taskHistoryResponse = await harness.request(
        'GET',
        'tasks/history',
        bearerToken: token,
        query: {'limit': '10'},
      );
      expect(taskHistoryResponse.statusCode, HttpStatus.ok);
      expect(
        (taskHistoryResponse.body['task_history'] as List<dynamic>),
        hasLength(2),
      );

      final auditResponse = await harness.request('GET', 'audit');
      expect(auditResponse.statusCode, HttpStatus.ok);
      expect(auditResponse.body['audit_entries'], isA<List<dynamic>>());

      harness.sshService.eventPayloads[701] = <String, dynamic>{
        'status': 'success',
        'done': false,
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'log',
            'message': 'deploy_private_key=PRIVATE-KEY-DATA',
          },
        ],
      };
      harness.sshService.resultPayloads[701] = <String, dynamic>{
        'status': 'success',
        'result': <String, dynamic>{
          'status': 'success',
          'deploy_private_key': 'PRIVATE-KEY-DATA',
          'access_token': 'token-123',
          'repository_url': 'https://user:pass@example.com/repo.git',
          'failure_evidence': <String, dynamic>{
            'schema_version': 1,
            'phase': 'build',
            'source': 'failed_operation',
            'completeness': 'diagnostic',
            'lines': <String>[
              'compiler failed',
              'deploy_private_key=CANARY-EVIDENCE-TEXT',
            ],
            'failed_step_id': 'release',
            'failed_action_id': 'build',
            'probe': null,
          },
        },
      };

      final taskResponse = await harness.request(
        'GET',
        'tasks/701',
        bearerToken: token,
      );
      expect(taskResponse.statusCode, HttpStatus.ok);
      expect(
        (taskResponse.body['task']
            as Map<String, dynamic>)['client_operation_id'],
        'op-701',
      );

      final eventsResponse = await harness.request(
        'GET',
        'tasks/701/events',
        bearerToken: token,
        query: {'max_events': '5'},
      );
      expect(eventsResponse.statusCode, HttpStatus.ok);
      expect(eventsResponse.body['task_id'], 701);
      expect(
        ((eventsResponse.body['events'] as List<dynamic>).single
            as Map<String, dynamic>)['message'],
        'deploy_private_key=***',
      );

      final resultResponse = await harness.request(
        'GET',
        'tasks/701/result',
        bearerToken: token,
      );
      expect(resultResponse.statusCode, HttpStatus.ok);
      expect(
        (resultResponse.body['result'] as Map<String, dynamic>)['status'],
        'success',
      );
      expect(
        (resultResponse.body['result']
            as Map<String, dynamic>)['deploy_private_key'],
        '***',
      );
      expect(
        (resultResponse.body['result'] as Map<String, dynamic>)['access_token'],
        '***',
      );
      expect(
        (resultResponse.body['result']
            as Map<String, dynamic>)['repository_url'],
        'https://user:***@example.com/repo.git',
      );
      final taskEvidence =
          (resultResponse.body['result']
                  as Map<String, dynamic>)['failure_evidence']
              as Map<String, dynamic>;
      expect(taskEvidence['phase'], 'build');
      expect(taskEvidence['source'], 'failed_operation');
      expect(taskEvidence['completeness'], 'diagnostic');
      expect(taskEvidence['lines'], <String>[
        'compiler failed',
        'deploy_private_key=***',
      ]);

      final conflictResponse = await harness.request(
        'POST',
        'tasks/evaluate-conflict',
        body: <String, dynamic>{
          'workflow_id': 'app',
          'operation_id': 'run',
          'connection': <String, dynamic>{'host': '203.0.113.10'},
          'params': <String, dynamic>{
            'settings': <String, dynamic>{'x': 1},
          },
          'serialize_per_host': false,
        },
      );
      expect(conflictResponse.statusCode, HttpStatus.ok);
      expect(
        (conflictResponse.body['conflict']
            as Map<String, dynamic>)['is_blocked'],
        isFalse,
      );

      final previewResponse = await harness.request(
        'POST',
        'web-apps/${harness.project!.id}/prepare-redeploy',
        body: <String, dynamic>{
          'server_id': harness.server!.id,
          'project_id': harness.project!.id,
          'web_app_id': harness.project!.id,
          'repository_full_name': 'me/blog',
          'primary_hostname': 'blog.example.com',
          'hostname_behavior': 'redirect_www_to_apex',
          'branch': 'release/2026',
          'port': 8080,
          'runtime': 'python',
          'build_command': '',
          'run_command': '',
        },
      );
      expect(previewResponse.statusCode, HttpStatus.ok);
      expect(previewResponse.body['can_redeploy'], isTrue);
      expect(
        (previewResponse.body['changed_fields'] as List<dynamic>),
        containsAll(<String>[
          'hostname_behavior',
          'branch',
          'port',
          'runtime',
          'build_command',
          'run_command',
        ]),
      );
      expect(
        (previewResponse.body['resolved_next_config']
            as Map<String, dynamic>)['build_command'],
        '',
      );
      expect(
        (previewResponse.body['queue_conflict']
            as Map<String, dynamic>)['is_blocked'],
        isFalse,
      );
      expect(previewResponse.body['approval_required'], isFalse);
      expect(
        previewResponse.body['allowed_repository_full_names'],
        contains('me/blog'),
      );
      expect(previewResponse.body['allowed_runtime_ids'], contains('python'));
      final previewSettings =
          harness.sshService.lastConflictParams?['settings']
              as Map<String, dynamic>;
      expect(previewSettings['public_health_check_enabled'], isTrue);
      expect(previewSettings['public_health_check_path'], '/');

      final redeployResponse = await harness.request(
        'POST',
        'web-apps/${harness.project!.id}/redeploy',
        bearerToken: token,
        body: <String, dynamic>{
          'server_id': harness.server!.id,
          'project_id': harness.project!.id,
          'web_app_id': harness.project!.id,
          'repository_full_name': 'me/blog',
          'primary_hostname': 'blog.example.com',
          'hostname_behavior': 'redirect_www_to_apex',
          'branch': 'release/2026',
          'port': 8080,
          'runtime': 'python',
          'build_command': 'pip install -r requirements.txt',
          'run_command': 'gunicorn app:app',
        },
      );
      expect(redeployResponse.statusCode, HttpStatus.accepted);
      expect(redeployResponse.body['task_id'], 701);
      expect(redeployResponse.body['operation_instance_id'], 'op-701');
      expect(redeployResponse.body['workflow_id'], 'app');
      expect(redeployResponse.body['operation_id'], 'run');
      expect(redeployResponse.body['streamable'], isTrue);
      expect(harness.notifier.lastActorLabel, 'agent-mcp');
      expect(harness.notifier.lastDomainRoutingMode, 'redirect_www_to_apex');
      expect(harness.notifier.lastRailpackProvider, 'python');
      expect(
        harness.notifier.lastSelectedServerOverride!.id,
        harness.server!.id,
      );
      expect(
        harness.notifier.lastSelectedProjectOverride!.id,
        harness.project!.id,
      );

      final cancelResponse = await harness.request(
        'POST',
        'tasks/701/cancel',
        bearerToken: token,
      );
      expect(cancelResponse.statusCode, HttpStatus.ok);
      expect(cancelResponse.body['cancelled'], isTrue);
    }, skip: !sqliteAvailable);

    test(
      'readStatus swallows task history errors and reports bind failure',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        harness.sshService.historyError = StateError('no history available');
        await harness.service.initialize();
        var status = await harness.service.readStatus();
        expect(status.runningTasks, isEmpty);
        expect(status.recentTaskResults, isEmpty);

        final blocker = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          harness.port,
        );
        addTearDown(() => blocker.close(force: true));
        await harness.service.setEnabled(true);
        status = await harness.service.readStatus();
        expect(status.serverRunning, isFalse);
        expect(
          status.serverError,
          contains('Could not bind Agent Access server'),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'additional edge cases cover malformed requests connection modes and audit failures',
      () async {
        final harness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(throwAfterTaskStarted: true),
        );
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final outsideApi = await harness.rawRequest('GET', '/oops');
        expect(outsideApi.statusCode, HttpStatus.notFound);
        expect(outsideApi.body['error'], 'not_found');

        final emptyPreview = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/prepare-redeploy',
        );
        expect(emptyPreview.statusCode, HttpStatus.ok);
        expect(emptyPreview.body['can_redeploy'], isFalse);
        expect(
          (emptyPreview.body['validation_errors'] as List<dynamic>)
              .cast<String>(),
          contains('server_id is required.'),
        );

        final repoLessProject = const Project(
          id: 'project-no-repo',
          name: 'Repo Less',
          type: 'Web app',
          gitUrl: 'https://github.com/me/repo-less',
          primaryDomain: 'repo-less.example.com',
          deployBranch: 'main',
          appPort: 3000,
        );
        await harness.projectRepository.createProject(repoLessProject);
        final blankRepositoryPreview = await harness.request(
          'POST',
          'web-apps/${repoLessProject.id}/prepare-redeploy',
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': repoLessProject.id,
            'web_app_id': repoLessProject.id,
            'repository_full_name': '   ',
            'primary_hostname': 'repo-less.example.com',
            'hostname_behavior': 'single_host',
            'branch': 'main',
            'port': 3000,
            'runtime': 'node',
          },
        );
        expect(
          (blankRepositoryPreview.body['validation_errors'] as List<dynamic>)
              .cast<String>(),
          contains('repository_full_name is required.'),
        );

        final invalidJsonBody = await harness.rawRequest(
          'POST',
          deployDashAgentMcpPath,
          body: '[]',
        );
        expect(invalidJsonBody.statusCode, HttpStatus.badRequest);
        expect(invalidJsonBody.body['error'], 'invalid_request');

        final streamProbe = await harness.openMcpEventStream();
        expect(streamProbe.statusCode, HttpStatus.ok);
        expect(streamProbe.firstChunk, contains(': connected'));

        final invalidKeyServer = await harness.serverRepository.createServer(
          draft: const ServerDraft(
            name: 'Keyless',
            host: '203.0.113.11',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
          ),
          specs: const ServerSpecs(osName: 'Ubuntu 24.04', cpuArch: 'x86_64'),
        );
        const invalidKeyProjectId = 'project-keyless';
        await harness.projectRepository.createProject(
          Project(
            id: invalidKeyProjectId,
            serverId: invalidKeyServer.id,
            name: 'Keyless App',
            type: 'Web app',
            gitUrl: 'https://github.com/me/blog',
            primaryDomain: 'blog.example.com',
            repositoryFullName: 'me/blog',
            deployBranch: 'main',
            appPort: 3000,
            railpackProvider: 'node',
          ),
        );
        final invalidRuntime = await harness.request(
          'GET',
          'web-apps/$invalidKeyProjectId/runtime-logs',
          query: {'server_id': invalidKeyServer.id},
        );
        expect(invalidRuntime.statusCode, HttpStatus.badRequest);
        expect(invalidRuntime.body['error'], 'invalid_connection');

        final invalidPreview = await harness.request(
          'POST',
          'web-apps/$invalidKeyProjectId/prepare-redeploy',
          body: <String, dynamic>{
            'server_id': invalidKeyServer.id,
            'project_id': invalidKeyProjectId,
            'web_app_id': invalidKeyProjectId,
            'repository_full_name': 'me/blog',
            'primary_hostname': 'blog.example.com',
            'hostname_behavior': 'single_host',
            'branch': 'main',
            'port': 8080.75,
            'runtime': 'python',
          },
        );
        expect(invalidPreview.statusCode, HttpStatus.ok);
        expect(
          (invalidPreview.body['validation_errors'] as List<dynamic>)
              .cast<String>(),
          contains('Selected server credentials are incomplete.'),
        );
        expect(
          (invalidPreview.body['resolved_next_config']
              as Map<String, dynamic>)['port'],
          8080,
        );

        final stringPortPreview = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/prepare-redeploy',
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
            'repository_full_name': 'me/blog',
            'primary_hostname': 'blog.example.com',
            'hostname_behavior': 'single_host',
            'branch': 'main',
            'port': '8081',
            'runtime': 'node',
          },
        );
        expect(stringPortPreview.statusCode, HttpStatus.ok);
        expect(
          (stringPortPreview.body['resolved_next_config']
              as Map<String, dynamic>)['port'],
          8081,
        );

        await harness.preferencesRepository.clearAgentSession();
        final cancelWithoutSession = await harness.request(
          'POST',
          'tasks/701/cancel',
        );
        expect(cancelWithoutSession.statusCode, HttpStatus.forbidden);
        expect(cancelWithoutSession.body['error'], 'session_required');
        final refreshedToken = await harness.service.issueSession(
          duration: const Duration(hours: 1),
        );

        final crashedRedeploy = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: refreshedToken,
          body: <String, dynamic>{
            'server_id': harness.server!.id,
            'project_id': harness.project!.id,
            'web_app_id': harness.project!.id,
          },
        );
        expect(crashedRedeploy.statusCode, HttpStatus.accepted);
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final audits = await harness.auditRepository.listRecent(limit: 10);
        expect(
          audits.any(
            (entry) =>
                entry.status == 'failed' &&
                entry.summary == 'Web app redeploy crashed before completion.',
          ),
          isTrue,
        );

        final unknownServer = await harness.request('GET', 'servers/missing');
        expect(unknownServer.statusCode, HttpStatus.notFound);
        expect(unknownServer.body['error'], 'invalid_server');

        final validKeyServer = await harness.serverRepository.createServer(
          draft: const ServerDraft(
            name: 'Keyed',
            host: '203.0.113.12',
            port: 22,
            sshUser: 'ubuntu',
            authMethod: ServerAuthMethod.sshKey,
            privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\ninline\n',
          ),
          specs: const ServerSpecs(osName: 'Ubuntu 24.04', cpuArch: 'x86_64'),
        );
        final keyedOverview = await harness.request(
          'GET',
          'servers/${validKeyServer.id}',
        );
        expect(keyedOverview.statusCode, HttpStatus.ok);
        expect(
          harness.sshService.runWorkflowCalls.last.connection!['private_key'],
          contains('BEGIN OPENSSH PRIVATE KEY'),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'repository fetch errors task lookup timeout and status payload fields are covered',
      () async {
        final fetchErrorHarness = await createHarness(
          authGateway: FakeGitHubAuthGateway(
            fetchRepositoriesError: StateError('repo lookup failed'),
          ),
        );
        await fetchErrorHarness.seedDefaultData();
        await fetchErrorHarness.enableAgentAccess();

        final repositoriesFailure = await fetchErrorHarness.request(
          'GET',
          'github/repositories',
        );
        expect(repositoriesFailure.statusCode, HttpStatus.ok);
        expect(repositoriesFailure.body['github_connected'], isFalse);
        expect(
          repositoriesFailure.body['message'],
          contains('GitHub repository listing failed'),
        );
        await fetchErrorHarness.dispose();

        final timeoutHarness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(deployTaskId: 999),
        );
        addTearDown(timeoutHarness.dispose);
        await timeoutHarness.seedDefaultData();
        await timeoutHarness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        final timeoutToken = (await timeoutHarness.preferencesRepository.read())
            .agentSessionToken!;
        final timeoutResponse = await timeoutHarness.request(
          'POST',
          'web-apps/${timeoutHarness.project!.id}/redeploy',
          bearerToken: timeoutToken,
          body: <String, dynamic>{
            'server_id': timeoutHarness.server!.id,
            'project_id': timeoutHarness.project!.id,
            'web_app_id': timeoutHarness.project!.id,
          },
        );
        expect(timeoutResponse.statusCode, HttpStatus.accepted);
        expect(timeoutResponse.body['operation_instance_id'], isNull);

        await timeoutHarness.dispose();

        final bindHarness = await createHarness();
        addTearDown(bindHarness.dispose);
        await bindHarness.service.initialize();
        final blocker = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          bindHarness.port,
        );
        addTearDown(() => blocker.close(force: true));
        await bindHarness.service.setEnabled(true);
        final bindStatus = await bindHarness.service.readStatus();
        expect(
          bindStatus.toJson()['server_error'],
          contains('Could not bind Agent Access server'),
        );
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);

  group('Agent Access tool analytics', () {
    test('successful tool calls report the tool name', () async {
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

      final response = await harness.mcpRequest('deploydash_status');
      expect(response.statusCode, HttpStatus.ok);

      expect(analytics.agentToolEvents, [
        (tool: 'deploydash_status', outcome: DataOperationOutcome.success),
      ]);
    }, skip: !sqliteAvailable);

    test('denied tool calls report the failure', () async {
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

      // A catalog tool that rejects its arguments: still a catalog name, so
      // the failure reports.
      final response = await harness.mcpRequest(
        'deploydash_list_postgres_schemas',
        arguments: <String, dynamic>{'project_id': harness.project!.id},
      );
      expect(response.statusCode, HttpStatus.badRequest);

      expect(analytics.agentToolEvents, [
        (
          tool: 'deploydash_list_postgres_schemas',
          outcome: DataOperationOutcome.failure,
        ),
      ]);
    }, skip: !sqliteAvailable);

    test('unknown tool names report nothing', () async {
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

      final response = await harness.mcpRequest('not_a_tool');
      expect(response.statusCode, HttpStatus.notFound);

      expect(analytics.agentToolEvents, isEmpty);
    }, skip: !sqliteAvailable);
  }, skip: !sqliteAvailable);
}
