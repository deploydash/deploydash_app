import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_network_trust_repository.dart';
import 'package:ui/data/local/project_sqlite_database_repository.dart';
import 'package:ui/data/local/project_sqlite_snapshot_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectSqliteSnapshotRepository', () {
    late AppDatabase database;
    late ProjectRepository projectRepository;
    late ProjectNetworkTrustRepository trustRepository;
    late ProjectSqliteDatabaseRepository sqliteRepository;
    late ProjectSqliteSnapshotRepository snapshotRepository;

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      projectRepository = ProjectRepository(database);
      trustRepository = ProjectNetworkTrustRepository(database);
      sqliteRepository = ProjectSqliteDatabaseRepository(database);
      snapshotRepository = ProjectSqliteSnapshotRepository(database);
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

    test('builds backend snapshot mount payloads for consumer', () async {
      final group = await trustRepository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-owner', 'project-consumer'],
      );
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      await sqliteRepository.upsert(source);

      final record = await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'project-consumer',
        trustGroupId: group.id,
      );
      final payloads = await snapshotRepository
          .buildSnapshotMountPayloadsForConsumer('project-consumer');

      expect(
        record.snapshotVolumeName,
        startsWith('deploydash_sqlite_snapshot_'),
      );
      expect(payloads, [
        {
          'volume_name': record.snapshotVolumeName,
          'mount_path': '/var/lib/deploydash/sqlite-snapshots/catalog-db',
          'file_name': 'catalog.db',
          'path_env_key': 'DEPLOYDASH_SQLITE_CATALOG_DB_PATH',
          'database_url_env_key': 'DEPLOYDASH_SQLITE_CATALOG_DB_DATABASE_URL',
        },
      ]);
    }, skip: !sqliteAvailable);

    test('deleting source database removes snapshot exports', () async {
      final group = await trustRepository.linkProjects(
        serverId: 'server-1',
        projectIds: const ['project-owner', 'project-consumer'],
      );
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      await sqliteRepository.upsert(source);
      await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'project-consumer',
        trustGroupId: group.id,
      );

      await sqliteRepository.delete(
        projectId: 'project-owner',
        sqliteDatabaseId: 'sqlite-catalog',
      );

      expect(
        await snapshotRepository.listForConsumerProject('project-consumer'),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('update and delete require matching project id', () async {
      const ownerRecord = ProjectSqliteDatabase(
        id: 'sqlite-owner',
        projectId: 'project-owner',
        name: 'Owner DB',
        volumeName: 'deploydash_sqlite_owner',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'owner.db',
        isPrimary: true,
      );
      const consumerRecord = ProjectSqliteDatabase(
        id: 'sqlite-consumer',
        projectId: 'project-consumer',
        name: 'Consumer DB',
        volumeName: 'deploydash_sqlite_consumer',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'consumer.db',
        isPrimary: true,
      );
      await sqliteRepository.upsert(ownerRecord);
      await sqliteRepository.upsert(consumerRecord);

      await sqliteRepository.updateRuntimeMetadata(
        projectId: 'project-owner',
        sqliteDatabaseId: 'sqlite-consumer',
        volumeExists: true,
        volumeMountpoint: '/volumes/wrong-project',
        volumeSizeBytes: 1024,
        checkedAt: DateTime(2026, 4, 13, 10),
      );
      await sqliteRepository.delete(
        projectId: 'project-owner',
        sqliteDatabaseId: 'sqlite-consumer',
      );

      final consumerRows = await sqliteRepository.listForProject(
        'project-consumer',
      );
      expect(consumerRows.single.id, 'sqlite-consumer');
      expect(consumerRows.single.volumeName, 'deploydash_sqlite_consumer');
      expect(consumerRows.single.volumeExists, isNull);
      expect(consumerRows.single.volumeMountpoint, isNull);
      expect(consumerRows.single.volumeSizeBytes, isNull);

      await sqliteRepository.delete(
        projectId: 'project-owner',
        sqliteDatabaseId: 'sqlite-owner',
      );
      expect(await sqliteRepository.listForProject('project-owner'), isEmpty);
      expect(
        await sqliteRepository.listForProject('project-consumer'),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);

    test('deletes route by consumer, owner, and source', () async {
      const first = ProjectSqliteDatabase(
        id: 'sqlite-first',
        projectId: 'project-owner',
        name: 'First DB',
        volumeName: 'deploydash_sqlite_first',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'first.db',
        isPrimary: true,
      );
      const second = ProjectSqliteDatabase(
        id: 'sqlite-second',
        projectId: 'project-owner',
        name: 'Second DB',
        volumeName: 'deploydash_sqlite_second',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'second.db',
      );
      await projectRepository.createProject(
        const Project(
          id: 'project-other',
          serverId: 'server-1',
          name: 'Other',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'other.example.com',
        ),
      );
      await snapshotRepository.upsertPublication(
        sourceDatabase: first,
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );
      await snapshotRepository.upsertPublication(
        sourceDatabase: first,
        consumerProjectId: 'project-other',
        trustGroupId: 'trust-1',
      );
      await snapshotRepository.upsertPublication(
        sourceDatabase: second,
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );

      await snapshotRepository.deleteForConsumerProject('project-other');
      expect(
        await snapshotRepository.listForConsumerProject('project-other'),
        isEmpty,
      );
      expect(
        await snapshotRepository.listForConsumerProject('project-consumer'),
        hasLength(2),
      );

      await snapshotRepository.deleteForSource('sqlite-second');
      expect(await snapshotRepository.listForSource('sqlite-second'), isEmpty);
      expect(
        await snapshotRepository.listForSource('sqlite-first'),
        hasLength(1),
      );

      await snapshotRepository.deleteForOwnerProject('project-owner');
      expect(
        await snapshotRepository.listForConsumerProject('project-consumer'),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('deletes ignore blank ids', () async {
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );

      await snapshotRepository.deleteForConsumerProject('   ');
      await snapshotRepository.deleteForOwnerProject('');
      await snapshotRepository.deleteForSource('  ');

      expect(
        await snapshotRepository.listForConsumerProject('project-consumer'),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);

    test('snapshot names keep the lenient contract', () async {
      ProjectSqliteDatabase sourceWith({required String name}) {
        return ProjectSqliteDatabase(
          id: 'sqlite-catalog',
          projectId: 'project-owner',
          name: name,
          volumeName: 'deploydash_sqlite_catalog',
          mountPath: '/var/lib/deploydash/sqlite',
          fileName: 'catalog.db',
          isPrimary: true,
        );
      }

      Future<void> publish(ProjectSqliteDatabase source) {
        return snapshotRepository.upsertPublication(
          sourceDatabase: source,
          consumerProjectId: 'project-consumer',
          trustGroupId: 'trust-1',
        );
      }

      // No 64-char cap on this layer (the database layer enforces it).
      final longName = 'n'.padRight(65, 'a');
      final record = await snapshotRepository.upsertPublication(
        sourceDatabase: sourceWith(name: longName),
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );
      expect(record.sourceSqliteDatabaseId, 'sqlite-catalog');

      await expectLater(
        publish(sourceWith(name: 'Bad!Name')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be a SQLite name',
          ),
        ),
      );
      await expectLater(
        publish(
          ProjectSqliteDatabase(
            id: 'sqlite-catalog',
            projectId: 'project-owner',
            name: 'Catalog DB',
            volumeName: '!!!',
            mountPath: '/var/lib/deploydash/sqlite',
            fileName: 'catalog.db',
            isPrimary: true,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be a Docker name',
          ),
        ),
      );
      await expectLater(
        publish(
          ProjectSqliteDatabase(
            id: 'sqlite-catalog',
            projectId: 'project-owner',
            name: 'Catalog DB',
            volumeName: 'deploydash_sqlite_catalog',
            mountPath: '/var/lib/deploydash/sqlite',
            fileName: 'sub/dir.db',
            isPrimary: true,
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be a filename',
          ),
        ),
      );
      await expectLater(
        snapshotRepository.upsertPublication(
          sourceDatabase: sourceWith(name: 'Catalog DB'),
          consumerProjectId: '   ',
          trustGroupId: 'trust-1',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must not be empty',
          ),
        ),
      );
    }, skip: !sqliteAvailable);

    test('snapshot paths pass through without normalizing', () async {
      Future<void> publishWithMount(String mountPath) {
        return snapshotRepository.upsertPublication(
          sourceDatabase: ProjectSqliteDatabase(
            id: 'sqlite-catalog',
            projectId: 'project-owner',
            name: 'Catalog DB',
            volumeName: 'deploydash_sqlite_catalog',
            mountPath: mountPath,
            fileName: 'catalog.db',
            isPrimary: true,
          ),
          consumerProjectId: 'project-consumer',
          trustGroupId: 'trust-1',
        );
      }

      // Accepted verbatim here (no rebuild); the database layer normalizes.
      await publishWithMount('/data//doubled/');
      // Bare root accepted here; the database layer rejects it.
      await publishWithMount('/');

      await expectLater(
        publishWithMount('relative/path'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be absolute',
          ),
        ),
      );
      await expectLater(
        publishWithMount('/data/./escape'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must not contain . or ..',
          ),
        ),
      );
    }, skip: !sqliteAvailable);

    test('snapshot ids and volumes honor caller bounds', () async {
      final source = ProjectSqliteDatabase(
        id: 's${'x' * 40}',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      final record = await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'c${'y' * 40}',
        trustGroupId: 'trust-1',
      );

      expect(record.id.length, 72);
      expect(record.snapshotVolumeName.length, 27 + 80);
      expect(
        record.snapshotVolumeName,
        startsWith('deploydash_sqlite_snapshot_'),
      );

      final longNamed = await snapshotRepository.upsertPublication(
        sourceDatabase: ProjectSqliteDatabase(
          id: 'sqlite-long',
          projectId: 'project-owner',
          name: 'a'.padRight(50, 'b'),
          volumeName: 'deploydash_sqlite_long',
          mountPath: '/var/lib/deploydash/sqlite',
          fileName: 'long.db',
          isPrimary: true,
        ),
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );
      expect(
        longNamed.mountPath,
        '/var/lib/deploydash/sqlite-snapshots/${'a'.padRight(40, 'b')}',
      );
    }, skip: !sqliteAvailable);

    test('markPublished records the copy', () async {
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      final record = await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );
      expect(record.lastPublishedAt, isNull);

      final publishedAt = DateTime(2026, 4, 13, 10);
      await snapshotRepository.markPublished(
        snapshotExportId: record.id,
        publishedAt: publishedAt,
      );
      final stored = (await snapshotRepository.listForSource(
        'sqlite-catalog',
      )).single;
      expect(stored.lastPublishedAt, publishedAt);
      expect(stored.status, 'active');

      await snapshotRepository.markPublished(snapshotExportId: '   ');
      final unchanged = (await snapshotRepository.listForSource(
        'sqlite-catalog',
      )).single;
      expect(unchanged.lastPublishedAt, publishedAt);
    }, skip: !sqliteAvailable);

    test('rejects publishing a project to itself', () async {
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );

      await expectLater(
        snapshotRepository.upsertPublication(
          sourceDatabase: source,
          consumerProjectId: 'project-owner',
          trustGroupId: 'trust-1',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'SQLite snapshots are only needed for a different linked project.',
          ),
        ),
      );
    }, skip: !sqliteAvailable);

    test('record exposes the consumer database path and url', () async {
      const source = ProjectSqliteDatabase(
        id: 'sqlite-catalog',
        projectId: 'project-owner',
        name: 'Catalog DB',
        volumeName: 'deploydash_sqlite_catalog',
        mountPath: '/var/lib/deploydash/sqlite',
        fileName: 'catalog.db',
        isPrimary: true,
      );
      final record = await snapshotRepository.upsertPublication(
        sourceDatabase: source,
        consumerProjectId: 'project-consumer',
        trustGroupId: 'trust-1',
      );

      expect(
        record.databasePath,
        '/var/lib/deploydash/sqlite-snapshots/catalog-db/catalog.db',
      );
      expect(
        record.databaseUrl,
        'sqlite:////var/lib/deploydash/sqlite-snapshots/catalog-db/catalog.db',
      );
    }, skip: !sqliteAvailable);
  });
}
