import 'package:ui/providers/agent_access/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Agent Access MCP surface is a published contract.
///
/// `deploydash-agent-access-skill/` and the repo-root `DEPLOYDASH_SKILL.md`
/// tell external agents to depend on these tool names, so a rename is a
/// breaking change to somebody else's integration. This file is the freeze:
/// the names below are stated literally, not derived from the service, so a
/// change to either one fails here and has to be a deliberate act.
///
/// Changing this list requires bumping [agentAccessSurfaceVersion].
/// That is the whole point of the test — the version and the names move
/// together.
void main() {
  // Frozen 2026-09-04 at surface version 2. Transcribed from the running
  // service, then read back against its tool catalog.
  //
  // The names are unchanged from version 1. The bump is for what
  // `deploydash_redeploy_web_app` returns when the deploy has not
  // reported a task id in time: a 202 `pending_confirmation` rather
  // than a 502, because the deploy is still running and a 502 invites
  // a retry that would start a second one.
  const readOnlyTools = <String>{
    'deploydash_describe_postgres_table',
    'deploydash_evaluate_conflict',
    'deploydash_execute_postgres_readonly_query',
    'deploydash_explain_postgres_query',
    'deploydash_get_deploy_history',
    'deploydash_get_deploy_logs',
    'deploydash_get_runtime_logs',
    'deploydash_get_server_overview',
    'deploydash_get_task',
    'deploydash_get_task_events',
    'deploydash_get_task_history',
    'deploydash_get_task_result',
    'deploydash_get_web_app_details',
    'deploydash_get_web_app_source',
    'deploydash_get_web_app_status',
    'deploydash_list_github_repositories',
    'deploydash_list_postgres_databases',
    'deploydash_list_postgres_schemas',
    'deploydash_list_postgres_tables',
    'deploydash_list_projects',
    'deploydash_list_repository_branches',
    'deploydash_list_servers',
    'deploydash_list_web_apps',
    'deploydash_list_workflows',
    'deploydash_read_audit',
    'deploydash_status',
  };

  // Only reachable when the user has granted the redeploy permission mode.
  const actionTools = <String>{
    'deploydash_cancel_task',
    'deploydash_prepare_web_app_redeploy',
    'deploydash_redeploy_web_app',
  };

  test(
    'the surface version is an integer that external agents can compare',
    () {
      // Deliberately not the release version and not the MCP protocol date.
      // The tool names change on their own schedule, so they need their own
      // number; reusing either of the others would make a rename invisible to
      // an agent pinning a version.
      expect(agentAccessSurfaceVersion, 2);
    },
  );

  test('every read-only tool name is frozen at this surface version', () {
    expect(agentAccessReadOnlyToolNames, readOnlyTools);
  });

  test('every redeploy-gated tool name is frozen at this surface version', () {
    expect(agentAccessActionToolNames, actionTools);
  });

  test('a tool is either read-only or redeploy-gated, never both', () {
    // An action tool leaking into the read-only set would be reachable
    // without the user granting redeploy permission.
    expect(readOnlyTools.intersection(actionTools), isEmpty);
    expect(
      agentAccessReadOnlyToolNames.intersection(agentAccessActionToolNames),
      isEmpty,
    );
  });

  test('a published tool serializes the annotations a client reads', () {
    // The annotations block is part of the frozen surface: a client
    // decides whether to confirm with the user from
    // readOnlyHint and destructiveHint. Frozen here because until T-3.5.3 no
    // test had ever called tools/list successfully -- the only call in the
    // suite used a deleted session and asserted a 404.
    final tools = mcpToolDefinitions(includeActionTools: true);
    final byName = <String, Map<String, dynamic>>{
      for (final tool in tools) tool.name: tool.toJson(),
    };

    final readOnly = byName['deploydash_list_servers']!;
    expect(readOnly['name'], 'deploydash_list_servers');
    expect(readOnly['inputSchema'], isA<Map<String, dynamic>>());
    expect(readOnly['annotations'], <String, dynamic>{
      'title': 'deploydash_list_servers',
      'readOnlyHint': true,
      'destructiveHint': false,
      'idempotentHint': true,
      'openWorldHint': false,
    });

    final destructive = byName['deploydash_redeploy_web_app']!;
    expect(destructive['annotations'], <String, dynamic>{
      'title': 'deploydash_redeploy_web_app',
      'readOnlyHint': false,
      'destructiveHint': true,
      'idempotentHint': false,
      'openWorldHint': false,
    });
  });

  test('every published resource serializes as an application/json entry', () {
    final resources = mcpResourceDefinitions();

    expect(
      resources.map((resource) => resource.uri),
      containsAll(<String>['deploydash://status', 'deploydash://servers']),
    );
    for (final resource in resources) {
      final json = resource.toJson();
      expect(json['uri'], resource.uri);
      expect(json['name'], resource.name);
      expect(json['description'], resource.description);
      expect(json['mimeType'], 'application/json');
    }
  });

  test('a resource read carries the body as pretty-printed JSON text', () {
    final contents = buildResourceContents(
      'deploydash://status',
      const AgentAccessReply(200, <String, dynamic>{'enabled': true}),
    );

    final entries = contents['contents']! as List<Map<String, dynamic>>;
    expect(entries, hasLength(1));
    expect(entries.single['uri'], 'deploydash://status');
    expect(entries.single['mimeType'], 'application/json');
    // Indented, not compact: a human reading the resource is the point.
    expect(entries.single['text'], '{\n  "enabled": true\n}');
  });
}
