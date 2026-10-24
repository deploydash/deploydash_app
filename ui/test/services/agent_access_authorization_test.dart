import 'package:ui/data/local/agent_audit_repository.dart';
import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_preferences_repository.dart';
import 'package:ui/providers/agent_access/authorization.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_support/sqlite_test_harness.dart';

/// The Agent Access security boundary, exercised without an `HttpServer`.
///
/// **Nothing in this file binds a socket or opens a port.** That is the point
/// of T-3.5.3's split: before it, every one of these decisions could only be
/// reached by standing up the real listener on a real port, so the refusals
/// were tested through the transport rather than against the predicate. The
/// in-memory database below is local state, not a network dependency.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AgentAccessAuthorization origin decisions', () {
    const port = 46337;

    test('accepts loopback addresses on this app port', () {
      for (final origin in <String>[
        'http://127.0.0.1:46337',
        'http://localhost:46337',
        'http://127.0.0.1',
        'http://localhost',
      ]) {
        expect(
          AgentAccessAuthorization.isLocalOrigin(origin, expectedPort: port),
          isTrue,
          reason: '$origin is a legitimate local client',
        );
      }
    });

    test('refuses a host that merely contains a loopback address', () {
      // The DNS-rebinding shape a `contains('127.0.0.1')` check waves through.
      expect(
        AgentAccessAuthorization.isLocalOrigin(
          'https://127.0.0.1.evil.example',
          expectedPort: port,
        ),
        isFalse,
      );
      expect(
        AgentAccessAuthorization.isLocalOrigin(
          'https://localhost.evil.example',
          expectedPort: port,
        ),
        isFalse,
      );
    });

    test('refuses a foreign origin, and one on another port', () {
      expect(
        AgentAccessAuthorization.isLocalOrigin(
          'https://evil.example',
          expectedPort: port,
        ),
        isFalse,
      );
      expect(
        AgentAccessAuthorization.isLocalOrigin(
          'http://127.0.0.1:9999',
          expectedPort: port,
        ),
        isFalse,
      );
    });

    test('refuses a value that is not a usable origin at all', () {
      expect(
        AgentAccessAuthorization.isLocalOrigin('null', expectedPort: port),
        isFalse,
      );
      expect(
        AgentAccessAuthorization.isLocalOrigin('', expectedPort: port),
        isFalse,
      );
      expect(
        AgentAccessAuthorization.isLocalOrigin(
          'not a uri at all',
          expectedPort: port,
        ),
        isFalse,
      );
    });
  });

  group('AgentAccessAuthorization bearer-token decisions', () {
    AppPreferencesRecord preferences({
      String mode = agentAccessPermissionRedeploy,
      String? token,
      DateTime? expiresAt,
    }) {
      return AppPreferencesRecord(
        terminalDebugView: false,
        themeMode: 'system',
        sqliteBackupS3Config: null,
        agentAccessEnabled: true,
        agentAccessPermissionMode: mode,
        agentSessionToken: token,
        agentSessionExpiresAt: expiresAt,
        updatedAt: DateTime(2026, 9, 3),
      );
    }

    final future = DateTime.now().add(const Duration(hours: 1));

    test('refuses every call while the user has not granted redeploy', () {
      final error = AgentAccessAuthorization.errorForBearerToken(
        'Bearer anything',
        preferences(mode: 'read_only', token: 'tok', expiresAt: future),
      );
      expect(error?['error'], 'permission_denied');
      expect(
        error?['message'],
        'Agent Access is not in redeploy-capable mode.',
      );
    });

    test('refuses when redeploy is granted but no session is active', () {
      final error = AgentAccessAuthorization.errorForBearerToken(
        'Bearer anything',
        preferences(),
      );
      expect(error?['error'], 'session_required');
      expect(error?['message'], 'No active redeploy session is available.');
    });

    test('refuses an expired session even with the right token', () {
      final error = AgentAccessAuthorization.errorForBearerToken(
        'Bearer tok',
        preferences(
          token: 'tok',
          expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ),
      );
      expect(error?['error'], 'session_required');
    });

    test('refuses a wrong, absent, or unprefixed token', () {
      for (final header in <String?>[null, '', 'tok', 'Bearer other']) {
        final error = AgentAccessAuthorization.errorForBearerToken(
          header,
          preferences(token: 'tok', expiresAt: future),
        );
        expect(
          error?['error'],
          'invalid_token',
          reason: 'header ${header ?? '<absent>'} must not authorize',
        );
      }
    });

    test('allows the exact active token', () {
      expect(
        AgentAccessAuthorization.errorForBearerToken(
          'Bearer tok',
          preferences(token: 'tok', expiresAt: future),
        ),
        isNull,
      );
    });
  });

  group('AgentAccessAuthorization token generation', () {
    test('produces distinct URL-safe 24-byte tokens', () {
      final tokens = <String>{
        for (var i = 0; i < 64; i += 1)
          AgentAccessAuthorization.generateToken(),
      };
      expect(tokens, hasLength(64), reason: 'tokens must not repeat');
      for (final token in tokens) {
        expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+=*$')));
        expect(token.length, greaterThanOrEqualTo(32));
      }
    });
  });

  group('AgentAccessAuthorization session state', () {
    late AppDatabase database;
    late ProviderContainer container;
    late AgentAccessAuthorization authorization;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      authorization = container.read(agentAccessAuthorizationProvider);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('issues a session that authorizes only in redeploy mode', () async {
      final issued = await authorization.issueSession(
        duration: const Duration(minutes: 30),
      );
      final readOnly = await authorization.readPreferences();

      expect(readOnly.agentSessionToken, issued.token);
      expect(readOnly.hasActiveAgentSession, isTrue);
      // A live session is not a grant. The default mode is read_only, and the
      // token stays inert until the user also grants redeploy -- two
      // independent conditions rather than one.
      expect(
        AgentAccessAuthorization.errorForBearerToken(
          'Bearer ${issued.token}',
          readOnly,
        )?['error'],
        'permission_denied',
      );

      await authorization.setPermissionMode(agentAccessPermissionRedeploy);
      expect(
        AgentAccessAuthorization.errorForBearerToken(
          'Bearer ${issued.token}',
          await authorization.readPreferences(),
        ),
        isNull,
      );
    }, skip: !sqliteAvailable);

    test('refuses to issue a second session while one is active', () async {
      await authorization.issueSession();
      await expectLater(
        authorization.issueSession(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('already active'),
          ),
        ),
      );
    }, skip: !sqliteAvailable);

    test(
      'revoking clears the token so the same header stops working',
      () async {
        await authorization.setPermissionMode(agentAccessPermissionRedeploy);
        final issued = await authorization.issueSession();
        await authorization.revokeSession();
        final stored = await authorization.readPreferences();

        expect(stored.hasActiveAgentSession, isFalse);
        expect(
          AgentAccessAuthorization.errorForBearerToken(
            'Bearer ${issued.token}',
            stored,
          )?['error'],
          'session_required',
        );
      },
      skip: !sqliteAvailable,
    );

    test('leaving redeploy mode drops the session it justified', () async {
      await authorization.setPermissionMode(agentAccessPermissionRedeploy);
      await authorization.issueSession();
      expect(
        (await authorization.readPreferences()).hasActiveAgentSession,
        isTrue,
      );

      final normalized = await authorization.setPermissionMode('read_only');

      expect(normalized, 'read_only');
      expect(
        (await authorization.readPreferences()).hasActiveAgentSession,
        isFalse,
      );
    }, skip: !sqliteAvailable);

    test('an unrecognised permission mode normalizes to read_only', () async {
      final normalized = await authorization.setPermissionMode('anything-else');

      expect(normalized, 'read_only');
      expect(
        (await authorization.readPreferences()).agentAccessPermissionMode,
        'read_only',
      );
    }, skip: !sqliteAvailable);

    test('disabling clears the session as well as the flag', () async {
      await authorization.setPermissionMode(agentAccessPermissionRedeploy);
      await authorization.issueSession();

      await authorization.setEnabled(false);
      final stored = await authorization.readPreferences();

      expect(stored.agentAccessEnabled, isFalse);
      expect(stored.hasActiveAgentSession, isFalse);
    }, skip: !sqliteAvailable);

    test('enabling leaves an active session in place', () async {
      await authorization.setPermissionMode(agentAccessPermissionRedeploy);
      final issued = await authorization.issueSession();

      await authorization.setEnabled(true);
      final stored = await authorization.readPreferences();

      expect(stored.agentAccessEnabled, isTrue);
      expect(stored.agentSessionToken, issued.token);
    }, skip: !sqliteAvailable);

    test('the first launch clears a stale enabled flag exactly once', () async {
      await authorization.setEnabled(true);

      await authorization.clearEnabledOnFirstLaunch();
      expect(
        (await authorization.readPreferences()).agentAccessEnabled,
        isFalse,
      );

      // Second call is a no-op, so a later legitimate enable survives.
      await authorization.setEnabled(true);
      await authorization.clearEnabledOnFirstLaunch();
      expect(
        (await authorization.readPreferences()).agentAccessEnabled,
        isTrue,
      );
    }, skip: !sqliteAvailable);
  });

  group('AgentAccessAuthorization audit trail', () {
    late AppDatabase database;
    late ProviderContainer container;
    late AgentAccessAuthorization authorization;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      authorization = container.read(agentAccessAuthorizationProvider);
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('records entries with their level, status, and details', () async {
      await authorization.record(
        toolName: 'list_servers',
        accessLevel: 'read_only',
        status: 'success',
        summary: 'Listed saved servers for agent access.',
        details: <String, dynamic>{'count': 2},
      );
      await authorization.record(
        toolName: 'redeploy_web_app',
        accessLevel: agentAccessPermissionRedeploy,
        status: 'started',
        summary: 'Started web app redeploy through Deploy Dash.',
      );

      final entries = await authorization.recentEntries();

      // Deliberately not asserted in order: listRecent sorts by createdAt with
      // no tiebreak, so two entries written inside one millisecond come back in
      // an undefined order. Recorded under Discovered work; not fixed here.
      expect(entries, hasLength(2));
      final byTool = <String, AgentAuditEntryRecord>{
        for (final entry in entries) entry.toolName: entry,
      };
      expect(
        byTool['redeploy_web_app']!.accessLevel,
        agentAccessPermissionRedeploy,
      );
      expect(byTool['redeploy_web_app']!.status, 'started');
      expect(byTool['list_servers']!.accessLevel, 'read_only');
      expect(byTool['list_servers']!.details, <String, dynamic>{'count': 2});
    }, skip: !sqliteAvailable);

    test('honours the requested limit', () async {
      for (var index = 0; index < 5; index += 1) {
        await authorization.record(
          toolName: 'tool_$index',
          accessLevel: 'read_only',
          status: 'success',
          summary: 'entry $index',
        );
      }

      expect(await authorization.recentEntries(limit: 2), hasLength(2));
    }, skip: !sqliteAvailable);
  });
}
