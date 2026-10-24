import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local/agent_audit_repository.dart';
import '../../data/local/app_preferences_repository.dart';

/// Every decision about whether an Agent Access request is allowed, plus the
/// session and audit state those decisions read.
///
/// This is the security boundary of the only network listener the desktop app
/// runs. It is a separate library rather than a `part` for one reason: until
/// T-3.5.3 it lived inside `AgentAccessService`, where the only way to reach
/// it from a test was to bind a real `HttpServer` on a real port. A guard that
/// can only be exercised through a socket is a guard whose failure modes are
/// expensive to enumerate, so the cases that matter — a foreign origin, an
/// absent session, a token that does not match — went untested against the
/// predicate itself and were covered only incidentally through the transport.
///
/// The two decisions are `static` and take everything they need as arguments,
/// so they can be called with no Riverpod container and no I/O at all. The
/// session and audit methods need the encrypted local database and take a
/// [Ref]; they still need no socket.
///
/// Nothing here knows about HTTP or MCP. `transport.dart` asks it questions.
class AgentAccessAuthorization {
  /// Creates the boundary reading session state through [ref].
  const AgentAccessAuthorization(this.ref);

  /// Riverpod handle used to reach the encrypted local preference and audit
  /// stores. No provider above `data/local` is read from here.
  final Ref ref;

  /// Loopback hosts an `Origin` header may name.
  ///
  /// `localhost` is accepted even though the server binds `loopbackIPv4`: a
  /// legitimate client may address it either way, and refusing one is a worse
  /// failure than this guard prevents.
  static const Set<String> _localHosts = <String>{
    '127.0.0.1',
    'localhost',
    '::1',
  };

  /// Whether [origin] is this app's own loopback endpoint on [expectedPort].
  ///
  /// Anything else is a browser page, which has no legitimate reason to reach
  /// this endpoint. The MCP specification requires local HTTP transports to
  /// validate `Origin`, because binding loopback does not stop DNS rebinding:
  /// an attacker who points their own domain at 127.0.0.1 is same-origin as
  /// far as the browser is concerned, so CORS never applies.
  ///
  /// The URI is parsed rather than substring-matched. `https://127.0.0.1.evil.example`
  /// contains `127.0.0.1` but its host is the attacker's. T-3.5.5.
  static bool isLocalOrigin(String origin, {required int expectedPort}) {
    final parsed = Uri.tryParse(origin);
    if (parsed == null || !parsed.hasAuthority) {
      return false;
    }
    if (!_localHosts.contains(parsed.host)) {
      return false;
    }
    return !parsed.hasPort || parsed.port == expectedPort;
  }

  /// The error payload rejecting [authorization], or `null` when it may proceed.
  ///
  /// Three distinct refusals rather than one, because an agent that cannot tell
  /// "the user has not granted redeploy" from "your token is wrong" cannot tell
  /// the user what to do about it.
  static Map<String, dynamic>? errorForBearerToken(
    String? authorization,
    AppPreferencesRecord preferences,
  ) {
    if (preferences.agentAccessPermissionMode !=
        agentAccessPermissionRedeploy) {
      return <String, dynamic>{
        'error': 'permission_denied',
        'message': 'Agent Access is not in redeploy-capable mode.',
      };
    }
    if (!preferences.hasActiveAgentSession) {
      return <String, dynamic>{
        'error': 'session_required',
        'message': 'No active redeploy session is available.',
      };
    }
    // Fails closed on an absent token rather than comparing against a blank
    // one: `'Bearer ' + ''` is a string a client could actually send.
    // `hasActiveAgentSession` above already requires a non-blank token, so
    // this cannot fire -- but an empty expected secret must never be the
    // fallback in the one function that decides who gets in.
    final expectedToken = preferences.agentSessionToken?.trim();
    if (expectedToken == null || authorization != 'Bearer $expectedToken') {
      return <String, dynamic>{
        'error': 'invalid_token',
        'message': 'Bearer token does not match the active agent session.',
      };
    }
    return null;
  }

