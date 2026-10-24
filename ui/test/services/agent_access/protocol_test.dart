import 'package:flutter_test/flutter_test.dart';

import '_support/agent_access_harness.dart';

/// Agent Access MCP protocol methods.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(2);

  group('AgentAccessService MCP protocol methods', () {
    test(
      'ping, tools/list and resources/list answer over a live session',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final ping = await harness.mcpMethod('ping');
        expect(ping.statusCode, HttpStatus.ok);
        expect(ping.body['result'], <String, dynamic>{});

        final tools = await harness.mcpMethod('tools/list');
        final listed = (tools.body['result'] as Map)['tools'] as List;
        final names = listed
            .map((tool) => (tool as Map)['name'] as String)
            .toSet();
        // Read-only mode: the three redeploy tools are not even named, so an
        // agent cannot discover a capability the user has not granted.
        expect(names, agentAccessReadOnlyToolNames);
        expect(names.intersection(agentAccessActionToolNames), isEmpty);

        final resources = await harness.mcpMethod('resources/list');
        final uris = ((resources.body['result'] as Map)['resources'] as List)
            .map((resource) => (resource as Map)['uri'] as String)
            .toList();
        expect(uris, <String>[
          'deploydash://status',
          'deploydash://servers',
          'deploydash://projects',
          'deploydash://web-apps',
          'deploydash://workflow-catalog',
          'deploydash://recent-task-history',
          'deploydash://agent-session-status',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'tools/list adds the redeploy tools once the user grants them',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
        );

        final tools = await harness.mcpMethod('tools/list');
        final names = ((tools.body['result'] as Map)['tools'] as List)
            .map((tool) => (tool as Map)['name'] as String)
            .toSet();

        expect(names, containsAll(agentAccessActionToolNames));
        expect(names, containsAll(agentAccessReadOnlyToolNames));
      },
      skip: !sqliteAvailable,
    );

    test('every published resource reads back as JSON text', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      for (final uri in const <String>[
        'deploydash://status',
        'deploydash://servers',
        'deploydash://projects',
        'deploydash://web-apps',
        'deploydash://workflow-catalog',
        'deploydash://recent-task-history',
        'deploydash://agent-session-status',
      ]) {
        final read = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': uri},
        );
        expect(read.statusCode, HttpStatus.ok, reason: uri);
        final contents = (read.body['result'] as Map)['contents'] as List;
        final entry = contents.single as Map;
        expect(entry['uri'], uri);
        expect(entry['mimeType'], 'application/json');
        expect(
          jsonDecode(entry['text'] as String),
          isA<Map<String, dynamic>>(),
          reason: '$uri must carry a decodable JSON body',
        );
      }
    }, skip: !sqliteAvailable);

    test(
      'the session-status resource reports the current mode and port',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess(
          permissionMode: agentAccessPermissionRedeploy,
          issueSession: true,
        );

        final read = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': 'deploydash://agent-session-status'},
        );
        final contents = (read.body['result'] as Map)['contents'] as List;
        final status =
            (jsonDecode((contents.single as Map)['text'] as String)
                    as Map)['session_status']
                as Map;

        expect(status['enabled'], isTrue);
        expect(status['permission_mode'], agentAccessPermissionRedeploy);
        expect(status['server_running'], isTrue);
        expect(status['port'], harness.port);
        expect(status['has_active_session'], isTrue);
        expect(status['session_expires_at'], isNotNull);
      },
      skip: !sqliteAvailable,
    );

    test(
      'the task-history resource carries completed app tasks only',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final read = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': 'deploydash://recent-task-history'},
        );
        final contents = (read.body['result'] as Map)['contents'] as List;
        final history =
            (jsonDecode((contents.single as Map)['text'] as String)
                    as Map)['task_history']
                as List;

        // 701 is still running and 699 is a postgres task; only the completed
        // app task belongs in the recent-results resource.
        expect(history.map((entry) => (entry as Map)['task_id']), <int>[700]);
        expect((history.single as Map)['status'], 'success');
      },
      skip: !sqliteAvailable,
    );

    test(
      'an unknown resource, a missing uri, and an unknown method are refused',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final unknownResource = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{'uri': 'deploydash://nope'},
        );
        expect(unknownResource.statusCode, HttpStatus.notFound);
        expect(unknownResource.body['error'], 'resource_not_found');

        final missingUri = await harness.mcpMethod(
          'resources/read',
          params: <String, dynamic>{},
        );
        expect(missingUri.statusCode, HttpStatus.badRequest);
        expect(missingUri.body['error'], 'invalid_resource');

        final unknownMethod = await harness.mcpMethod('does/not-exist');
        expect(unknownMethod.statusCode, HttpStatus.notFound);
        expect(unknownMethod.body['error'], 'method_not_found');

        final namelessTool = await harness.mcpMethod(
          'tools/call',
          params: <String, dynamic>{'arguments': <String, dynamic>{}},
        );
        expect(namelessTool.statusCode, HttpStatus.badRequest);
        expect(namelessTool.body['error'], 'invalid_tool');
      },
      skip: !sqliteAvailable,
    );

    test('agentAnalyticsToolNameOrNull admits only frozen catalog names', () {
      final catalogNames = mcpToolDefinitions(
        includeActionTools: true,
      ).map((tool) => tool.name).toList(growable: false);
      expect(catalogNames, hasLength(29));
      for (final name in catalogNames) {
        expect(agentAnalyticsToolNameOrNull(name), name, reason: name);
      }
      expect(agentAnalyticsToolNameOrNull(''), isNull);
      expect(agentAnalyticsToolNameOrNull('not_a_tool'), isNull);
      // Legacy-shaped and case variants are not catalog names.
      expect(agentAnalyticsToolNameOrNull('server_overview'), isNull);
      expect(agentAnalyticsToolNameOrNull('DEPLOYDASH_STATUS'), isNull);
    }, skip: !sqliteAvailable);
  });
}
