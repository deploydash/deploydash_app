import 'package:ui/data/local/app_database.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  // The runtime is still required: the remaining tests open an in-memory
  // database through the generated code, even though the legacy-seeding
  // helpers went with the migration tests in T-1.2.4.
  ensureSqliteRuntimeAvailable();

  group('AppDatabase agent access schema', () {
    test('generated AppPreference methods preserve agent access fields', () {
      final row = AppPreferenceRow(
        id: 1,
        terminalDebugView: true,
        themeMode: 'dark',
        gitHubPendingOauthState: 'oauth-123',
        sqliteBackupS3ConfigJson: '{"bucket":"backups"}',
        sqliteBackupLastRunAt: DateTime.utc(2026, 3, 20, 12),
        sqliteBackupLastStatus: 'success',
        sqliteBackupLastMessage: 'Done',
        agentAccessEnabled: true,
        agentAccessPermissionMode: 'redeploy',
        agentSessionToken: 'session-token',
        agentSessionExpiresAt: DateTime.utc(2026, 3, 20, 13),
        updatedAt: DateTime.utc(2026, 3, 20, 12, 1),
      );

      expect(row.toColumns(true), contains('agent_access_enabled'));
      expect(row.toColumns(true), contains('agent_access_permission_mode'));
      expect(row.toColumns(true), contains('agent_session_token'));
      expect(row.toColumns(true), contains('agent_session_expires_at'));
      expect(row.toCompanion(true).agentAccessEnabled.value, isTrue);
      expect(row.toCompanion(true).agentAccessPermissionMode.value, 'redeploy');
      expect(row.toCompanion(true).agentSessionToken.value, 'session-token');

      final fromJson = AppPreferenceRow.fromJson(row.toJson());
      expect(fromJson.agentAccessEnabled, isTrue);
      expect(fromJson.agentAccessPermissionMode, 'redeploy');
      expect(fromJson.agentSessionToken, 'session-token');

      final copy = row.copyWith(
        agentAccessEnabled: false,
        agentAccessPermissionMode: 'read_only',
        agentSessionToken: const Value('next-token'),
        agentSessionExpiresAt: Value(DateTime.utc(2026, 3, 20, 14)),
      );
      expect(copy.agentAccessEnabled, isFalse);
      expect(copy.agentAccessPermissionMode, 'read_only');
      expect(copy.agentSessionToken, 'next-token');

      final copyWithCompanion = row.copyWithCompanion(
        const AppPreferencesCompanion(
          agentAccessEnabled: Value(false),
          agentAccessPermissionMode: Value('read_only'),
          agentSessionToken: Value('final-token'),
        ),
      );
      expect(copyWithCompanion.agentAccessEnabled, isFalse);
      expect(copyWithCompanion.agentAccessPermissionMode, 'read_only');
      expect(copyWithCompanion.agentSessionToken, 'final-token');

      final custom = AppPreferencesCompanion.custom(
        agentAccessEnabled: const Variable<bool>(true),
        agentAccessPermissionMode: const Variable<String>('redeploy'),
        agentSessionToken: const Variable<String>('custom-token'),
      );
      expect(custom.toColumns(false), contains('agent_access_enabled'));
      expect(custom.toColumns(false), contains('agent_access_permission_mode'));
      expect(custom.toColumns(false), contains('agent_session_token'));
      expect(row.toString(), contains('agentAccessPermissionMode: redeploy'));
    });

    test('table getters expose agent access and deploy routing columns', () {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      expect(
        database.appPreferences.gitHubPendingOauthState.$name,
        'git_hub_pending_oauth_state',
      );
      expect(
        database.appPreferences.agentAccessEnabled.$name,
        'agent_access_enabled',
      );
      expect(
        database.appPreferences.agentAccessPermissionMode.$name,
        'agent_access_permission_mode',
      );
      expect(
        database.appPreferences.agentSessionToken.$name,
        'agent_session_token',
      );
      expect(
        database.appPreferences.agentSessionExpiresAt.$name,
        'agent_session_expires_at',
      );
      expect(database.projects.domainRoutingMode.$name, 'domain_routing_mode');
      expect(database.projects.railpackProvider.$name, 'railpack_provider');
      expect(database.agentAuditEntries.id.$name, 'id');
      expect(database.agentAuditEntries.toolName.$name, 'tool_name');
      expect(database.agentAuditEntries.accessLevel.$name, 'access_level');
      expect(database.agentAuditEntries.status.$name, 'status');
      expect(database.agentAuditEntries.summary.$name, 'summary');
      expect(database.agentAuditEntries.detailsJson.$name, 'details_json');
      expect(database.agentAuditEntries.createdAt.$name, 'created_at');
    });

    test('table managers expose agent access and audit composers', () {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final managers = database.managers;

      expect(
        managers.appPreferences.filter(
          (f) => f.agentAccessPermissionMode.equals('redeploy'),
        ),
        isNotNull,
      );
      expect(
        managers.appPreferences.orderBy((o) => o.agentSessionExpiresAt.desc()),
        isNotNull,
      );
      expect(
        managers.appPreferences.computedField((a) => a.agentSessionToken),
        isNotNull,
      );

      expect(
        managers.agentAuditEntries.filter((f) => f.toolName.equals('tool')),
        isNotNull,
      );
      expect(
        managers.agentAuditEntries.orderBy((o) => o.createdAt.desc()),
        isNotNull,
      );
      expect(
        managers.agentAuditEntries.computedField((a) => a.summary),
        isNotNull,
      );
    });
  });
}
