import 'package:flutter_test/flutter_test.dart';

import '_support/app_database_harness.dart';

/// generated drift models.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  group('generated drift models', () {
    test('AppPreference generated methods preserve pending OAuth state', () {
      final row = AppPreferenceRow(
        id: 1,
        terminalDebugView: true,
        themeMode: 'dark',
        gitHubPendingOauthState: 'oauth-123',
        sqliteBackupS3ConfigJson: '{"bucket":"backups"}',
        sqliteBackupLastRunAt: DateTime.utc(2026, 3, 20, 12),
        sqliteBackupLastStatus: 'success',
        sqliteBackupLastMessage: 'Done',
        agentAccessEnabled: false,
        agentAccessPermissionMode: 'read_only',
        agentSessionToken: null,
        agentSessionExpiresAt: null,
        updatedAt: DateTime.utc(2026, 3, 20, 12, 1),
      );

      expect(row.toColumns(true), contains('git_hub_pending_oauth_state'));
      expect(row.toCompanion(true).gitHubPendingOauthState.value, 'oauth-123');

      final fromJson = AppPreferenceRow.fromJson(row.toJson());
      expect(fromJson.gitHubPendingOauthState, 'oauth-123');

      final copy = row.copyWith(
        gitHubPendingOauthState: const Value('oauth-456'),
      );
      expect(copy.gitHubPendingOauthState, 'oauth-456');
      expect(row.copyWith().gitHubPendingOauthState, 'oauth-123');

      final copyWithCompanion = row.copyWithCompanion(
        const AppPreferencesCompanion(
          gitHubPendingOauthState: Value('oauth-789'),
        ),
      );
      expect(copyWithCompanion.gitHubPendingOauthState, 'oauth-789');
      expect(
        row
            .copyWithCompanion(const AppPreferencesCompanion())
            .gitHubPendingOauthState,
        'oauth-123',
      );

      final custom = AppPreferencesCompanion.custom(
        gitHubPendingOauthState: const Variable<String>('oauth-custom'),
      );
      expect(custom.toColumns(false), contains('git_hub_pending_oauth_state'));
      final companionCopy = AppPreferencesCompanion(
        gitHubPendingOauthState: const Value('oauth-123'),
      ).copyWith(gitHubPendingOauthState: const Value('oauth-copy'));
      expect(companionCopy.gitHubPendingOauthState.value, 'oauth-copy');
      expect(
        AppPreferencesCompanion(
          gitHubPendingOauthState: const Value('oauth-123'),
        ).copyWith().gitHubPendingOauthState.value,
        'oauth-123',
      );

      expect(row.toString(), contains('gitHubPendingOauthState: oauth-123'));
      expect(row.hashCode, isNonZero);
      expect(row == row.copyWith(), isTrue);
      expect(
        AppPreferencesCompanion(
          gitHubPendingOauthState: const Value('oauth-123'),
        ).toString(),
        contains('gitHubPendingOauthState'),
      );
    });

    test('AppPreference generated methods preserve agent access fields', () {
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

    test(
      'generated table managers expose agent access and audit composers',
      () {
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
          managers.appPreferences.orderBy(
            (o) => o.agentSessionExpiresAt.desc(),
          ),
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
        expect(
          managers.operationRecoveryStates.filter(
            (f) => f.snapshotsJson.equals('[]'),
          ),
          isNotNull,
        );
        expect(
          managers.operationRecoveryStates.orderBy((o) => o.updatedAt.desc()),
          isNotNull,
        );
      },
    );

    test('Project generated methods preserve routing mode and provider', () {
      final row = ProjectRow(
        id: 'project-1',
        name: 'Docs',
        type: 'Web app',
        gitUrl: 'https://github.com/example/docs.git',
        primaryDomain: 'docs.example.com',
        domainRoutingMode: 'redirect_apex_to_www',
        repositoryFullName: 'example/docs',
        appSubdirectory: 'apps/web',
        deployBranch: 'main',
        appPort: 3000,
        publicHealthCheckEnabled: true,
        publicHealthCheckPath: '/',
        lastDeployCommit: 'abcdef',
        lastDeployedAt: DateTime.utc(2026, 3, 20, 13),
        railpackBuildCommand: 'npm run build',
        railpackRunCommand: 'npm run start',
        railpackProvider: 'python',
        railpackNodeMode: 'auto',
        tlsChallengeMode: 'dns',
        tlsDnsProvider: 'cloudflare',
        tlsDnsConfigJson: '{"api_token":"token"}',
        appDisconnected: true,
        injectPostgresEnv: false,
        sqliteStorageEnabled: false,
        sqliteVolumeName: null,
        sqliteMountPath: null,
        sqliteFileName: null,
        isActive: true,
        createdAt: DateTime.utc(2026, 3, 20, 12),
        updatedAt: DateTime.utc(2026, 3, 20, 13),
      );

      expect(row.toColumns(true), contains('domain_routing_mode'));
      expect(row.toColumns(true), contains('railpack_provider'));

      final companion = row.toCompanion(true);
      expect(companion.domainRoutingMode.value, 'redirect_apex_to_www');
      expect(companion.railpackProvider.value, 'python');

      final fromJson = ProjectRow.fromJson(row.toJson());
      expect(fromJson.domainRoutingMode, 'redirect_apex_to_www');
      expect(fromJson.railpackProvider, 'python');

      final copy = row.copyWith(
        domainRoutingMode: 'redirect_www_to_apex',
        railpackProvider: const Value('php'),
      );
      expect(copy.domainRoutingMode, 'redirect_www_to_apex');
      expect(copy.railpackProvider, 'php');

      final copyWithCompanion = row.copyWithCompanion(
        const ProjectsCompanion(
          domainRoutingMode: Value('single_host'),
          railpackProvider: Value('ruby'),
        ),
      );
      expect(copyWithCompanion.domainRoutingMode, 'single_host');
      expect(copyWithCompanion.railpackProvider, 'ruby');
      final preservedCopy = row.copyWithCompanion(const ProjectsCompanion());
      expect(preservedCopy.domainRoutingMode, 'redirect_apex_to_www');
      expect(preservedCopy.railpackProvider, 'python');

      final custom = ProjectsCompanion.custom(
        domainRoutingMode: const Variable<String>('redirect_www_to_apex'),
        railpackProvider: const Variable<String>('dotnet'),
      );
      expect(custom.toColumns(false), contains('domain_routing_mode'));
      expect(custom.toColumns(false), contains('railpack_provider'));

      final companionCopy =
          ProjectsCompanion(
            domainRoutingMode: const Value('redirect_apex_to_www'),
            railpackProvider: const Value('python'),
          ).copyWith(
            domainRoutingMode: const Value('single_host'),
            railpackProvider: const Value('go'),
          );
      expect(companionCopy.domainRoutingMode.value, 'single_host');
      expect(companionCopy.railpackProvider.value, 'go');
      final preservedCompanionCopy = ProjectsCompanion(
        domainRoutingMode: const Value('redirect_apex_to_www'),
        railpackProvider: const Value('python'),
      ).copyWith();
      expect(
        preservedCompanionCopy.domainRoutingMode.value,
        'redirect_apex_to_www',
      );
      expect(preservedCompanionCopy.railpackProvider.value, 'python');

      final insertable = ProjectsCompanion.custom(
        domainRoutingMode: const Variable<String>('single_host'),
        railpackProvider: const Variable<String>('rust'),
      );
      expect(insertable.toColumns(false), contains('domain_routing_mode'));
      expect(insertable.toColumns(false), contains('railpack_provider'));

      final createCompanion =
          ProjectsCompanion.insert(
            id: 'project-2',
            name: 'API',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'api.example.com',
          ).copyWith(
            domainRoutingMode: const Value('redirect_www_to_apex'),
            railpackProvider: const Value('elixir'),
          );
      expect(createCompanion.domainRoutingMode.value, 'redirect_www_to_apex');
      expect(createCompanion.railpackProvider.value, 'elixir');

      expect(
        row.toString(),
        contains('domainRoutingMode: redirect_apex_to_www'),
      );
      expect(row.toString(), contains('railpackProvider: python'));
      expect(row.hashCode, isNonZero);
      expect(row == row.copyWith(), isTrue);
      expect(
        ProjectsCompanion(
          domainRoutingMode: const Value('redirect_apex_to_www'),
          railpackProvider: const Value('python'),
        ).toString(),
        allOf(contains('domainRoutingMode'), contains('railpackProvider')),
      );
    });

    test('generated table managers expose changed field composers', () {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final managers = database.managers;

      expect(
        managers.appPreferences.filter(
          (f) => f.gitHubPendingOauthState.equals('oauth-123'),
        ),
        isNotNull,
      );
      expect(
        managers.appPreferences.orderBy((o) => o.gitHubPendingOauthState.asc()),
        isNotNull,
      );
      expect(
        managers.appPreferences.computedField((a) => a.gitHubPendingOauthState),
        isNotNull,
      );

      expect(
        managers.projects.filter(
          (f) => f.domainRoutingMode.equals('single_host'),
        ),
        isNotNull,
      );
      expect(
        managers.projects.orderBy((o) => o.domainRoutingMode.asc()),
        isNotNull,
      );
      expect(
        managers.projects.computedField((a) => a.domainRoutingMode),
        isNotNull,
      );
      expect(
        managers.projects.filter((f) => f.railpackProvider.equals('python')),
        isNotNull,
      );
      expect(
        managers.projects.orderBy((o) => o.railpackProvider.asc()),
        isNotNull,
      );
      expect(
        managers.projects.computedField((a) => a.railpackProvider),
        isNotNull,
      );
    });
  });
}
