import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../../integration_test/support/relay_client.dart';

/// Scripted fake of the OAuth relay the E2E GitHub login uses.
///
/// Implements the same contract as the throwaway relay: POST /auth-url
/// stores (200), GET /auth-url-status reports pending/consumed without
/// consuming, GET /auth-url destructively reads, GET /callback returns the
/// stored callback once posted.
class _FakeRelay {
  final HttpServer _server;
  String? authUrl;
  bool consumed = false;
  String? callback;
  bool failPublish = false;

  _FakeRelay(this._server);

  static Future<_FakeRelay> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = _FakeRelay(server);
    server.listen(relay._handle);
    return relay;
  }

  Uri get callbackBase =>
      Uri.parse('http://127.0.0.1:${_server.port}/callback');

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (request.method == 'POST' && path == '/auth-url') {
      await request.drain<void>();
      if (failPublish) {
        request.response.statusCode = 500;
      } else {
        authUrl = 'posted';
        request.response.statusCode = 200;
      }
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/auth-url-status') {
      request.response
        ..statusCode = 200
        ..write(consumed ? 'consumed' : 'pending');
      await request.response.close();
      return;
    }
    if (request.method == 'POST' && path == '/callback') {
      final body = await utf8.decoder.bind(request).join();
      callback = (jsonDecode(body) as Map<String, dynamic>)['url'] as String?;
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }
    if (request.method == 'GET' && path == '/callback') {
      if (callback == null) {
        request.response.statusCode = 404;
      } else {
        request.response
          ..statusCode = 200
          ..write(callback);
      }
      await request.response.close();
      return;
    }
    request.response.statusCode = 404;
    await request.response.close();
  }
}

const _authUrl =
    'https://github.com/login/oauth/authorize?client_id=x&state=abc123';

void main() {
  test(
    'dead operator fails fast instead of waiting out the callback window',
    () async {
      final relay = await _FakeRelay.bind();
      try {
        final stopwatch = Stopwatch()..start();
        await expectLater(
          waitForRelayCallback(
            relayBase: relay.callbackBase,
            authUrl: _authUrl,
            pickupTimeout: const Duration(seconds: 2),
            callbackTimeout: const Duration(seconds: 30),
          ),
          throwsA(
            isA<TestFailure>().having(
              (failure) => failure.message,
              'message',
              contains('did not pick up'),
            ),
          ),
        );
        stopwatch.stop();
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 20)));
      } finally {
        await relay.close();
      }
    },
  );

  test('live operator pickup then callback returns the callback URL', () async {
    final relay = await _FakeRelay.bind();
    try {
      // Operator consumes the URL shortly after publish, then completes the
      // login and posts the callback for this run's state.
      unawaited(
        Future<void>(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          relay.consumed = true;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          final poster = await HttpClient().postUrl(relay.callbackBase);
          poster.headers.contentType = ContentType.json;
          const body = '{"url": "deploydash://callback?code=q&state=abc123"}';
          poster.contentLength = body.length;
          poster.write(body);
          await poster.close().then((response) => response.drain<void>());
        }),
      );
      final callback = await waitForRelayCallback(
        relayBase: relay.callbackBase,
        authUrl: _authUrl,
        pickupTimeout: const Duration(seconds: 5),
        callbackTimeout: const Duration(seconds: 10),
      );
      expect(callback, 'deploydash://callback?code=q&state=abc123');
    } finally {
      await relay.close();
    }
  });

  test('stale callback from another run is not accepted', () async {
    final relay = await _FakeRelay.bind();
    try {
      relay.callback = 'deploydash://callback?code=old&state=zzz999';
      relay.consumed = true;
      await expectLater(
        waitForRelayCallback(
          relayBase: relay.callbackBase,
          authUrl: _authUrl,
          pickupTimeout: const Duration(seconds: 2),
          callbackTimeout: const Duration(seconds: 3),
        ),
        throwsA(isA<TestFailure>()),
      );
    } finally {
      await relay.close();
    }
  });

  test('refused publish fails immediately', () async {
    final relay = await _FakeRelay.bind();
    try {
      relay.failPublish = true;
      await expectLater(
        waitForRelayCallback(relayBase: relay.callbackBase, authUrl: _authUrl),
        throwsA(
          isA<TestFailure>().having(
            (failure) => failure.message,
            'message',
            contains('refused the authorization URL'),
          ),
        ),
      );
    } finally {
      await relay.close();
    }
  });
}
