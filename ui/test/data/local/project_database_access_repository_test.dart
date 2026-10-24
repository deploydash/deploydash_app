import 'dart:io';

import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_database_access_repository.dart';
import 'package:ui/data/local/project_network_trust_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';
import '../../../integration_test/support/e2e_checklist.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectDatabaseAccessRepository', () {
    late AppDatabase database;
    late ProjectRepository projectRepository;
    late ProjectDatabaseAccessRepository repository;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      projectRepository = ProjectRepository(database);
      repository = ProjectDatabaseAccessRepository(database);
      await projectRepository.createProject(
        const Project(
          id: 'project-owner',
          serverId: 'server-1',
          name: 'Owner',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'owner.example.com',
        ),
      );
      await projectRepository.createProject(
        const Project(
          id: 'project-consumer',
          serverId: 'server-1',
          name: 'Consumer',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'consumer.example.com',
        ),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'creates one same-server grant per owner consumer and database',
      () async {
        final first = await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
        );
        final second = await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
        );
        final third = await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
          engine: 'postgres',
          databaseName: 'analytics_db',
        );

        expect(second.id, first.id);
        expect(third.id, isNot(first.id));
        expect(first.engine, 'postgres');
        expect(first.databaseName, 'owner_db');
        expect(
          await repository.listOwnerGrants(
            serverId: 'server-1',
            ownerProjectId: 'project-owner',
          ),
          hasLength(2),
        );
        expect(
          await repository.listConsumerGrants(
            serverId: 'server-1',
            consumerProjectId: 'project-consumer',
          ),
          hasLength(2),
        );
        expect(
          await ProjectNetworkTrustRepository(
            database,
          ).listTrustNetworkNamesForProject('project-consumer'),
          hasLength(1),
        );
      },
      skip: !sqliteAvailable,
    );

    test('rejects cross-server grants', () async {
      await projectRepository.createProject(
        const Project(
          id: 'project-other',
          serverId: 'server-2',
          name: 'Other',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'other.example.com',
        ),
      );

      await expectLater(
        repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-other',
        ),
        throwsStateError,
      );
    }, skip: !sqliteAvailable);

    test('rejects self grants and blank ids', () async {
      await expectLater(
        repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-owner',
        ),
        throwsArgumentError,
      );
      await expectLater(
        repository.upsertGrant(
          serverId: '   ',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
        ),
        throwsArgumentError,
      );
    }, skip: !sqliteAvailable);

    test('tracks and deletes access users for a grant', () async {
      final grant = await repository.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );
      final now = DateTime.utc(2026, 4, 23, 12);

      final user = await repository.upsertUser(
        ProjectDatabaseAccessUserRecord(
          id: 'user-1',
          grantId: grant.id,
          engine: 'postgres',
          databaseName: 'dd_owner_vectors',
          username: 'dd_owner_consumer',
          accessMode: 'read_only',
          host: 'example.com',
          port: 5432,
          connectionUri:
              'postgresql://dd_owner_consumer:secret@example.com:5432/dd_owner_vectors',
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(user.engine, 'postgres');
      expect(user.accessMode, 'read_only');
      expect(await repository.listUsersForGrant(grant.id), hasLength(1));

      await repository.deleteGrantAndUsers(grant.id);

      expect(
        await repository.listConsumerGrants(
          serverId: 'server-1',
          consumerProjectId: 'project-consumer',
        ),
        isEmpty,
      );
      expect(await repository.listUsersForGrant(grant.id), isEmpty);
      expect(
        await ProjectNetworkTrustRepository(
          database,
        ).listTrustNetworkNamesForProject('project-consumer'),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('deletes shared users for one owner database', () async {
      final grant = await repository.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );
      final now = DateTime.utc(2026, 4, 23, 12);

      await repository.upsertUser(
        ProjectDatabaseAccessUserRecord(
          id: 'postgres-user',
          grantId: grant.id,
          engine: 'postgres',
          databaseName: 'owner_db',
          username: 'reader_one',
          accessMode: 'read_only',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.upsertUser(
        ProjectDatabaseAccessUserRecord(
          id: 'other-database-user',
          grantId: grant.id,
          engine: 'postgres',
          databaseName: 'analytics_db',
          username: 'reader_two',
          accessMode: 'read_only',
          createdAt: now,
          updatedAt: now,
        ),
      );
      await repository.deleteUsersForOwnerDatabase(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        engine: 'postgres',
        databaseName: 'owner_db',
      );

      final remaining = await repository.listUsersForGrant(grant.id);
      expect(
        remaining.map((user) => user.id),
        unorderedEquals(['other-database-user']),
      );
    }, skip: !sqliteAvailable);

    test(
      'lists users for grants and supports deleteUser and deleteForProject',
      () async {
        final secondConsumer = const Project(
          id: 'project-consumer-2',
          serverId: 'server-1',
          name: 'Consumer 2',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'consumer-2.example.com',
        );
        await projectRepository.createProject(secondConsumer);

        final firstGrant = await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
        );
        final secondGrant = await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer-2',
        );
        final now = DateTime.utc(2026, 4, 23, 12);

        await repository.upsertUser(
          ProjectDatabaseAccessUserRecord(
            id: '',
            grantId: firstGrant.id,
            engine: ' POSTGRES ',
            databaseName: 'owner_db',
            username: 'reader_one',
            accessMode: ' READ_WRITE ',
            createdAt: now,
            updatedAt: now,
          ),
        );
        final secondUser = await repository.upsertUser(
          ProjectDatabaseAccessUserRecord(
            id: 'user-2',
            grantId: secondGrant.id,
            engine: 'postgres',
            databaseName: 'owner_vectors',
            username: 'reader_two',
            accessMode: 'read_only',
            createdAt: now,
            updatedAt: now,
          ),
        );

        expect(await repository.listUsersForGrants(const ['   ']), isEmpty);
        final users = await repository.listUsersForGrants([
          firstGrant.id,
          secondGrant.id,
        ]);
        expect(users, hasLength(2));
        final normalizedPostgresUser = users.singleWhere(
          (user) => user.username == 'reader_one',
        );
        expect(normalizedPostgresUser.engine, 'postgres');
        expect(normalizedPostgresUser.accessMode, 'read_write');

        await repository.deleteUser(secondUser.id);
        expect(await repository.listUsersForGrant(secondGrant.id), isEmpty);

        await repository.deleteForProject('project-consumer');
        expect(
          await repository.listConsumerGrants(
            serverId: 'server-1',
            consumerProjectId: 'project-consumer',
          ),
          isEmpty,
        );
        expect(await repository.listUsersForGrant(firstGrant.id), isEmpty);
      },
      skip: !sqliteAvailable,
    );

    test('provider resolves from database provider', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final provided = container.read(projectDatabaseAccessRepositoryProvider);
      final grant = await provided.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );

      expect(grant.ownerProjectId, 'project-owner');
    }, skip: !sqliteAvailable);

    test(
      'reports the database-sharing message when a grant spans servers',
      () async {
        await projectRepository.createProject(
          const Project(
            id: 'project-other',
            serverId: 'server-2',
            name: 'Other',
            type: 'Web app',
            gitUrl: '',
            primaryDomain: 'other.example.com',
          ),
        );

        await expectLater(
          repository.upsertGrant(
            serverId: 'server-1',
            ownerProjectId: 'project-owner',
            consumerProjectId: 'project-other',
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Database sharing is only available on the same server.',
            ),
          ),
        );
      },
      skip: !sqliteAvailable,
    );

    test(
      'grants and links derive the same trust group id for one pair',
      () async {
        await repository.upsertGrant(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
          consumerProjectId: 'project-consumer',
        );
        final trustRepository = ProjectNetworkTrustRepository(database);
        final fromGrant = await trustRepository.listGroupsForProject(
          'project-consumer',
        );
        final fromLink = await trustRepository.linkProjects(
          serverId: 'server-1',
          projectIds: const ['project-owner', 'project-consumer'],
        );

        expect(fromGrant.single.id, fromLink.id);
        expect(fromLink.id, 'trust-server-1-project-consumer-project-owner');
      },
      skip: !sqliteAvailable,
    );

    test('re-granting re-stamps the trust group creation time', () async {
      await repository.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );
      final trustRepository = ProjectNetworkTrustRepository(database);
      final firstCreatedAt = (await trustRepository.listGroupsForProject(
        'project-consumer',
      )).single.createdAt;
      // Drift stores timestamps at second precision, so the gap must cross a
      // second boundary for the re-stamp to be observable.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await repository.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );
      final group = (await trustRepository.listGroupsForProject(
        'project-consumer',
      )).single;

      // The grant path overwrites createdAt on every grant; the link path
      // preserves it. Both are pinned so the D-17 collapse cannot silently
      // unify them.
      expect(group.createdAt.isAfter(firstCreatedAt), isTrue);
    }, skip: !sqliteAvailable);
  });

  group('ProjectDatabaseAccessRepository list ordering (D-15)', () {
    late AppDatabase database;
    late ProjectRepository projectRepository;
    late ProjectDatabaseAccessRepository repository;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      projectRepository = ProjectRepository(database);
      repository = ProjectDatabaseAccessRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> createProject(String id) {
      return projectRepository.createProject(
        Project(
          id: id,
          serverId: 'server-1',
          name: id,
          type: 'Web app',
          gitUrl: '',
          primaryDomain: '$id.example.com',
        ),
      );
    }

    test(
      'owner lists order by consumer when engine and database tie',
      () async {
        await createProject('project-owner');
        await createProject('project-consumer-c');
        await createProject('project-consumer-a');
        await createProject('project-consumer-b');
        for (final consumer in [
          'project-consumer-c',
          'project-consumer-a',
          'project-consumer-b',
        ]) {
          await repository.upsertGrant(
            serverId: 'server-1',
            ownerProjectId: 'project-owner',
            consumerProjectId: consumer,
            databaseName: 'owner_db',
          );
        }

        final grants = await repository.listOwnerGrants(
          serverId: 'server-1',
          ownerProjectId: 'project-owner',
        );

        expect(grants.map((grant) => grant.consumerProjectId), [
          'project-consumer-a',
          'project-consumer-b',
          'project-consumer-c',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test(
      'consumer lists order by owner when engine and database tie',
      () async {
        await createProject('project-consumer');
        await createProject('project-owner-c');
        await createProject('project-owner-a');
        await createProject('project-owner-b');
        for (final owner in [
          'project-owner-c',
          'project-owner-a',
          'project-owner-b',
        ]) {
          await repository.upsertGrant(
            serverId: 'server-1',
            ownerProjectId: owner,
            consumerProjectId: 'project-consumer',
            databaseName: 'owner_db',
          );
        }

        final grants = await repository.listConsumerGrants(
          serverId: 'server-1',
          consumerProjectId: 'project-consumer',
        );

        expect(grants.map((grant) => grant.ownerProjectId), [
          'project-owner-a',
          'project-owner-b',
          'project-owner-c',
        ]);
      },
      skip: !sqliteAvailable,
    );

    test('user lists short-circuit blank and empty id sets', () async {
      await createProject('project-owner');
      await createProject('project-consumer');
      final grant = await repository.upsertGrant(
        serverId: 'server-1',
        ownerProjectId: 'project-owner',
        consumerProjectId: 'project-consumer',
      );
      final now = DateTime.utc(2026, 4, 23, 12);
      await repository.upsertUser(
        ProjectDatabaseAccessUserRecord(
          id: 'user-1',
          grantId: grant.id,
          engine: 'postgres',
          databaseName: 'owner_db',
          username: 'reader_one',
          accessMode: 'read_only',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // Single-blank issues a query matching nothing today; after the D-15
      // collapse it short-circuits instead. Same observable result either way.
      expect(await repository.listUsersForGrant(''), isEmpty);
      expect(await repository.listUsersForGrant('   '), isEmpty);
      expect(await repository.listUsersForGrants(const []), isEmpty);
      expect(await repository.listUsersForGrants(const ['  ']), isEmpty);
      // ... while a padded real id still trims to its user.
      expect(
        await repository.listUsersForGrant('  ${grant.id}  '),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);
  });

  group('ProjectDatabaseAccessRepository collapsed list owners (D-15)', () {
    test('lists delegate to single private owners', () {
      // Why source-based: the UNIQUE(server, owner, consumer, ...) index
      // feeds both lists their third-column order for free, so swapping a
      // third order column is behaviorally invisible (verified: a swapped
      // column still passes the ordering pins). The collapse is therefore
      // pinned structurally, guard-style: one definition + two delegate
      // call sites per owner.
      final root = findRepositoryRoot();
      final source = File(
        '${root.path}/ui/lib/data/local/project_database_access_repository.dart',
      ).readAsStringSync();
      expect('_listGrants('.allMatches(source).length, 3);
      expect('_listUsersForGrantIds('.allMatches(source).length, 3);
    });
  });
}
