import 'package:flutter_test/flutter_test.dart';

import '_support/app_database_harness.dart';

/// AppDatabase.
///
/// One of six files T-3.6.2 split `app_database_test.dart` into, one per
/// group. Fixtures live in `_support/app_database_harness.dart`.
void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AppDatabase', () {
    late AppDatabase database;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('schema version is current', () {
      // This is deliberately a literal rather than a reference to the
      // constant: reading the constant would make the test agree with
      // whatever the code says, which is exactly the check it is supposed to
      // be performing.
      expect(database.schemaVersion, 2);
      expect(database.migration, isNotNull);
    }, skip: !sqliteAvailable);

    test('onCreate seeds singleton onboarding and preferences rows', () async {
      final onboardingRow =
          await (database.select(database.onboardingStateEntries)
                ..where((table) => table.id.equals(1))
                ..limit(1))
              .getSingleOrNull();
      final preferencesRow =
          await (database.select(database.appPreferences)
                ..where((table) => table.id.equals(1))
                ..limit(1))
              .getSingleOrNull();

      expect(onboardingRow, isNotNull);
      expect(preferencesRow, isNotNull);
      expect(onboardingRow!.isCompleted, isFalse);
      expect(preferencesRow!.terminalDebugView, isFalse);
      expect(preferencesRow.themeMode, 'system');
      expect(preferencesRow.sqliteBackupS3ConfigJson, isNull);
      expect(preferencesRow.agentAccessEnabled, isFalse);
      expect(preferencesRow.agentAccessPermissionMode, 'read_only');
    }, skip: !sqliteAvailable);

    test('table column getters are available for all schema tables', () {
      touchAllColumnGetters(database);
    }, skip: !sqliteAvailable);

    test('v1 to v2 migration backfills setup_complete as complete', () async {
      final file = File(
        '${Directory.systemTemp.path}/deploydash-migration-v1v2-'
        '${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(() async {
        if (await file.exists()) {
          await file.delete();
        }
      });

      // Phase 1: full schema with one server row, then strip the v2 column
      // and re-stamp as v1: the closest faithful stand-in for a real v1
      // file, which predates early saves entirely.
      var migrated = AppDatabase.forTesting(NativeDatabase(file));
      await migrated
          .into(migrated.servers)
          .insert(
            ServersCompanion.insert(
              id: 'server-v1',
              name: 'Legacy',
              host: '203.0.113.60',
              sshUser: 'ubuntu',
            ),
          );
      await migrated.customStatement(
        'ALTER TABLE servers DROP COLUMN setup_complete',
      );
      await migrated.customStatement('PRAGMA user_version = 1');
      await migrated.close();

      // Phase 2: reopen; drift must upgrade 1 to 2 and backfill the row.
      migrated = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(migrated.close);
      final rows = await migrated.select(migrated.servers).get();
      final versionRow = await migrated
          .customSelect('PRAGMA user_version')
          .getSingle();

      expect(rows, hasLength(1));
      expect(rows.single.setupComplete, isTrue);
      expect(versionRow.read<int>('user_version'), 2);
    }, skip: !sqliteAvailable);

    test('recent schema columns are exposed on table definitions', () {
      expect(database.servers.setupComplete.$name, 'setup_complete');
      expect(
        database.appPreferences.gitHubPendingOauthState.$name,
        'git_hub_pending_oauth_state',
      );
      expect(database.projects.domainRoutingMode.$name, 'domain_routing_mode');
      expect(database.projects.domainRoutingMode.defaultValue, isNotNull);
      expect(database.projects.railpackProvider.$name, 'railpack_provider');
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
      expect(database.projectDatabaseAccessGrants.serverId.$name, 'server_id');
      expect(database.projectDatabaseAccessGrants.engine.$name, 'engine');
      expect(
        database.projectDatabaseAccessGrants.databaseName.$name,
        'database_name',
      );
      expect(
        database.projectDatabaseAccessUsers.connectionUri.$name,
        'connection_uri',
      );
      expect(
        database.projectManagedDatabases.databaseName.$name,
        'database_name',
      );
      expect(
        database.projectManagedDatabaseUsers.connectionUri.$name,
        'connection_uri',
      );
      expect(database.appReleases.releaseId.$name, 'release_id');
      expect(
        database.appRuntimeSnapshots.resourceUsageJson.$name,
        'resource_usage_json',
      );
      expect(
        database.workerRuntimeSnapshots.snapshotJson.$name,
        'snapshot_json',
      );
      expect(database.projectWorkspaceImportStates.status.$name, 'status');
      expect(
        database.projectManagedOperationJournal.resultJson.$name,
        'result_json',
      );
      expect(
        database.projectDeletionRecoveryStates.stepStatesJson.$name,
        'step_states_json',
      );
      expect(database.projectScreenVisits.projectId.$name, 'project_id');
      expect(
        database.projectScreenVisits.destinationId.$name,
        'destination_id',
      );
      expect(database.projectScreenVisits.visitedAt.$name, 'visited_at');
      expect(database.projectScreenVisits.visitedAt.defaultValue, isNotNull);
    });

    test(
      'project managed database repository applies workflow result contracts',
      () async {
        final repository = ProjectManagedDatabaseRepository(database);

        await repository.applyOperationResult(
          projectId: 'project-1',
          serverId: 'server-1',
          operationType: 'project_create_user',
          request: const <String, dynamic>{
            'database_name': 'dd_app',
            'access_mode': 'read_only',
          },
          result: const <String, dynamic>{
            'connection_uri':
                'postgresql://readonly:secret@postgres.internal:15432/dd_app',
          },
        );

        var databases = await repository.listDatabasesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        var users = await repository.listUsersForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        expect(databases.map((row) => row.databaseName), ['dd_app']);
        expect(users, hasLength(1));
        expect(users.single.username, 'readonly');
        expect(users.single.accessMode, 'read_only');
        expect(users.single.password, 'secret');
        expect(users.single.host, 'postgres.internal');
        expect(users.single.port, 15432);

        await repository.applyOperationResult(
          projectId: 'project-1',
          serverId: 'server-1',
          operationType: 'restore_run_now',
          result: const <String, dynamic>{
            'database_name': 'restored_app',
            'target_database_name': 'dd_example_restored_app',
          },
        );
        databases = await repository.listDatabasesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        expect(databases.map((row) => row.databaseName), [
          'dd_app',
          'restored_app',
        ]);

        await repository.applyOperationResult(
          projectId: 'project-1',
          serverId: 'server-1',
          operationType: 'project_delete_user',
          result: const <String, dynamic>{
            'database_name': 'dd_app',
            'username': 'readonly',
          },
        );
        users = await repository.listUsersForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        databases = await repository.listDatabasesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        expect(users, isEmpty);
        expect(databases.map((row) => row.databaseName), [
          'dd_app',
          'restored_app',
        ]);

        await repository.applyOperationResult(
          projectId: 'project-1',
          serverId: 'server-1',
          operationType: 'project_delete_database',
          request: const <String, dynamic>{'database_name': 'dd_app'},
          result: const <String, dynamic>{'status': 'success'},
        );
        databases = await repository.listDatabasesForScope(
          projectId: 'project-1',
          serverId: 'server-1',
        );
        expect(databases.map((row) => row.databaseName), ['restored_app']);
      },
      skip: !sqliteAvailable,
    );

    test(
      'operation journal rows can be applied and marked committed locally',
      () async {
        final appRepository = AppReleaseRepository(database);
        final managedDatabaseRepository = ProjectManagedDatabaseRepository(
          database,
        );
        final journal = await appRepository.createJournalEntry(
          projectId: 'project-journal',
          serverId: 'server-journal',
          surface: 'database',
          operationType: 'project_create_database',
          request: const <String, dynamic>{'database_name': 'journal_db'},
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{'database_name': 'journal_db'},
        );

        final remoteSuccessRows = await appRepository
            .listRemoteSuccessJournal();
        expect(remoteSuccessRows.map((row) => row.id), [journal.id]);

        await managedDatabaseRepository.applyJournaledOperation(
          projectId: 'project-journal',
          serverId: 'server-journal',
          operationType: remoteSuccessRows.single.operationType,
          requestJson: remoteSuccessRows.single.requestJson,
          resultJson: remoteSuccessRows.single.resultJson,
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'committed_local',
          result: const <String, dynamic>{'database_name': 'journal_db'},
        );

        final databases = await managedDatabaseRepository.listDatabasesForScope(
          projectId: 'project-journal',
          serverId: 'server-journal',
        );
        expect(databases.map((row) => row.databaseName), ['journal_db']);
        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'operation journal redacts secret-bearing request and result fields',
      () async {
        final repository = AppReleaseRepository(database);
        final journal = await repository.createJournalEntry(
          projectId: 'project-secret',
          serverId: 'server-secret',
          surface: 'app',
          operationType: 'run',
          request: const <String, dynamic>{
            'deploy_private_key': 'PRIVATE KEY',
            'settings': {
              'runtime_env': {'API_TOKEN': 'token-value'},
              'app_port': 3000,
            },
          },
        );
        await repository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{
            'status': 'success',
            'password': 'generated-password',
            'connection_uri': 'postgres://user:pass@example/db',
            'https_url': 'https://app.example.com',
          },
        );

        final rows = await repository.listRemoteSuccessJournal();
        final stored = rows.single;
        final request = jsonDecode(stored.requestJson!) as Map<String, dynamic>;
        final result = jsonDecode(stored.resultJson!) as Map<String, dynamic>;

        expect(request['deploy_private_key'], '***');
        expect((request['settings'] as Map)['runtime_env'], {
          'API_TOKEN': '***',
        });
        expect((request['settings'] as Map)['app_port'], 3000);
        expect(result['password'], '***');
        expect(result['connection_uri'], 'postgres://user:***@example/db');
        expect(result['https_url'], 'https://app.example.com');
      },
      skip: !sqliteAvailable,
    );

    test(
      'operation journal replay never treats redaction markers as credentials',
      () async {
        final appRepository = AppReleaseRepository(database);
        final managedDatabaseRepository = ProjectManagedDatabaseRepository(
          database,
        );
        final journal = await appRepository.createJournalEntry(
          projectId: 'project-replay-secret',
          serverId: 'server-replay-secret',
          surface: 'database',
          operationType: 'project_create_user',
          request: const <String, dynamic>{
            'database_name': 'replay_db',
            'username': 'replay_user',
            'access_mode': 'read_only',
          },
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          sanitizeResult: false,
          result: const <String, dynamic>{
            'status': 'success',
            'database_name': 'replay_db',
            'username': 'replay_user',
            'access_mode': 'read_only',
            'password': 'generated-password',
            'connection_uri':
                'postgres://replay_user:generated-password@db.example.com:5432/replay_db',
            'host': 'db.example.com',
            'port': 5432,
          },
        );

        final rows = await appRepository.listRemoteSuccessJournal();
        final result =
            jsonDecode(rows.single.resultJson!) as Map<String, dynamic>;
        expect(result['password'], '***');
        expect(result['connection_uri'], isNot(contains('generated-password')));
        expect(result['connection_uri'], contains('replay_user:***'));

        await managedDatabaseRepository.applyJournaledOperation(
          projectId: 'project-replay-secret',
          serverId: 'server-replay-secret',
          operationType: rows.single.operationType,
          requestJson: rows.single.requestJson,
          resultJson: rows.single.resultJson,
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'committed_local',
          result: const <String, dynamic>{'status': 'success'},
        );

        final users = await managedDatabaseRepository.listUsersForScope(
          projectId: 'project-replay-secret',
          serverId: 'server-replay-secret',
        );
        expect(users.single.databaseName, 'replay_db');
        expect(users.single.username, 'replay_user');
        expect(users.single.accessMode, 'read_only');
        expect(users.single.password, isNull);
        expect(users.single.connectionUri, isNull);
        expect(users.single.host, 'db.example.com');
        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'app release repository parses response inventories and import states',
      () async {
        final repository = AppReleaseRepository(database);
        final records = AppReleaseRepository.recordsFromBackendResponse(
          projectId: 'project-release',
          serverId: 'server-release',
          payload: const <String, dynamic>{
            'release_inventory': {
              'live_release_id': 'release-live',
              'releases': [
                {
                  'release_id': 'release-live',
                  'status': 'live',
                  'commit_sha': 'abcdef123456',
                  'created_at': '2026-06-01T12:00:00Z',
                  'live_at': '2026-06-01T12:02:00Z',
                },
                {
                  'release_id': 'release-retained',
                  'status': 'retained',
                  'commit_sha': 'fedcba654321',
                  'created_at': '2026-05-31T12:00:00Z',
                },
              ],
            },
            'release_entry': {
              'release_id': 'release-live',
              'status': 'live',
              'commit_sha': 'abcdef123456',
            },
          },
          observedAt: DateTime.utc(2026, 6, 1, 12, 5),
        );

        expect(records.map((row) => row.releaseId).toSet(), {
          'release-live',
          'release-retained',
        });
        await repository.replaceReleasesForScope(
          projectId: 'project-release',
          serverId: 'server-release',
          releases: records,
        );
        final stored = await repository.listReleasesForScope(
          projectId: 'project-release',
          serverId: 'server-release',
        );
        expect(stored.first.releaseId, 'release-live');
        expect(stored.first.status, 'live');
        expect(stored.last.releaseId, 'release-retained');

        await repository.upsertImportState(
          projectId: 'project-release',
          serverId: 'server-release',
          status: 'completed',
        );
        final importState = await repository.readImportState(
          projectId: 'project-release',
          serverId: 'server-release',
        );
        expect(importState?.status, 'imported');
      },
      skip: !sqliteAvailable,
    );

    test(
      'project project deletion removes local-first workspace catalogs',
      () async {
        final projectRepository = ProjectRepository(database);
        final appRepository = AppReleaseRepository(database);
        final managedDatabaseRepository = ProjectManagedDatabaseRepository(
          database,
        );
        await projectRepository.createProject(
          const Project(
            id: 'project-delete',
            serverId: 'server-delete',
            name: 'Delete me',
            type: 'Web app',
            gitUrl: 'https://github.com/example/delete-me',
            primaryDomain: 'delete.example.com',
          ),
        );
        await managedDatabaseRepository.upsertDatabase(
          ProjectManagedDatabaseRepository.fromBackendDatabase(
            projectId: 'project-delete',
            serverId: 'server-delete',
            databaseName: 'delete_db',
          )!,
        );
        await managedDatabaseRepository.upsertUser(
          ProjectManagedDatabaseRepository.fromBackendUser(
            projectId: 'project-delete',
            serverId: 'server-delete',
            databaseName: 'delete_db',
            username: 'delete_user',
          )!,
        );
        await appRepository.replaceReleasesForScope(
          projectId: 'project-delete',
          serverId: 'server-delete',
          releases: [
            AppReleaseRepository.fromBackendRelease(
              projectId: 'project-delete',
              serverId: 'server-delete',
              payload: const <String, dynamic>{
                'release_id': 'release-delete',
                'status': 'live',
              },
            )!,
          ],
        );
        await appRepository.upsertRuntimeSnapshot(
          AppRuntimeSnapshotRecord(
            projectId: 'project-delete',
            serverId: 'server-delete',
            resourceUsageJson: '{"cpu":"1%"}',
            updatedAt: DateTime.utc(2026, 6, 1),
          ),
        );
        await appRepository.upsertWorkerRuntimeSnapshot(
          WorkerRuntimeSnapshotRecord(
            projectId: 'project-delete',
            serverId: 'server-delete',
            snapshotJson: '{"workers":[]}',
            updatedAt: DateTime.utc(2026, 6, 1),
          ),
        );
        await appRepository.upsertImportState(
          projectId: 'project-delete',
          serverId: 'server-delete',
          status: 'failed',
          errorMessage: 'boom',
        );
        final journal = await appRepository.createJournalEntry(
          projectId: 'project-delete',
          serverId: 'server-delete',
          surface: 'database',
          operationType: 'project_create_database',
        );
        await appRepository.updateJournalStatus(
          id: journal.id,
          status: 'remote_success',
          result: const <String, dynamic>{'database_name': 'delete_db'},
        );

        await projectRepository.deleteProjectAndRelatedRecords(
          'project-delete',
        );

        expect(
          await managedDatabaseRepository.listDatabasesForScope(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isEmpty,
        );
        expect(
          await managedDatabaseRepository.listUsersForScope(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isEmpty,
        );
        expect(
          await appRepository.listReleasesForScope(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isEmpty,
        );
        expect(
          await appRepository.readRuntimeSnapshot(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isNull,
        );
        expect(
          await appRepository.readWorkerRuntimeSnapshot(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isNull,
        );
        expect(
          await appRepository.readImportState(
            projectId: 'project-delete',
            serverId: 'server-delete',
          ),
          isNull,
        );
        expect(await appRepository.listRemoteSuccessJournal(), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test('terminal log scope indexes are created', () async {
      final rows = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND name IN ('terminal_logs_scope_created_at_idx', "
            "'terminal_logs_task_scope_created_at_idx') "
            "ORDER BY name;",
          )
          .get();

      expect(rows.map((row) => row.data['name']).toList(), [
        'terminal_logs_scope_created_at_idx',
        'terminal_logs_task_scope_created_at_idx',
      ]);
    }, skip: !sqliteAvailable);

    test(
      'appDatabaseProvider uses passphrase provider and closes on dispose',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'deploydash-app-database-provider-',
        );
        addTearDown(() async {
          if (await tempDirectory.exists()) {
            await tempDirectory.delete(recursive: true);
          }
        });
        final file = File('${tempDirectory.path}/deploydash_state.db');
        debugOverrideAppDatabaseFileResolver(() async => file);
        addTearDown(() => debugOverrideAppDatabaseFileResolver(null));

        final container = ProviderContainer(
          overrides: [
            initialDatabasePassphraseProvider.overrideWithValue('  pass  '),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(databasePassphraseProvider), 'pass');
        container.read(appDatabaseProvider);
      },
      skip: !sqliteAvailable,
    );
  });
}