  /// A 192-bit URL-safe random token.
  ///
  /// Used for both the redeploy session token and the MCP session id, so it is
  /// `Random.secure()` rather than the default generator in both cases.
  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  /// Reads the stored Agent Access preferences.
  Future<AppPreferencesRecord> readPreferences() {
    return ref.read(appPreferencesRepositoryProvider).read();
  }

  /// Turns Agent Access on or off, clearing any session when turning it off.
  Future<void> setEnabled(bool enabled) async {
    await ref
        .read(appPreferencesRepositoryProvider)
        .setAgentAccessEnabled(enabled);
    if (!enabled) {
      await ref.read(appPreferencesRepositoryProvider).clearAgentSession();
    }
  }

  /// Stores [mode] normalized, returning the value actually written.
  ///
  /// Leaving redeploy mode drops the active session: a session outliving the
  /// permission that justified it is a token nobody expects to still work.
  Future<String> setPermissionMode(String mode) async {
    final normalized = normalizeAgentAccessPermissionMode(mode);
    await ref
        .read(appPreferencesRepositoryProvider)
        .setAgentAccessPermissionMode(normalized);
    if (normalized != agentAccessPermissionRedeploy) {
      await ref.read(appPreferencesRepositoryProvider).clearAgentSession();
    }
    return normalized;
  }

  /// Clears the stored enabled flag on the first call of the process.
  ///
  /// Agent Access never survives a restart: it binds a localhost endpoint that
  /// can drive redeploys, so enabling it is a per-session decision. The flag is
  /// written, not merely ignored, so no stale `true` remains on disk. See G-37.
  Future<void> clearEnabledOnFirstLaunch() async {
    if (_clearedForThisLaunch) {
      return;
    }
    _clearedForThisLaunch = true;
    await ref
        .read(appPreferencesRepositoryProvider)
        .setAgentAccessEnabled(false);
  }

  static bool _clearedForThisLaunch = false;

  /// Forgets that this process already cleared the flag, for tests only.
  ///
  /// [clearEnabledOnFirstLaunch] is guarded by a process-lifetime static, so
  /// in a test process the *first* service to sync burns it and every later
  /// one skips the write. That is correct in production and wrong in a test
  /// file, where it made the first group in the process the only one whose
  /// listener bound -- so `--plain-name` failed for whichever group ran
  /// first, while a full-file run passed. Found by running a new group
  /// alone. Same shape as `deployDashAgentControlPortOverrideForTests`.
  @visibleForTesting
  static void resetFirstLaunchClearForTests() {
    _clearedForThisLaunch = false;
  }

  /// Issues a redeploy-capable session token valid for [duration].
  ///
  /// Throws [StateError] when one is already active: two live tokens would mean
  /// revoking the one the user can see does not revoke the one they cannot.
  Future<({String token, DateTime expiresAt})> issueSession({
    Duration duration = const Duration(hours: 1),
  }) async {
    final preferences = await readPreferences();
    if (preferences.hasActiveAgentSession) {
      throw StateError(
        'An agent session is already active. Revoke it before issuing a new session.',
      );
    }
    final token = generateToken();
    final expiresAt = DateTime.now().add(duration);
    await ref
        .read(appPreferencesRepositoryProvider)
        .issueAgentSession(token: token, expiresAt: expiresAt);
    return (token: token, expiresAt: expiresAt);
  }

  /// Revokes the active redeploy session, if any.
  Future<void> revokeSession() {
    return ref.read(appPreferencesRepositoryProvider).clearAgentSession();
  }

  /// Appends one entry to the agent audit trail.
  Future<void> record({
    required String toolName,
    required String accessLevel,
    required String status,
    required String summary,
    Map<String, dynamic>? details,
  }) {
    return ref
        .read(agentAuditRepositoryProvider)
        .append(
          toolName: toolName,
          accessLevel: accessLevel,
          status: status,
          summary: summary,
          details: details,
        );
  }

  /// Reads the most recent [limit] audit entries, newest first.
  Future<List<AgentAuditEntryRecord>> recentEntries({int limit = 20}) {
    return ref.read(agentAuditRepositoryProvider).listRecent(limit: limit);
  }
}

/// The Agent Access security boundary for the current provider scope.
final agentAccessAuthorizationProvider = Provider<AgentAccessAuthorization>(
  (ref) => AgentAccessAuthorization(ref),
);
