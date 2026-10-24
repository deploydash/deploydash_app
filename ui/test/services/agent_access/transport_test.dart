import 'package:flutter_test/flutter_test.dart';

import '_support/agent_access_harness.dart';

/// Agent Access transport.
///
/// One of seven files T-3.6.2 split `agent_access_service_test.dart` into,
/// along the same seams T-3.5.3 split the service itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();
  claimAgentAccessTestPortBlock(6);

  group('Agent Access transport', () {
    test(
      'MCP transport supports stream GET, session delete, and modern initialize negotiation',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final initialize = await harness.rawRequest(
          'POST',
          deployDashAgentMcpPath,
          body: jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 41,
            'method': 'initialize',
            'params': <String, dynamic>{
              'protocolVersion': '2026-07-28',
              'capabilities': <String, dynamic>{},
              'clientInfo': <String, dynamic>{
                'name': 'deploydash-test',
                'version': '1.0.0',
              },
            },
          }),
        );
        expect(initialize.statusCode, HttpStatus.ok);
        expect(
          (initialize.body['result']
              as Map<String, dynamic>)['protocolVersion'],
          '2026-07-28',
        );
        final sessionId = initialize.headers[testMcpSessionIdHeader];
        expect(sessionId, isNotNull);

        final streamProbe = await harness.openMcpEventStream(
          sessionId: sessionId,
        );
        expect(streamProbe.statusCode, HttpStatus.ok);
        expect(streamProbe.firstChunk, contains(': connected'));
        expect(streamProbe.headers[testMcpSessionIdHeader], sessionId);

        final missingSessionDelete = await harness.rawRequest(
          'DELETE',
          deployDashAgentMcpPath,
        );
        expect(missingSessionDelete.statusCode, HttpStatus.badRequest);

        final deleteSession = await harness.rawRequest(
          'DELETE',
          deployDashAgentMcpPath,
          headers: <String, String>{testMcpSessionIdHeader: sessionId!},
        );
        expect(deleteSession.statusCode, HttpStatus.noContent);

        final staleSessionCall = await harness.rawRequest(
          'POST',
          deployDashAgentMcpPath,
          body: jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 42,
            'method': 'tools/list',
            'params': <String, dynamic>{},
          }),
          headers: <String, String>{testMcpSessionIdHeader: sessionId},
        );
        expect(staleSessionCall.statusCode, HttpStatus.notFound);
      },
      skip: !sqliteAvailable,
    );
  }, skip: !sqliteAvailable);

  group('AgentAccessService transport edges', () {
    test(
      'a method other than GET, POST or DELETE is refused with Allow',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.rawRequest(
          'PUT',
          deployDashAgentMcpPath,
          body: jsonEncode(<String, dynamic>{'jsonrpc': '2.0'}),
        );

        expect(response.statusCode, HttpStatus.methodNotAllowed);
        expect(response.body['error'], 'method_not_allowed');
        // The Allow header is what tells a client which verbs exist; a bare 405
        // leaves it guessing.
        expect(response.headers['allow'], 'GET, POST, DELETE');
      },
      skip: !sqliteAvailable,
    );

    test('a request outside /mcp is a plain 404', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      final response = await harness.rawRequest('GET', '/not-mcp');

      expect(response.statusCode, HttpStatus.notFound);
      expect(response.body['error'], 'not_found');
    }, skip: !sqliteAvailable);

    test('a non-initialize call without a session id is refused', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      final response = await harness.rawRequest(
        'POST',
        deployDashAgentMcpPath,
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/list',
        }),
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.body['id'], 9);
      expect((response.body['error'] as Map)['code'], -32600);
      expect(
        (response.body['error'] as Map)['message'],
        'Missing MCP session id.',
      );
    }, skip: !sqliteAvailable);

    test(
      'notifications are accepted with 202 and echo the session headers',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();
        // Opens the session the notification will name.
        await harness.mcpMethod('ping');

        final initialized = await harness.mcpMethod(
          'notifications/initialized',
          includeId: false,
        );
        expect(initialized.statusCode, HttpStatus.accepted);
        expect(
          initialized.headers[testMcpSessionIdHeader],
          harness.mcpSessionId,
        );
        expect(initialized.headers['mcp-protocol-version'], isNotNull);

        // Any other id-less call takes the second 202 path, after dispatch.
        final notification = await harness.mcpMethod('ping', includeId: false);
        expect(notification.statusCode, HttpStatus.accepted);
        expect(
          notification.headers[testMcpSessionIdHeader],
          harness.mcpSessionId,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'a body that is not JSON becomes an internal JSON-RPC error',
      () async {
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final response = await harness.rawRequest(
          'POST',
          deployDashAgentMcpPath,
          body: '{not json',
        );

        expect(response.statusCode, HttpStatus.internalServerError);
        expect((response.body['error'] as Map)['code'], -32603);
        expect(response.body['id'], isNull);
      },
      skip: !sqliteAvailable,
    );

    test('an event stream naming an unknown session is refused', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      final response = await harness.rawRequest(
        'GET',
        deployDashAgentMcpPath,
        headers: <String, String>{testMcpSessionIdHeader: 'not-a-session'},
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(response.body['error'], 'invalid_session');
    }, skip: !sqliteAvailable);

    test('deleting an unknown session is refused', () async {
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      final response = await harness.rawRequest(
        'DELETE',
        deployDashAgentMcpPath,
        headers: <String, String>{testMcpSessionIdHeader: 'not-a-session'},
      );

      expect(response.statusCode, HttpStatus.notFound);
      expect(response.body['error'], 'invalid_session');
    }, skip: !sqliteAvailable);
  });

  group('AgentAccessService event stream keepalive', () {
    tearDown(() {
      deployDashAgentEventStreamHeartbeatOverrideForTests = null;
    });

    test(
      'an idle stream is held open by periodic keepalive comments',
      () async {
        deployDashAgentEventStreamHeartbeatOverrideForTests = const Duration(
          milliseconds: 20,
        );
        final harness = await createHarness();
        addTearDown(harness.dispose);
        await harness.seedDefaultData();
        await harness.enableAgentAccess();

        final chunks = await harness.collectMcpEventStream(
          const Duration(milliseconds: 150),
        );
        final transcript = chunks.join();

        expect(transcript, startsWith(': connected\n\n'));
        // Several ticks inside the window: one would not distinguish a working
        // timer from a single delayed write.
        expect(
          ': keepalive\n\n'.allMatches(transcript).length,
          greaterThanOrEqualTo(2),
          reason: 'transcript was: $transcript',
        );
      },
      skip: !sqliteAvailable,
    );

    test('the keepalive timer stops when the client disconnects', () async {
      deployDashAgentEventStreamHeartbeatOverrideForTests = const Duration(
        milliseconds: 20,
      );
      final harness = await createHarness();
      addTearDown(harness.dispose);
      await harness.seedDefaultData();
      await harness.enableAgentAccess();

      await harness.collectMcpEventStream(const Duration(milliseconds: 60));
      // Give the handler's `await response.done` a chance to resolve after the
      // client has gone, which is what runs the cancelling `finally`.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final response = await harness.mcpMethod('ping');
      expect(response.statusCode, HttpStatus.ok);

      // Closing the listener completes the handler's `response.done`, which is
      // what runs the `finally` that cancels the timer. A timer left running
      // past the disconnect would keep writing to a dead response for the life
      // of the process, so the cancellation is the behaviour under test.
      await harness.service.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final afterClose = await harness
          .rawRequest(
            'POST',
            deployDashAgentMcpPath,
            body: jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'ping',
            }),
          )
          .then<Object?>((value) => value)
          .onError<SocketException>((_, _) => null);
      expect(
        afterClose,
        isNull,
        reason: 'the listener is closed, so nothing should still answer',
      );
    }, skip: !sqliteAvailable);
  });
}
