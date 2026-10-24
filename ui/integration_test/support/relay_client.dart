import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Completes the operator side of the relay GitHub login.
///
/// Two phases, because the two waits mean different things:
/// 1. Pickup (default 10s): the operator must consume the published
///    authorization URL, proving a watcher is actually listening. A dead
///    operator used to burn the whole callback window in silence; now it
///    fails fast with an actionable message. Detection uses the
///    non-destructive GET /auth-url-status endpoint -- polling GET /auth-url
///    itself would steal the URL from the operator.
/// 2. Callback (default 3min): the login itself takes about a minute
///    (GitHub round trips plus approval), so this window stays generous.
///    Only a callback minted for this run's OAuth state is accepted; a stale
///    relay handing back a previous run's callback is ignored until timeout.
///
/// Returns the `deploydash://callback?` URL or fails.
Future<String> waitForRelayCallback({
  required Uri relayBase,
  required String authUrl,
  Duration pickupTimeout = const Duration(seconds: 10),
  Duration callbackTimeout = const Duration(minutes: 3),
}) async {
  final expectedState = Uri.parse(authUrl).queryParameters['state']?.trim();
  final client = HttpClient();
  try {
    // Publish the authorization URL for the operator flow before polling
    // for the callback: without this post the operator cannot know a login
    // is waiting, and both sides would idle until timeout.
    final publish = await client.postUrl(relayBase.replace(path: '/auth-url'));
    publish.headers.contentType = ContentType.json;
    final publishBody = utf8.encode(
      jsonEncode(<String, String>{'url': authUrl}),
    );
    // Explicit length: without it the request may go out chunked, which the
    // throwaway relay cannot parse, surfacing as a bare HTTP 400.
    publish.contentLength = publishBody.length;
    publish.add(publishBody);
    final publishResponse = await publish.close();
    await publishResponse.drain<void>();
    if (publishResponse.statusCode != 200) {
      fail(
        'GitHub auth relay refused the authorization URL '
        '(HTTP ${publishResponse.statusCode}).',
      );
    }
    final pickupDeadline = DateTime.now().add(pickupTimeout);
    while (DateTime.now().isBefore(pickupDeadline)) {
      final request = await client.getUrl(
        relayBase.replace(path: '/auth-url-status'),
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200 && body.trim() == 'consumed') {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (DateTime.now().isAfter(pickupDeadline)) {
      fail(
        'The operator did not pick up the GitHub authorization URL within '
        '${pickupTimeout.inSeconds}s -- is the OAuth watcher running '
        'against this relay?',
      );
    }
    final callbackDeadline = DateTime.now().add(callbackTimeout);
    while (DateTime.now().isBefore(callbackDeadline)) {
      final request = await client.getUrl(relayBase);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      final callbackUrl = body.trim();
      if (response.statusCode == 200 &&
          callbackUrl.startsWith('deploydash://callback?')) {
        // A stale relay can hand back a previous run's callback; only accept
        // the one minted for this run's OAuth state.
        final callbackState = Uri.parse(
          callbackUrl,
        ).queryParameters['state']?.trim();
        if (expectedState == null ||
            expectedState.isEmpty ||
            callbackState == expectedState) {
          return callbackUrl;
        }
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  } finally {
    client.close(force: true);
  }
  fail('Timed out waiting for the GitHub callback relay.');
}
