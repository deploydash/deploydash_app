import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_database_access_repository.dart';
import 'package:ui/data/local/project_deletion_recovery_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectRepository', () {
    late AppDatabase database;
    late ProjectRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = ProjectRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'a project whose stored DNS credentials are not JSON still loads',
      () async {
        // The column holds JSON this repository wrote, so a value that does
        // not parse means the row was corrupted or written by something
        // else. A local-first app cannot answer that by refusing to open the
        // project: the user would lose the whole workspace over one column.
        await repository.createProject(
          const Project(
            id: 'project-app',
            name: 'My App',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'app.example.com',
            isActive: true,
            tlsDnsCredentials: {'api_token': 'token-123'},
          ),
        );
        await database.customStatement(
          "UPDATE projects SET tls_dns_config_json = '{not-json' "
          "WHERE id = 'project-app'",
        );

        final project = await repository.readProject('project-app');

        expect(project, isNotNull);
        expect(project!.name, 'My App');
        expect(project.tlsDnsCredentials, isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test('deployment config and deploy metadata persist correctly', () async {
      await repository.createProject(
        const Project(
          id: 'project-app',
          name: 'My App',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'initial.example.com',
          isActive: true,
        ),
      );

      await repository.updateDeploymentConfig(
        projectId: 'project-app',
        primaryDomain: ' app.example.com ',
        domainRoutingMode: 'redirect_apex_to_www',
        repositoryFullName: ' me/my-app ',
        appSubdirectory: ' website/frontend ',
        deployBranch: ' main ',
        appPort: 70000,
        publicHealthCheckEnabled: false,
        publicHealthCheckPath: 'invalid-path',
        railpackNodeMode: 'RUNTIME',
        railpackProvider: 'python',
        tlsChallengeMode: 'dns',
        tlsDnsProvider: 'cloudflare',
        tlsDnsCredentials: const {'api_token': 'token-123'},
        sqliteStorageEnabled: true,
        sqliteVolumeName: 'deploydash_sqlite_bucket-app',
        sqliteMountPath: '/var/lib/deploydash/sqlite',
        sqliteFileName: 'main.db',
        railpackBuildCommand: ' ',
        railpackRunCommand: ' ',
      );

      final deployedAt = DateTime.utc(2026, 2, 14, 12, 0, 0);
      await repository.updateLastDeployState(
        projectId: 'project-app',
        commit: ' abcdef123456 ',
        deployedAt: deployedAt,
      );
      await repository.updateRuntimeState(
        projectId: 'project-app',
        appDisconnected: true,
      );

      final projects = await repository.listProjects();
      expect(projects, hasLength(1));
      final project = projects.single;
      expect(project.primaryDomain, 'app.example.com');
      expect(project.domainRoutingMode, 'redirect_apex_to_www');
      expect(project.repositoryFullName, 'me/my-app');
      expect(project.appSubdirectory, 'website/frontend');
      expect(project.deployBranch, 'main');
      expect(project.appPort, 3000);
      expect(project.publicHealthCheckEnabled, isFalse);
      expect(project.publicHealthCheckPath, '/');
      expect(project.railpackNodeMode, 'runtime');
      expect(project.railpackProvider, 'python');
      expect(project.railpackBuildCommand, isEmpty);
      expect(project.railpackRunCommand, isEmpty);
      expect(project.tlsChallengeMode, 'dns');
      expect(project.tlsDnsProvider, 'cloudflare');
      expect(project.tlsDnsCredentials, const {'api_token': 'token-123'});
      expect(project.sqliteStorageEnabled, isTrue);
      expect(project.sqliteVolumeName, 'deploydash_sqlite_bucket-app');
      expect(project.sqliteMountPath, '/var/lib/deploydash/sqlite');
      expect(project.sqliteFileName, 'main.db');
      expect(project.lastDeployCommit, 'abcdef123456');
      expect(project.lastDeployedAt?.toUtc(), deployedAt);
      expect(project.appDisconnected, isTrue);
      expect(await repository.readActiveProjectId(), 'project-app');
    }, skip: !sqliteAvailable);

    test('redirect modes normalize www input to apex storage', () async {
      await repository.createProject(
        const Project(
          id: 'project-www',
          name: 'WWW',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'www.example.com',
          isActive: true,
        ),
      );

      await repository.updateDeploymentConfig(
        projectId: 'project-www',
        primaryDomain: 'www.example.com',
        domainRoutingMode: 'redirect_www_to_apex',
        repositoryFullName: 'me/www-app',
        appSubdirectory: null,
        deployBranch: 'main',
        appPort: 3000,
        railpackNodeMode: 'auto',
        railpackProvider: null,
        tlsChallengeMode: 'http',
        tlsDnsProvider: null,
        tlsDnsCredentials: const {},
        sqliteStorageEnabled: false,
      );

      final project = (await repository.listProjects()).single;
      expect(project.primaryDomain, 'example.com');
      expect(project.domainRoutingMode, 'redirect_www_to_apex');
    }, skip: !sqliteAvailable);

    test(
      'setActiveProject switches active selection between projects',
      () async {
        await repository.createProject(
          const Project(
            id: 'project-a',
            name: 'A',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'a.example.com',
            isActive: true,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-b',
            name: 'B',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'b.example.com',
            isActive: false,
          ),
        );

        await repository.setActiveProject('project-b');

        final activeId = await repository.readActiveProjectId();
        final projects = await repository.listProjects();
        expect(activeId, 'project-b');
        expect(projects.where((project) => project.isActive), hasLength(1));
        expect(
          projects.singleWhere((project) => project.id == 'project-b').isActive,
          isTrue,
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'project listing and active selection can be scoped by server',
      () async {
        await repository.createProject(
          const Project(
            id: 'project-a',
            serverId: 'server-a',
            name: 'A',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'a.example.com',
            isActive: true,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-b',
            serverId: 'server-b',
            name: 'B',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'b.example.com',
            isActive: true,
          ),
        );

        expect(
          (await repository.listProjects(
            serverId: 'server-a',
          )).map((project) => project.id),
          ['project-a'],
        );
        expect(
          await repository.readActiveProjectId(serverId: 'server-a'),
          'project-a',
        );
        expect(
          await repository.readActiveProjectId(serverId: 'server-b'),
          'project-b',
        );

        await repository.setActiveProject('project-a');

        expect(
          await repository.readActiveProjectId(serverId: 'server-a'),
          'project-a',
        );
        expect(
          await repository.readActiveProjectId(serverId: 'server-b'),
          'project-b',
        );
      },
      skip: !sqliteAvailable,
    );

    test('empty commit is normalized to null', () async {
      await repository.createProject(
        const Project(
          id: 'project-app',
          name: 'My App',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'app.example.com',
        ),
      );

      await repository.updateLastDeployState(
        projectId: 'project-app',
        commit: '   ',
        deployedAt: DateTime.utc(2026, 2, 14, 12, 30, 0),
      );

      final project = (await repository.listProjects()).single;
      expect(project.lastDeployCommit, isNull);
    }, skip: !sqliteAvailable);

    test('database wiring and runtime flags persist correctly', () async {
      await repository.createProject(
        const Project(
          id: 'project-db',
          name: 'DB',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'db.example.com',
        ),
      );

      await repository.updateRuntimeState(
        projectId: 'project-db',
        appDisconnected: true,
      );
      await repository.updateDatabaseWiring(
        projectId: 'project-db',
        injectPostgresEnv: true,
      );

      final project = (await repository.listProjects()).single;
      expect(project.appDisconnected, isTrue);
      expect(project.injectPostgresEnv, isTrue);
    }, skip: !sqliteAvailable);

    test(
      'deleteProjectAndRelatedRecords trims empty ids and promotes next active project',
      () async {
        await repository.createProject(
          const Project(
            id: 'project-a',
            serverId: 'server-1',
            name: 'A',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'a.example.com',
            isActive: true,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-b',
            serverId: 'server-1',
            name: 'B',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'b.example.com',
            isActive: false,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-shared',
            serverId: 'server-1',
            name: 'Shared',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'shared.example.com',
            isActive: false,
          ),
        );
        final accessRepository = ProjectDatabaseAccessRepository(database);
        final grant = await accessRepository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-a',
          consumerProjectId: 'project-shared',
        );
        final now = DateTime.utc(2026, 4, 23, 12);
        await accessRepository.upsertUser(
          ProjectDatabaseAccessUserRecord(
            id: 'access-user-1',
            grantId: grant.id,
            engine: 'postgres',
            databaseName: 'dd_a_app',
            username: 'dd_a_reader',
            accessMode: 'read_only',
            createdAt: now,
            updatedAt: now,
          ),
        );

        expect(
          await repository.deleteProjectAndRelatedRecords('   '),
          'project-a',
        );

        final nextActiveId = await repository.deleteProjectAndRelatedRecords(
          'project-a',
        );
        expect(nextActiveId, 'project-b');

        final projects = await repository.listProjects();
        expect(projects, hasLength(2));
        expect(projects.map((project) => project.id), contains('project-b'));
        expect(await repository.readActiveProjectId(), 'project-b');
        expect(await accessRepository.listUsersForGrant(grant.id), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'deleteProjectAndRelatedRecords keeps an already-active remaining project',
      () async {
        await repository.createProject(
          const Project(
            id: 'project-a',
            name: 'A',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'a.example.com',
            isActive: false,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-b',
            name: 'B',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'b.example.com',
            isActive: true,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-c',
            name: 'C',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'c.example.com',
            isActive: false,
          ),
        );

        final nextActiveId = await repository.deleteProjectAndRelatedRecords(
          'project-a',
        );

        expect(nextActiveId, 'project-b');
        expect(await repository.readActiveProjectId(), 'project-b');
      },
      skip: !sqliteAvailable,
    );

    test(
      'pending deletion projects are hidden until recovery is removed',
      () async {
        await repository.createProject(
          const Project(
            id: 'project-pending',
            serverId: 'server-1',
            name: 'Pending',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'pending.example.com',
            isActive: true,
          ),
        );
        await repository.createProject(
          const Project(
            id: 'project-visible',
            serverId: 'server-1',
            name: 'Visible',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'visible.example.com',
            isActive: false,
          ),
        );
        final recoveryRepository = ProjectDeletionRecoveryRepository(database);
        await recoveryRepository.startRecovery(
          projectId: 'project-pending',
          serverId: 'server-1',
          projectName: 'Pending',
          projectSlug: 'pending',
        );

        expect((await repository.listProjects()).map((project) => project.id), [
          'project-visible',
        ]);
        expect(await repository.readActiveProjectId(), 'project-visible');
        expect(await repository.readProject('project-pending'), isNull);
        expect(
          await repository.readProject(
            'project-pending',
            includePendingDeletion: true,
          ),
          isNotNull,
        );
        await repository.setActiveProject('project-pending');
        expect(await repository.readActiveProjectId(), 'project-visible');

        await repository.deleteProjectAndRelatedRecords('project-pending');
        expect(await recoveryRepository.getRecovery('project-pending'), isNull);
      },
      skip: !sqliteAvailable,
    );

    test('provider resolves repository from the database provider', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final provided = container.read(projectRepositoryProvider);
      await provided.createProject(
        const Project(
          id: 'project-provider',
          name: 'Provider',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'provider.example.com',
          isActive: true,
        ),
      );

      final projects = await provided.listProjects();
      expect(projects, hasLength(1));
      expect(projects.single.id, 'project-provider');
    }, skip: !sqliteAvailable);
  });
}
