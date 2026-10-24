part of '../agent_access_service.dart';

/// The HTTP edge: the listener, request routing, and response writing.
///
/// Split out by T-3.5.3. It knows how to move bytes and how to ask
/// `authorization.dart` whether a request may proceed; the answers themselves
/// come from the tool handlers and the framing from `protocol.dart`.
/// Overrides the event-stream keepalive interval, for tests only.
///
/// The shipped interval is 15 seconds, which no test can wait for. The same
/// shape as `deployDashAgentControlPortOverrideForTests`: a nullable override
/// beside the value it replaces, so the production default stays a plain
/// constant and the test does not reach inside the handler.
@visibleForTesting
Duration? deployDashAgentEventStreamHeartbeatOverrideForTests;

/// How often an open event stream emits a keepalive comment.
Duration get _eventStreamHeartbeatInterval =>
    deployDashAgentEventStreamHeartbeatOverrideForTests ??
    const Duration(seconds: 15);

/// Overrides how long an idle MCP session survives, for tests only.
@visibleForTesting
Duration? deployDashAgentMcpSessionIdleTimeoutOverrideForTests;

/// How long an MCP session survives without being used.
///
/// Every refusal in this file already says "Invalid or **expired** MCP session
/// id", and until this existed nothing ever expired one: `lastSeenAt` was
/// written by [McpSessionState.touch] and read by nobody, and `_mcpSessions`
/// grew by one entry per `initialize` for as long as the app ran. An hour is
/// the same window the redeploy session token uses, and re-initializing is
/// the documented response a client already has to handle for this exact
/// error.
Duration get _mcpSessionIdleTimeout =>
    deployDashAgentMcpSessionIdleTimeoutOverrideForTests ??
    const Duration(hours: 1);

extension _AgentAccessTransport on AgentAccessService {
  /// Drops every session idle for longer than [_mcpSessionIdleTimeout].
  ///
  /// Called before a session id is looked up, so an expired one is absent by
  /// the time the lookup runs and takes the existing "invalid or expired"
  /// path rather than needing a second branch beside it.
  void _pruneExpiredMcpSessions() {
    if (_mcpSessions.isEmpty) {
      return;
    }
    final cutoff = DateTime.now().toUtc().subtract(_mcpSessionIdleTimeout);
    _mcpSessions.removeWhere(
      (_, session) => !session.lastSeenAt.isAfter(cutoff),
    );
  }

