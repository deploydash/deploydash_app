import 'package:flutter_test/flutter_test.dart';

import '_support/agent_access_harness.dart';

/// Agent Access upstream failure paths.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(1);

  group('AgentAccessService upstream failure paths', () {
    test(
      'a thrown overview workflow becomes a 500 rather than escaping',
      () async {
        final ssh = FakeSSHService()
          ..overviewThrows = StateError('ssh exploded');
        final harness = await createHarness(sshService: ssh);
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.request(
          'GET',
          'servers/${harness.server!.id}',
        );

        expect(response.statusCode, HttpStatus.internalServerError);
        expect(response.body['error'], 'internal_error');
        // The exception text must NOT reach the client. This assertion used
        // to be `contains('ssh exploded')`, which froze the leak: whatever an
        // exception stringifies to went straight out to whoever holds the
        // socket, and an engine failure wrapping a connection carries host,
        // user and path detail into it. The stack still goes to stderr.
        expect(response.body['message'], isNot(contains('ssh exploded')));
        expect(
          response.body['message'],
          "Deploy Dash could not read this server's overview.",
        );
      },
      skip: !sqliteAvailable,
    );

    test('every task tool refuses a read-only session', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      // The task family is the one group gated on the bearer token, and each
      // member checks independently -- so each is asserted independently.
      for (final call in <(String, String)>[
        ('GET', 'tasks/history'),
        ('GET', 'tasks/701'),
        ('GET', 'tasks/701/events'),
        ('GET', 'tasks/701/result'),
        ('POST', 'tasks/701/cancel'),
      ]) {
        final response = await harness.request(call.$1, call.$2);
        expect(
          response.statusCode,
          HttpStatus.forbidden,
          reason: '${call.$1} ${call.$2} must require redeploy permission',
        );
        expect(response.body['error'], 'permission_denied');
      }
    }, skip: !sqliteAvailable);

    test(
      'an engine failure reaching task history keeps the engine message',
      () async {
        final ssh = FakeSSHService()
          ..historyFailure = const EngineFailure(
            code: 'ENGINE_TASK_LOOKUP_FAILED',
            msg: 'Task store is unavailable.',
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
          'GET',
          'tasks/history',
          bearerToken: token,
        );

        expect(response.statusCode, HttpStatus.badGateway);
        expect(response.body['error'], 'engine_error');
        // The engine's own sentence, not a stringified Dart object.
        expect(response.body['message'], 'Task store is unavailable.');
      },
      skip: !sqliteAvailable,
    );

    test(
      'a non-engine failure falls back to the failure description',
      () async {
        final ssh = FakeSSHService()
          ..historyEntryFailure = const ConnectionFailure('Socket closed.');
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
          'GET',
          'tasks/701',
          bearerToken: token,
        );

        expect(response.statusCode, HttpStatus.badGateway);
        expect(response.body['error'], 'engine_error');
        expect(response.body['message'], contains('Socket closed.'));
      },
      skip: !sqliteAvailable,
    );

    test(
      'a failed cancellation reports cancelled false rather than throwing',
      () async {
        final ssh = FakeSSHService()
          ..cancelFailure = const ConnectionFailure('Engine unreachable.');
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
          'tasks/701/cancel',
          bearerToken: token,
        );

        expect(response.statusCode, HttpStatus.badGateway);
        expect(response.body['cancelled'], isFalse);
        expect(response.body['task_id'], 701);
      },
      skip: !sqliteAvailable,
    );

    test(
      'runtime logs for an unknown server id report an invalid server',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.request(
          'GET',
          'web-apps/${harness.project!.id}/runtime-logs',
          query: <String, String>{'server_id': 'server-that-does-not-exist'},
        );

        expect(response.statusCode, HttpStatus.notFound);
        expect(response.body['error'], 'invalid_server');
      },
      skip: !sqliteAvailable,
    );

    test(
      'a failed postgres workflow surfaces the engine diagnostics it carries',
      () async {
        final ssh = FakeSSHService()
          ..postgresResponses['project_list_schemas'] = <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_VALIDATION_ERROR',
            'msg': 'Database is not reachable.',
            'details': 'connection refused',
            'service_status': <String, dynamic>{'running': false},
            'engine_version': '17.8',
            'host': '203.0.113.10',
            'port': 5432,
            'operation_id': 'project_list_schemas',
          };
        final harness = await createHarness(sshService: ssh);
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/schemas',
          query: <String, String>{'database_name': 'app'},
        );

        expect(response.statusCode, HttpStatus.badRequest);
        expect(response.body['error'], 'engine_validation_error');
        expect(response.body['message'], 'Database is not reachable.');
        expect(response.body['details'], 'connection refused');
        expect(response.body['service_status'], <String, dynamic>{
          'running': false,
        });
        expect(response.body['engine_version'], '17.8');
        expect(response.body['host'], '203.0.113.10');
        expect(response.body['port'], 5432);
        expect(response.body['operation_id'], 'project_list_schemas');
      },
      skip: !sqliteAvailable,
    );

    test(
      'a long query is audited by a bounded preview and a full-text hash',
      () async {
        final ssh = FakeSSHService()
          ..postgresResponses['project_execute_readonly_query'] =
              <String, dynamic>{
                'status': 'success',
                'remote_database_name': 'dd_blog_app',
                'row_count_returned': 3,
                'truncated': false,
                'duration_ms': 12,
              };
        final harness = await createHarness(sshService: ssh);
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final sql =
            'SELECT ${List<String>.filled(80, 'column_name').join(', ')} '
            'FROM widgets';
        expect(sql.length, greaterThan(240));

        final response = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/query',
          body: <String, dynamic>{'database_name': 'app', 'sql': sql},
        );
        expect(response.statusCode, HttpStatus.ok);

        final audited = (await harness.auditRepository.listRecent(limit: 5))
            .firstWhere(
              (entry) =>
                  entry.toolName ==
                  'deploydash_execute_postgres_readonly_query',
            );
        final details = audited.details!;
        // Truncated, not omitted: the preview is for a human reading the trail,
        // and the sha256 is what identifies the statement exactly.
        expect((details['sql_preview'] as String).length, 240);
        expect(sql, startsWith(details['sql_preview'] as String));
        expect(details['sql_sha256'], hasLength(64));
        expect(details['remote_database_name'], 'dd_blog_app');
        expect(details['row_count_returned'], 3);
        expect(details['truncated'], isFalse);
        expect(details['duration_ms'], 12);
      },
      skip: !sqliteAvailable,
    );
  });
}
