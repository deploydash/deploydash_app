import 'package:flutter_test/flutter_test.dart';

import '_support/agent_access_harness.dart';

/// Agent Access PostgreSQL tools.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(3);

  group('Agent Access PostgreSQL tools', () {
    test(
      'project postgres read-only endpoints return expected payloads without a bearer token',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionReadOnly,
        );
        harness.sshService.postgresResponses = <String, Map<String, dynamic>>{
          'project_list': <String, dynamic>{
            'status': 'success',
            'engine_version': '17.4',
            'service_status': <String, dynamic>{
              'running': true,
              'configured': true,
            },
            'databases': <String>['dd_blog_app', 'dd_blog_analytics'],
          },
          'project_list_schemas': <String, dynamic>{
            'status': 'success',
            'schemas': <String>['public', 'audit'],
            'service_status': <String, dynamic>{'running': true},
          },
          'project_list_tables': <String, dynamic>{
            'status': 'success',
            'tables': <Map<String, dynamic>>[
              <String, dynamic>{
                'schema_name': 'public',
                'table_name': 'users',
                'object_type': 'table',
              },
            ],
            'service_status': <String, dynamic>{'running': true},
          },
          'project_describe_table': <String, dynamic>{
            'status': 'success',
            'schema_name': 'public',
            'table_name': 'users',
            'columns': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'id',
                'data_type': 'uuid',
                'is_nullable': false,
                'default_expression': null,
              },
            ],
            'primary_key_columns': <String>['id'],
            'indexes': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'users_pkey',
                'is_unique': true,
                'definition': 'CREATE UNIQUE INDEX users_pkey ...',
              },
            ],
            'foreign_keys': const <Map<String, dynamic>>[],
            'service_status': <String, dynamic>{'running': true},
          },
          'project_explain_readonly_query': <String, dynamic>{
            'status': 'success',
            'duration_ms': 11,
            'plan': <Map<String, dynamic>>[
              <String, dynamic>{
                'Plan': <String, dynamic>{'Node Type': 'Limit'},
              },
            ],
            'service_status': <String, dynamic>{'running': true},
          },
          'project_execute_readonly_query': <String, dynamic>{
            'status': 'success',
            'duration_ms': 15,
            'columns': <String>['id', 'email'],
            'rows': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'u_1', 'email': 'alice@example.com'},
            ],
            'row_count_returned': 1,
            'truncated': false,
            'service_status': <String, dynamic>{'running': true},
          },
        };

        final databases = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/databases',
        );
        expect(databases.statusCode, HttpStatus.ok);
        expect(
          (databases.body['databases'] as List<dynamic>).first,
          <String, dynamic>{'name': 'app', 'remote_name': 'dd_blog_app'},
        );

        final schemas = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/schemas',
          query: {'database_name': 'app'},
        );
        expect(schemas.statusCode, HttpStatus.ok);
        expect(schemas.body['schemas'], <String>['public', 'audit']);

        final tables = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/tables',
          query: {'database_name': 'app', 'schema_name': 'public'},
        );
        expect(tables.statusCode, HttpStatus.ok);
        expect(
          ((tables.body['tables'] as List<dynamic>).single
              as Map<String, dynamic>)['table_name'],
          'users',
        );

        final describe = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/table',
          query: {
            'database_name': 'app',
            'schema_name': 'public',
            'table_name': 'users',
          },
        );
        expect(describe.statusCode, HttpStatus.ok);
        expect(describe.body['primary_key_columns'], <String>['id']);

        final explain = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/explain-query',
          body: <String, dynamic>{
            'database_name': 'app',
            'sql': 'SELECT * FROM users ORDER BY id',
          },
        );
        expect(explain.statusCode, HttpStatus.ok);
        expect((explain.body['plan'] as List<dynamic>), isNotEmpty);

        final query = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/query',
          body: <String, dynamic>{
            'database_name': 'app',
            'sql': 'SELECT id, email FROM users',
            'max_rows': 50,
          },
        );
        expect(query.statusCode, HttpStatus.ok);
        expect(query.body['columns'], <String>['id', 'email']);
        expect(query.body['row_count_returned'], 1);
        expect(
          ((query.body['rows'] as List<dynamic>).single
              as Map<String, dynamic>)['email'],
          'alice@example.com',
        );

        expect(
          harness.sshService.runWorkflowCalls
              .where((call) => call.workflowId == 'postgres')
              .map((call) => call.operationId)
              .toList(growable: false),
          <String>[
            'project_list',
            'project_list_schemas',
            'project_list_tables',
            'project_describe_table',
            'project_explain_readonly_query',
            'project_execute_readonly_query',
          ],
        );
        final executeCall = harness.sshService.runWorkflowCalls.last;
        expect(
          ((executeCall.params!['settings']
              as Map<String, dynamic>)['database_name']),
          'app',
        );
        expect(
          ((executeCall.params!['settings']
              as Map<String, dynamic>)['superuser_password']),
          'pg-secret',
        );

        final audits = await harness.auditRepository.listRecent(limit: 12);
        final queryAudit = audits.firstWhere(
          (row) => row.toolName == 'deploydash_execute_postgres_readonly_query',
        );
        expect(queryAudit.accessLevel, 'read_only');
        expect(
          (queryAudit.details ?? const <String, dynamic>{}).containsKey('rows'),
          isFalse,
        );
        expect(
          (queryAudit.details ?? const <String, dynamic>{})['sql_preview'],
          contains('SELECT id, email FROM users'),
        );
        expect(
          (queryAudit.details ?? const <String, dynamic>{})['sql_sha256'],
          hasLength(64),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'project postgres tools forward the logical database name to the engine',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionReadOnly,
        );
        harness.sshService.postgresResponses = <String, Map<String, dynamic>>{
          'project_list_schemas': <String, dynamic>{
            'status': 'success',
            'schemas': <String>['public'],
            'service_status': <String, dynamic>{'running': true},
          },
        };

        final schemas = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/schemas',
          query: {'database_name': 'dd_blog_app'},
        );
        expect(schemas.statusCode, HttpStatus.ok);

        final schemasCall = harness.sshService.runWorkflowCalls.lastWhere(
          (call) => call.operationId == 'project_list_schemas',
        );
        expect(
          (schemasCall.params!['settings']
              as Map<String, dynamic>)['database_name'],
          'app',
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'project postgres routes surface precondition and workflow errors',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final unknownProject = await harness.request(
          'GET',
          'projects/missing/postgres/databases',
        );
        expect(unknownProject.statusCode, HttpStatus.notFound);
        expect(unknownProject.body['error'], 'invalid_project');

        await harness.serverRepository.updateServerServices(
          serverId: harness.server!.id,
          enableDatabases: false,
          enableEmailAccounts: false,
          enableDomains: false,
        );
        final postgresDisabled = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/databases',
        );
        expect(postgresDisabled.statusCode, HttpStatus.preconditionFailed);
        expect(postgresDisabled.body['error'], 'postgres_disabled');

        await harness.serverRepository.updateServerServices(
          serverId: harness.server!.id,
          enableDatabases: true,
          enableEmailAccounts: false,
          enableDomains: false,
        );
        await harness.serverRepository.updateServerPostgresConfig(
          serverId: harness.server!.id,
          config: const ServerPostgresConfig(postgresVersion: '17'),
        );
        final credentialsMissing = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/databases',
        );
        expect(credentialsMissing.statusCode, HttpStatus.preconditionFailed);
        expect(
          credentialsMissing.body['error'],
          'postgres_credentials_missing',
        );

        await harness.serverRepository.updateServerPostgresConfig(
          serverId: harness.server!.id,
          config: const ServerPostgresConfig(
            postgresVersion: '17',
            superuserPassword: 'pg-secret',
          ),
        );
        harness.sshService.postgresResponses = <String, Map<String, dynamic>>{
          'project_execute_readonly_query': <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_VALIDATION_ERROR',
            'msg': 'settings.sql must start with SELECT or WITH.',
            'details': 'invalid_sql',
          },
        };
        final invalidSql = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/query',
          body: <String, dynamic>{
            'database_name': 'app',
            'sql': 'DELETE FROM users',
          },
        );
        expect(invalidSql.statusCode, HttpStatus.badRequest);
        expect(invalidSql.body['error'], 'engine_validation_error');
      },
      skip: !sqliteAvailable,
    );

    test(
      'project postgres routes validate inputs and context errors',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        harness.sshService.postgresResponses = <String, Map<String, dynamic>>{
          'project_list': <String, dynamic>{
            'status': 'error',
            'code': 'ENGINE_RUNTIME_ERROR',
            'msg': 'listing failed',
          },
        };

        final listFailure = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/databases',
        );
        expect(listFailure.statusCode, HttpStatus.badGateway);
        expect(listFailure.body['error'], 'engine_runtime_error');

        final missingSchemasDatabase = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/schemas',
        );
        expect(missingSchemasDatabase.statusCode, HttpStatus.badRequest);
        expect(missingSchemasDatabase.body['error'], 'invalid_database');

        final missingTablesDatabase = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/tables',
        );
        expect(missingTablesDatabase.statusCode, HttpStatus.badRequest);
        expect(missingTablesDatabase.body['error'], 'invalid_database');

        final missingDescribeDatabase = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/table',
          query: {'table_name': 'users'},
        );
        expect(missingDescribeDatabase.statusCode, HttpStatus.badRequest);
        expect(missingDescribeDatabase.body['error'], 'invalid_database');

        final missingDescribeTable = await harness.request(
          'GET',
          'projects/${harness.project!.id}/postgres/table',
          query: {'database_name': 'app'},
        );
        expect(missingDescribeTable.statusCode, HttpStatus.badRequest);
        expect(missingDescribeTable.body['error'], 'invalid_table');

        final missingExplainDatabase = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/explain-query',
          body: <String, dynamic>{'sql': 'SELECT 1'},
        );
        expect(missingExplainDatabase.statusCode, HttpStatus.badRequest);
        expect(missingExplainDatabase.body['error'], 'invalid_database');

        final missingExplainSql = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/explain-query',
          body: <String, dynamic>{'database_name': 'app'},
        );
        expect(missingExplainSql.statusCode, HttpStatus.badRequest);
        expect(missingExplainSql.body['error'], 'invalid_sql');

        final missingQueryDatabase = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/query',
          body: <String, dynamic>{'sql': 'SELECT 1'},
        );
        expect(missingQueryDatabase.statusCode, HttpStatus.badRequest);
        expect(missingQueryDatabase.body['error'], 'invalid_database');

        final missingQuerySql = await harness.request(
          'POST',
          'projects/${harness.project!.id}/postgres/query',
          body: <String, dynamic>{'database_name': 'app'},
        );
        expect(missingQuerySql.statusCode, HttpStatus.badRequest);
        expect(missingQuerySql.body['error'], 'invalid_sql');
      },
      skip: !sqliteAvailable,
    );

    test(
      'project postgres context errors cover missing server links and invalid credentials',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        await harness.projectRepository.createProject(
          const Project(
            id: 'project-no-server',
            name: 'No Server',
            type: 'Web app',
            gitUrl: 'https://github.com/me/no-server',
            primaryDomain: 'no-server.example.com',
          ),
        );
        final missingServerLink = await harness.request(
          'GET',
          'projects/project-no-server/postgres/databases',
        );
        expect(missingServerLink.statusCode, HttpStatus.preconditionFailed);
        expect(missingServerLink.body['error'], 'project_server_missing');

        await harness.projectRepository.createProject(
          const Project(
            id: 'project-stale-server',
            serverId: 'missing-server',
            name: 'Stale Server',
            type: 'Web app',
            gitUrl: 'https://github.com/me/stale-server',
            primaryDomain: 'stale-server.example.com',
          ),
        );
        final staleServer = await harness.request(
          'GET',
          'projects/project-stale-server/postgres/databases',
        );
        expect(staleServer.statusCode, HttpStatus.notFound);
        expect(staleServer.body['error'], 'invalid_server');

        final invalidConnectionHarness = await createHarness();
        addTearDown(invalidConnectionHarness.dispose);
        await invalidConnectionHarness.seedDefaultData(validServer: false);
        await invalidConnectionHarness.enableAgentAccess();
        final invalidConnection = await invalidConnectionHarness.request(
          'GET',
          'projects/${invalidConnectionHarness.project!.id}/postgres/databases',
        );
        expect(invalidConnection.statusCode, HttpStatus.badRequest);
        expect(invalidConnection.body['error'], 'invalid_connection');
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);
}
