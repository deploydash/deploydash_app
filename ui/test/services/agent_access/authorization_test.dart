import 'package:flutter_test/flutter_test.dart';

import '_support/agent_access_harness.dart';

/// Agent Access authorization and session state.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(0);

  group('Agent Access authorization and session state', () {
    test(
      'service methods manage enabled state permission mode and session',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);

        await harness.service.initialize();
        var status = await harness.service.readStatus();
        expect(status.enabled, isFalse);
        expect(status.permissionMode, agentAccessPermissionReadOnly);
        expect(status.serverRunning, isFalse);
        expect(status.runningTasks, isEmpty);
        expect(status.recentTaskResults, isEmpty);

        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );
        status = await harness.service.readStatus();
        expect(status.enabled, isTrue);
        expect(status.permissionMode, agentAccessPermissionRedeploy);
        expect(status.serverRunning, isTrue);
        expect(status.hasActiveSession, isTrue);
        expect(status.recentActions, isNotEmpty);

        await expectLater(
          () => harness.service.issueSession(),
          throwsA(isA<StateError>()),
        );

        await harness.service.setPermissionMode('unknown-mode');
        status = await harness.service.readStatus();
        expect(status.permissionMode, agentAccessPermissionReadOnly);
        expect(status.hasActiveSession, isFalse);

        await harness.service.revokeSession();
        await harness.service.setEnabled(false);
        status = await harness.service.readStatus();
        expect(status.enabled, isFalse);
        expect(status.serverRunning, isFalse);
      },
      skip: !sqliteAvailable,
    );

    test(
      'error responses cover disabled auth validation and invalid requests',
      () async {
        final harness = await createHarness(
          notifier: FakeGitHubIntegrationNotifier(
            branchError: StateError('boom'),
          ),
        );
        addTearDown(harness.dispose);
        await harness.seedDefaultData(validServer: false);
        await harness.enableAgentAccess();

        await harness.preferencesRepository.setAgentAccessEnabled(false);
        final disabledResponse = await harness.request('GET', 'status');
        expect(disabledResponse.statusCode, HttpStatus.serviceUnavailable);
        expect(disabledResponse.body['error'], 'agent_access_disabled');
        await harness.preferencesRepository.setAgentAccessEnabled(true);
        final token = await harness.service.issueSession(
          duration: const Duration(hours: 1),
        );

        final notFound = await harness.request('GET', 'unknown/path');
        expect(notFound.statusCode, HttpStatus.notFound);

        final invalidServerOverview = await harness.request(
          'GET',
          'servers/${harness.server!.id}',
        );
        expect(invalidServerOverview.statusCode, HttpStatus.badRequest);
        expect(invalidServerOverview.body['error'], 'invalid_connection');

        final missingRuntimeServer = await harness.request(
          'GET',
          'web-apps/${harness.project!.id}/runtime-logs',
        );
        expect(missingRuntimeServer.statusCode, HttpStatus.badRequest);
        expect(missingRuntimeServer.body['error'], 'invalid_server');

        final otherServer = await harness.serverRepository.createServer(
          draft: const ServerDraft(
            name: 'Staging-01',
            host: '203.0.113.11',
            port: 22,
            sshUser: 'root',
            authMethod: ServerAuthMethod.password,
            sshPassword: 'secret',
          ),
          specs: const ServerSpecs(osName: 'Ubuntu 24.04', cpuArch: 'x86_64'),
        );
        final mismatchedRuntimeServer = await harness.request(
          'GET',
          'web-apps/${harness.project!.id}/runtime-logs',
          query: {'server_id': otherServer.id},
        );
        expect(mismatchedRuntimeServer.statusCode, HttpStatus.badRequest);
        expect(
          mismatchedRuntimeServer.body['error'],
          'project_server_mismatch',
        );

        final missingRepo = await harness.request(
          'GET',
          'github/repository-branches',
        );
        expect(missingRepo.statusCode, HttpStatus.badRequest);
        expect(missingRepo.body['error'], 'invalid_repository');

        harness.secretRepository.authToken = null;
        final disconnectedRepos = await harness.request(
          'GET',
          'github/repositories',
        );
        expect(disconnectedRepos.statusCode, HttpStatus.ok);
        expect(disconnectedRepos.body['github_connected'], isFalse);
        expect(disconnectedRepos.body['reconnect_required'], isTrue);

        final disconnectedBranches = await harness.request(
          'GET',
          'github/repository-branches',
          query: {'repository_full_name': 'me/blog'},
        );
        expect(disconnectedBranches.statusCode, HttpStatus.preconditionFailed);
        expect(disconnectedBranches.body['error'], 'github_reconnect_required');

        harness.secretRepository.authToken = 'token-123';
        final failingBranches = await harness.request(
          'GET',
          'github/repository-branches',
          query: {'repository_full_name': 'me/blog'},
        );
        expect(failingBranches.statusCode, HttpStatus.preconditionFailed);
        expect(failingBranches.body['error'], 'github_reconnect_required');

        await harness.service.setPermissionMode(agentAccessPermissionRedeploy);
        final missingTask = await harness.request(
          'GET',
          'tasks/999',
          bearerToken: token,
        );
        expect(missingTask.statusCode, HttpStatus.notFound);
        expect(missingTask.body['error'], 'task_not_found');

        // A malformed `task_id` is the client's mistake, so it is a 400 and
        // not a 500. It used to answer `internal_error` with the message
        // 'Bad state: Task id must be an integer.' -- a Dart `StateError`
        // prefix fossilised into the wire format from a version that caught
        // and stringified an exception this code no longer throws. All four
        // task tools now share `_replyCancelTask`'s always-correct answer.
        final invalidTask = await harness.request(
          'GET',
          'tasks/not-a-number',
          bearerToken: token,
        );
        expect(invalidTask.statusCode, HttpStatus.badRequest);
        expect(invalidTask.body['error'], 'invalid_task_id');
        expect(invalidTask.body['message'], 'Task id must be an integer.');

        harness.sshService.taskEventsError = StateError('events unavailable');
        final taskEventsError = await harness.request(
          'GET',
          'tasks/701/events',
          bearerToken: token,
        );
        expect(taskEventsError.statusCode, HttpStatus.badGateway);
        harness.sshService.taskEventsError = null;

        harness.sshService.taskResultError = StateError('result unavailable');
        final taskResultError = await harness.request(
          'GET',
          'tasks/701/result',
          bearerToken: token,
        );
        expect(taskResultError.statusCode, HttpStatus.badGateway);
        harness.sshService.taskResultError = null;
        await harness.service.setPermissionMode(agentAccessPermissionReadOnly);

        final badConflict = await harness.request(
          'POST',
          'tasks/evaluate-conflict',
          body: const <String, dynamic>{'workflow_id': 'app'},
        );
        expect(badConflict.statusCode, HttpStatus.badRequest);
        expect(badConflict.body['error'], 'invalid_request');

        final preview = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/prepare-redeploy',
          body: const <String, dynamic>{
            'server_id': 'missing',
            'project_id': 'wrong-project',
            'web_app_id': 'wrong-app',
            'repository_full_name': 'wrong/repo',
            'primary_hostname': 'not configured',
            'hostname_behavior': 'wrong_behavior',
            'branch': 'bad branch name!',
            'port': 99999,
            'runtime': 'perl',
          },
        );
        expect(preview.statusCode, HttpStatus.ok);
        expect(preview.body['can_redeploy'], isFalse);
        final errors = (preview.body['validation_errors'] as List<dynamic>)
            .cast<String>();
        expect(errors, contains('server_id does not match a saved server.'));
        expect(
          errors,
          contains('project_id does not match the selected web app.'),
        );
        expect(
          errors,
          contains(
            'repository_full_name must come from list_github_repositories.',
          ),
        );
        expect(errors, contains('primary_hostname must be a valid FQDN.'));
        expect(
          errors.any(
            (item) => item.contains('hostname_behavior must be one of'),
          ),
          isTrue,
        );
        expect(errors, contains('branch contains invalid characters.'));
        expect(errors, contains('port must be between 1 and 65535.'));
        expect(
          errors,
          contains('runtime must be one of the supported runtime ids.'),
        );
        expect(preview.body['approval_required'], isTrue);

        final mismatchedServerPreview = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/prepare-redeploy',
          body: <String, dynamic>{'server_id': otherServer.id},
        );
        expect(mismatchedServerPreview.statusCode, HttpStatus.ok);
        expect(mismatchedServerPreview.body['can_redeploy'], isFalse);
        expect(
          (mismatchedServerPreview.body['validation_errors'] as List<dynamic>)
              .cast<String>(),
          contains('server_id does not match the selected web app server.'),
        );

        final permissionDenied = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          body: <String, dynamic>{'server_id': harness.server!.id},
        );
        expect(permissionDenied.statusCode, HttpStatus.forbidden);
        expect(permissionDenied.body['error'], 'permission_denied');

        await harness.service.setPermissionMode(agentAccessPermissionRedeploy);
        final sessionRequired = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          body: <String, dynamic>{'server_id': harness.server!.id},
        );
        expect(sessionRequired.statusCode, HttpStatus.forbidden);
        expect(sessionRequired.body['error'], 'session_required');

        final refreshedToken = await harness.service.issueSession();
        final invalidToken = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: '$refreshedToken-wrong',
          body: <String, dynamic>{'server_id': harness.server!.id},
        );
        expect(invalidToken.statusCode, HttpStatus.forbidden);
        expect(invalidToken.body['error'], 'invalid_token');

        final validationFailure = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: refreshedToken,
          body: const <String, dynamic>{'server_id': 'missing'},
        );
        expect(validationFailure.statusCode, HttpStatus.badRequest);
        expect(validationFailure.body['error'], 'validation_failed');

        harness.secretRepository.authToken = null;
        final reconnectFailure = await harness.request(
          'POST',
          'web-apps/${harness.project!.id}/redeploy',
          bearerToken: refreshedToken,
          body: <String, dynamic>{'server_id': harness.server!.id},
        );
        expect(reconnectFailure.statusCode, HttpStatus.preconditionFailed);
        expect(reconnectFailure.body['error'], 'github_reconnect_required');

        final invalidCancel = await harness.request(
          'POST',
          'tasks/not-a-number/cancel',
          bearerToken: refreshedToken,
        );
        expect(invalidCancel.statusCode, HttpStatus.badRequest);
        expect(invalidCancel.body['error'], 'invalid_task_id');

        harness.sshService.cancelReturnValue = false;
        final failedCancel = await harness.request(
          'POST',
          'tasks/701/cancel',
          bearerToken: refreshedToken,
        );
        expect(failedCancel.statusCode, HttpStatus.badGateway);
        expect(failedCancel.body['cancelled'], isFalse);

        final unknownWebApp = await harness.request('GET', 'web-apps/unknown');
        expect(unknownWebApp.statusCode, HttpStatus.notFound);
        expect(unknownWebApp.body['error'], 'unknown_web_app');
      },
      skip: !sqliteAvailable,
    );

    test(
      'the MCP endpoint refuses a foreign Origin and allows a client that sends none',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        Future<JsonResponse> initializeWith(String? origin) {
          return harness.rawRequest(
            'POST',
            deployDashAgentMcpPath,
            body: jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'initialize',
              'params': <String, dynamic>{
                'protocolVersion': '2025-03-26',
                'capabilities': <String, dynamic>{},
                'clientInfo': <String, dynamic>{
                  'name': 'deploydash-test',
                  'version': '1.0.0',
                },
              },
            }),
            headers: origin == null ? null : <String, String>{'origin': origin},
          );
        }

        // A real MCP client sends no Origin. Asserted first: getting this
        // wrong breaks every legitimate user, which is worse than the hole.
        final noOrigin = await initializeWith(null);
        expect(noOrigin.statusCode, HttpStatus.ok);

        final localOrigin = await initializeWith(
          'http://127.0.0.1:${harness.port}',
        );
        expect(localOrigin.statusCode, HttpStatus.ok);

        final foreignOrigin = await initializeWith('https://evil.example');
        expect(foreignOrigin.statusCode, HttpStatus.forbidden);
        expect(foreignOrigin.body['error'], 'forbidden_origin');

        // Contains 127.0.0.1 but the host belongs to the attacker -- the case
        // a substring check would wave through.
        final lookalike = await initializeWith(
          'https://127.0.0.1.evil.example',
        );
        expect(
          lookalike.statusCode,
          HttpStatus.forbidden,
          reason: 'the origin is parsed, not substring-matched',
        );

        // The guard deliberately runs before the enabled check so a refusal
        // cannot reveal whether Agent Access is on. That ordering is not
        // observable from here: disabling closes the socket, so there is
        // nothing left to connect to. It stays for defence in depth.
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);

  group('AgentAccessService hardening', () {
    tearDown(() {
      deployDashAgentMcpSessionIdleTimeoutOverrideForTests = null;
    });

    test('a session idle past its timeout is refused', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      await harness.mcpMethod('ping');
      final sessionId = harness.mcpSessionId!;

      // Every refusal in this transport already said "invalid or **expired**"
      // while nothing ever expired: `lastSeenAt` was written by `touch()` and
      // read by nobody, so `_mcpSessions` grew one entry per `initialize` for
      // as long as the app ran.
      deployDashAgentMcpSessionIdleTimeoutOverrideForTests = Duration.zero;

      final response = await harness.rawRequest(
        'POST',
        deployDashAgentMcpPath,
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'tools/list',
        }),
        headers: <String, String>{testMcpSessionIdHeader: sessionId},
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(
        (response.body['error'] as Map)['message'],
        'Invalid or expired MCP session id.',
      );
    }, skip: !sqliteAvailable);

    test('a session used inside its window survives', () async {
      // The other half: an expiry that drops live sessions would break every
      // client while looking like a fix.
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      deployDashAgentMcpSessionIdleTimeoutOverrideForTests = const Duration(
        minutes: 5,
      );

      await harness.mcpMethod('ping');
      final sessionId = harness.mcpSessionId!;
      final second = await harness.mcpMethod('tools/list');

      expect(second.statusCode, HttpStatus.ok);
      expect(second.headers[testMcpSessionIdHeader], sessionId);
    }, skip: !sqliteAvailable);

    test(
      'an unhandled failure does not put its exception text on the wire',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        // `_buildRedeployPreview` calls `_requireProject`, which throws
        // `StateError('Unknown web app/project id: ...')`, and nothing between
        // there and the transport catches it. The catch-all used to write
        // `error.toString()` straight out to whoever held the socket.
        final response = await harness.mcpMethod(
          'tools/call',
          params: <String, dynamic>{
            'name': 'deploydash_prepare_web_app_redeploy',
            'arguments': <String, dynamic>{'web_app_id': 'ghost-project'},
          },
        );

        expect(response.statusCode, HttpStatus.internalServerError);
        final error = response.body['error'] as Map;
        expect(error['code'], -32603);
        expect(
          error['message'],
          'Agent Access could not complete the request.',
        );
        expect(error['message'], isNot(contains('ghost-project')));
        expect(error['message'], isNot(contains('Bad state')));
      },
      skip: !sqliteAvailable,
    );

    test('reading the audit trail is itself audited', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      final response = await harness.mcpMethod(
        'tools/call',
        params: <String, dynamic>{
          'name': 'deploydash_read_audit',
          'arguments': <String, dynamic>{},
        },
      );
      expect(response.statusCode, HttpStatus.ok);

      // Recorded after the read, so it is absent from its own result and
      // present in the next one. Reading the trail was the one agent action
      // the trail did not show.
      final entries = await harness.auditRepository.listRecent(limit: 10);
      expect(entries.map((entry) => entry.toolName), contains('read_audit'));
    }, skip: !sqliteAvailable);

    test(
      'the workflow catalog hides action tools from a read-only session',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        // `tools/list` and `deploydash_list_workflows` both gate this on the
        // permission mode. The catalog resource passed `includeActionTools:
        // true` unconditionally, so a read-only session that could not get
        // `tools/list` to name the redeploy tools could read them here.
        final response = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': 'deploydash://workflow-catalog'},
        );
        expect(response.statusCode, HttpStatus.ok);

        final contents =
            (response.body['result'] as Map)['contents'] as List<dynamic>;
        final text = (contents.single as Map)['text'] as String;
        final catalog = jsonDecode(text) as Map<String, dynamic>;

        expect(catalog['action_tools'], isEmpty);
        expect(text, isNot(contains('deploydash_redeploy_web_app')));
      },
      skip: !sqliteAvailable,
    );

    test(
      'the workflow catalog still names action tools in redeploy mode',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );

        final response = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': 'deploydash://workflow-catalog'},
        );

        final contents =
            (response.body['result'] as Map)['contents'] as List<dynamic>;
        final text = (contents.single as Map)['text'] as String;
        final catalog = jsonDecode(text) as Map<String, dynamic>;

        expect(catalog['action_tools'], isNotEmpty);
        expect(text, contains('deploydash_redeploy_web_app'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'runtime logs for an unknown web app report an unknown web app',
      () async {
        // The counterpart of the existing unknown-server-id test. Both used to
        // be recovered from one `StateError` by testing its message for
        // 'Unknown server id', so rewording that string in another file would
        // have swapped these two answers with no test failing -- both are 404s.
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.request(
          'GET',
          'web-apps/ghost-project/runtime-logs',
          query: <String, String>{'server_id': harness.server!.id},
        );

        expect(response.statusCode, HttpStatus.notFound);
        expect(response.body['error'], 'unknown_web_app');
      },
      skip: !sqliteAvailable,
    );
  });
}
