import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_sqlite_database_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectSqliteDatabaseRepository id preamble (D-87)', () {
    late AppDatabase database;
    late ProjectSqliteDatabaseRepository sqliteRepository;

    const record = ProjectSqliteDatabase(
      id: 'db1',
      projectId: 'p1',
      name: 'Primary',
      volumeName: 'deploydash_sqlite_p1_db1',
      mountPath: '/data/db1',
      fileName: 'db1.db',
    );
    const recordB = ProjectSqliteDatabase(
      id: 'db2',
      projectId: 'p1',
      name: 'Second',
      volumeName: 'deploydash_sqlite_p1_db2',
      mountPath: '/data/db2',
      fileName: 'db2.db',
    );

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final projects = ProjectRepository(database);
      sqliteRepository = ProjectSqliteDatabaseRepository(database);
      await projects.createProject(
        const Project(
          id: 'p1',
          serverId: 'server-1',
          name: 'P1',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'p1.example.com',
        ),
      );
      await sqliteRepository.upsert(record);
      await sqliteRepository.upsert(recordB);
    });

    tearDown(() async {
      await database.close();
    });

    test('setPrimary ignores blank ids and keeps the primary', () async {
      await sqliteRepository.setPrimary(
        projectId: 'p1',
        sqliteDatabaseId: 'db2',
      );
      expect((await sqliteRepository.readPrimaryForProject('p1'))?.id, 'db2');

      await sqliteRepository.setPrimary(
        projectId: '   ',
        sqliteDatabaseId: 'db1',
      );
      await sqliteRepository.setPrimary(
        projectId: 'p1',
        sqliteDatabaseId: '  ',
      );

      expect((await sqliteRepository.readPrimaryForProject('p1'))?.id, 'db2');
    }, skip: !sqliteAvailable);

    test('setPrimary trims padded ids', () async {
      await sqliteRepository.setPrimary(
        projectId: '  p1  ',
        sqliteDatabaseId: '  db1  ',
      );

      expect((await sqliteRepository.readPrimaryForProject('p1'))?.id, 'db1');
    }, skip: !sqliteAvailable);

    test('updateRuntimeMetadata ignores blank ids', () async {
      await sqliteRepository.updateRuntimeMetadata(
        projectId: '   ',
        sqliteDatabaseId: 'db1',
        volumeExists: true,
      );
      await sqliteRepository.updateRuntimeMetadata(
        projectId: 'p1',
        sqliteDatabaseId: '',
        volumeExists: true,
      );

      final stored = await sqliteRepository.readPrimaryForProject('p1');
      expect(stored?.volumeExists, isNull);
    }, skip: !sqliteAvailable);

    test('updateRuntimeMetadata trims padded ids', () async {
      await sqliteRepository.updateRuntimeMetadata(
        projectId: '  p1  ',
        sqliteDatabaseId: '  db1  ',
        volumeExists: true,
      );

      final rows = await sqliteRepository.listForProject('p1');
      expect(rows.where((row) => row.id == 'db1').single.volumeExists, isTrue);
    }, skip: !sqliteAvailable);

    test('delete ignores blank ids and keeps every row', () async {
      await sqliteRepository.delete(projectId: '  ', sqliteDatabaseId: 'db1');
      await sqliteRepository.delete(projectId: 'p1', sqliteDatabaseId: '   ');

      expect(await sqliteRepository.listForProject('p1'), hasLength(2));
    }, skip: !sqliteAvailable);

    test('delete trims padded ids and repairs the primary', () async {
      await sqliteRepository.delete(
        projectId: '  p1  ',
        sqliteDatabaseId: '  db1  ',
      );

      final survivors = await sqliteRepository.listForProject('p1');
      expect(survivors.map((row) => row.id), ['db2']);
      expect((await sqliteRepository.readPrimaryForProject('p1'))?.id, 'db2');
    }, skip: !sqliteAvailable);
  });

  group('ProjectSqliteDatabaseRepository validation', () {
    late AppDatabase database;
    late ProjectSqliteDatabaseRepository sqliteRepository;

    ProjectSqliteDatabase recordWith({
      String id = 'db1',
      String projectId = 'p1',
      String name = 'Primary',
      String volumeName = 'deploydash_sqlite_p1_db1',
      String mountPath = '/data/db1',
      String fileName = 'db1.db',
    }) {
      return ProjectSqliteDatabase(
        id: id,
        projectId: projectId,
        name: name,
        volumeName: volumeName,
        mountPath: mountPath,
        fileName: fileName,
      );
    }

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      final projects = ProjectRepository(database);
      sqliteRepository = ProjectSqliteDatabaseRepository(database);
      await projects.createProject(
        const Project(
          id: 'p1',
          serverId: 'server-1',
          name: 'P1',
          type: 'Web app',
          gitUrl: '',
          primaryDomain: 'p1.example.com',
        ),
      );
    });

    tearDown(() async {
      await database.close();
    });

    test('upsert rejects names over 64 characters', () async {
      await expectLater(
        sqliteRepository.upsert(recordWith(name: 'n'.padRight(65, 'a'))),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be 64 characters or fewer',
          ),
        ),
      );

      // The snapshot layer accepts the same name (lenient contract); this
      // layer enforces the cap.
      await sqliteRepository.upsert(recordWith(name: 'n'.padRight(64, 'a')));
      expect(await sqliteRepository.listForProject('p1'), hasLength(1));
    }, skip: !sqliteAvailable);

    test('upsert validates names volumes and filenames', () async {
      await expectLater(
        sqliteRepository.upsert(recordWith(name: 'Bad!Name')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must start with alphanumeric and use letters, numbers, spaces, '
                '_, -, .',
          ),
        ),
      );
      await expectLater(
        sqliteRepository.upsert(recordWith(volumeName: '!!!')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be a valid Docker volume name',
          ),
        ),
      );
      await expectLater(
        sqliteRepository.upsert(recordWith(fileName: 'sub/dir.db')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be a plain filename without /, . or ..',
          ),
        ),
      );
      await expectLater(
        sqliteRepository.upsert(recordWith(id: '   ')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must not be empty',
          ),
        ),
      );
    }, skip: !sqliteAvailable);

    test('upsert normalizes mount paths', () async {
      await sqliteRepository.upsert(recordWith(mountPath: '/data//db1/'));
      final stored = (await sqliteRepository.listForProject('p1')).single;
      // Rebuilt, not passed through (the snapshot layer passes through).
      expect(stored.mountPath, '/data/db1');

      await expectLater(
        sqliteRepository.upsert(recordWith(mountPath: '/')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must include path segments',
          ),
        ),
      );
      await expectLater(
        sqliteRepository.upsert(recordWith(mountPath: '/data/./escape')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must not include . or .. segments',
          ),
        ),
      );
      await expectLater(
        sqliteRepository.upsert(recordWith(mountPath: 'relative/path')),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            'must be an absolute path',
          ),
        ),
      );
    }, skip: !sqliteAvailable);
  });
}