  Future<void> _serveRequests(HttpServer server) async {
    await for (final request in server) {
      unawaited(_handleRequest(request));
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length != 1 || segments[0] != 'mcp') {
        await _writeJson(
          request.response,
          HttpStatus.notFound,
          <String, dynamic>{'error': 'not_found'},
        );
        return;
      }
      // The MCP specification requires local HTTP transports to validate
      // Origin. Binding loopback does not stop DNS rebinding: an attacker who
      // points their own domain at 127.0.0.1 is same-origin as far as the
      // browser is concerned, so CORS never applies. A real MCP client sends
      // no Origin at all, so absent is allowed and only a foreign value is
      // refused.
      //
      // This runs before the enabled check on purpose: answering
      // `agent_access_disabled` to a foreign origin would tell it whether the
      // feature is on. T-3.5.5.
      final origin = request.headers.value('origin')?.trim();
      if (origin != null &&
          origin.isNotEmpty &&
          !AgentAccessAuthorization.isLocalOrigin(
            origin,
            expectedPort: resolvedDeployDashAgentControlPort,
          )) {
        await _writeJson(
          request.response,
          HttpStatus.forbidden,
          <String, dynamic>{
            'error': 'forbidden_origin',
            'message': 'Agent Access refuses cross-origin requests.',
          },
        );
        return;
      }
      final preferences = await ref
          .read(appPreferencesRepositoryProvider)
          .read();
      if (!preferences.agentAccessEnabled) {
        await _writeJson(
          request.response,
          HttpStatus.serviceUnavailable,
          <String, dynamic>{
            'error': 'agent_access_disabled',
            'message': 'Agent Access is disabled in the desktop app.',
          },
        );
        return;
      }

      if (request.method == 'GET') {
        await _handleMcpEventStream(request);
        return;
      }
      if (request.method == 'DELETE') {
        await _handleMcpDelete(request);
        return;
      }
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(
          HttpHeaders.allowHeader,
          'GET, POST, DELETE',
        );
        request.response.write(
          jsonEncode(<String, dynamic>{'error': 'method_not_allowed'}),
        );
        await request.response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final parsed = parseJsonRpcRequest(body);
      if (parsed case final AgentAccessReply errorReply) {
        await _writeJson(
          request.response,
          errorReply.statusCode,
          errorReply.body,
        );
        return;
      }
      final message = parsed as Map<String, dynamic>;
      final method = message['method']?.toString().trim() ?? '';
      final id = message.containsKey('id') ? message['id'] : null;
      final hasId = message.containsKey('id');
      final authorization = request.headers
          .value(HttpHeaders.authorizationHeader)
          ?.trim();

      McpSessionState? session;
      if (method == 'initialize') {
        session = _initializeMcpSession(message);
      } else {
        _pruneExpiredMcpSessions();
        final sessionId = request.headers.value(mcpSessionIdHeader)?.trim();
        if (sessionId == null || sessionId.isEmpty) {
          await _writeJsonRpcError(
            request.response,
            id: id,
            code: -32600,
            message: 'Missing MCP session id.',
            statusCode: HttpStatus.badRequest,
          );
          return;
        }
        final existing = _mcpSessions[sessionId];
        if (existing == null) {
          await _writeJsonRpcError(
            request.response,
            id: id,
            code: -32600,
            message: 'Invalid or expired MCP session id.',
            statusCode: HttpStatus.notFound,
          );
          return;
        }
        session = existing.touch();
        _mcpSessions[sessionId] = session;
      }

      if (method == 'notifications/initialized' && !hasId) {
        request.response.statusCode = HttpStatus.accepted;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(mcpSessionIdHeader, session.id);
        request.response.headers.set(
          mcpProtocolVersionHeader,
          session.protocolVersion,
        );
        await request.response.close();
        return;
      }

      final result = await _dispatchMcpMethod(
        method: method,
        params: mcpMapOrNull(message['params']) ?? const <String, dynamic>{},
        id: id,
        hasId: hasId,
        preferences: preferences,
        authorization: authorization,
        session: session,
      );
      if (result case final AgentAccessReply errorReply) {
        await _writeJson(
          request.response,
          errorReply.statusCode,
          errorReply.body,
        );
        return;
      }
      final response = result as Map<String, dynamic>?;
      if (!hasId) {
        request.response.statusCode = HttpStatus.accepted;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(mcpSessionIdHeader, session.id);
        request.response.headers.set(
          mcpProtocolVersionHeader,
          session.protocolVersion,
        );
        await request.response.close();
        return;
      }
      await _writeJsonRpcResult(
        request.response,
        id: id,
        result: response ?? const <String, dynamic>{},
        session: session,
      );
    } catch (error, stackTrace) {
      // A fixed sentence on the wire. `error.toString()` used to go straight
      // out to whatever holds the socket, and what an exception stringifies
      // to is not a contract: file paths, SQL fragments, and connection
      // details from a wrapped engine failure all reach it. The stack still
      // goes to stderr, which is where local debugging reads it from.
      stderr.writeln('Agent Access request failed: $error\n$stackTrace');
      try {
        await _writeJsonRpcError(
          request.response,
          id: null,
          code: -32603,
          message: 'Agent Access could not complete the request.',
          statusCode: HttpStatus.internalServerError,
        );
      } on StateError {
        // The response was already closed -- an aborted event stream reaches
        // here. Writing to it throws a second time, and this method is called
        // through `unawaited`, so that would surface as an unhandled async
        // error and take down the zone rather than one request.
      }
    }
  }

  Future<void> _handleMcpEventStream(HttpRequest request) async {
    _pruneExpiredMcpSessions();
    final sessionId = request.headers.value(mcpSessionIdHeader)?.trim();
    McpSessionState? session;
    if (sessionId != null && sessionId.isNotEmpty) {
      final existing = _mcpSessions[sessionId];
      if (existing == null) {
        await _writeJson(
          request.response,
          HttpStatus.notFound,
          <String, dynamic>{
            'error': 'invalid_session',
            'message': 'Invalid or expired MCP session id.',
          },
        );
        return;
      }
      session = existing.touch();
      _mcpSessions[sessionId] = session;
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    request.response.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
    request.response.headers.set('X-Accel-Buffering', 'no');
    request.response.bufferOutput = false;
    if (session != null) {
      request.response.headers.set(mcpSessionIdHeader, session.id);
      request.response.headers.set(
        mcpProtocolVersionHeader,
        session.protocolVersion,
      );
    }
    request.response.write(': connected\n\n');
    await request.response.flush();

    final heartbeat = Timer.periodic(_eventStreamHeartbeatInterval, (timer) {
      try {
        request.response.write(': keepalive\n\n');
      } on StateError {
        // The client closed the stream, so the sink is no longer writable.
        timer.cancel();
        return;
      }
      // A dropped connection surfaces here and only here: `write` buffers, so
      // it never throws `SocketException` synchronously, and `flush` reports
      // asynchronously. This future used to be discarded, which turned a
      // client disappearing into an unhandled async error and left the timer
      // running against a dead socket.
      unawaited(
        request.response.flush().catchError((Object _) {
          timer.cancel();
        }),
      );
    });
    try {
      await request.response.done;
    } on SocketException {
      // An aborted stream. Nothing to report: the client is gone, and this
      // method's caller would try to answer on the same dead response.
    } finally {
      heartbeat.cancel();
    }
  }

  Future<void> _handleMcpDelete(HttpRequest request) async {
    _pruneExpiredMcpSessions();
    final sessionId = request.headers.value(mcpSessionIdHeader)?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      await _writeJson(
        request.response,
        HttpStatus.badRequest,
        <String, dynamic>{
          'error': 'missing_session',
          'message': 'MCP session id is required.',
        },
      );
      return;
    }
    final existing = _mcpSessions.remove(sessionId);
    if (existing == null) {
      await _writeJson(request.response, HttpStatus.notFound, <String, dynamic>{
        'error': 'invalid_session',
        'message': 'Invalid or expired MCP session id.',
      });
      return;
    }
    request.response.statusCode = HttpStatus.noContent;
    request.response.headers.set(
      mcpProtocolVersionHeader,
      existing.protocolVersion,
    );
    await request.response.close();
  }

  Future<void> _writeJsonRpcResult(
    HttpResponse? response, {
    required Object? id,
    required Map<String, dynamic> result,
    required McpSessionState session,
  }) async {
    if (response == null) {
      return;
    }
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.headers.set(mcpSessionIdHeader, session.id);
    response.headers.set(mcpProtocolVersionHeader, session.protocolVersion);
    response.write(jsonEncode(jsonRpcResultEnvelope(id: id, result: result)));
    await response.close();
  }

  Future<void> _writeJsonRpcError(
    HttpResponse? response, {
    required Object? id,
    required int code,
    required String message,
    int statusCode = HttpStatus.badRequest,
  }) async {
    if (response == null) {
      return;
    }
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode(jsonRpcErrorEnvelope(id: id, code: code, message: message)),
    );
    await response.close();
  }

  Future<void> _writeJson(
    HttpResponse response,
    int statusCode,
    Map<String, dynamic> payload,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(payload));
    await response.close();
  }
}
