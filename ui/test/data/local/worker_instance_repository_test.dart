import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/worker_instance_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('WorkerInstanceRepository', () {
    late AppDatabase database;
    late WorkerInstanceRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = WorkerInstanceRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('replace and list persist normalized worker rows', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: '  worker-api  ',
            projectId: 'project-a',
            name: ' API Worker ',
            startCommand: ' npm run worker:api ',
            cpuLimit: 0.05,
            memoryMb: 64,
            diskMb: 128,
            databaseUser: ' app_rw ',
            databaseName: ' app_db ',
            databasePassword: ' secret ',
          ),
          WorkerInstanceRecord(
            id: 'worker-mail',
            projectId: 'project-a',
            name: 'Mail worker',
            startCommand: 'npm run worker:mail',
            cpuLimit: 2,
            memoryMb: 512,
            diskMb: 4096,
            enabled: false,
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows, hasLength(2));

      final api = rows[0];
      expect(api.id, 'worker-api');
      expect(api.name, 'API Worker');
      expect(api.startCommand, 'npm run worker:api');
      expect(api.cpuLimit, 0.1);
      expect(api.memoryMb, 128);
      expect(api.diskMb, 256);
      expect(api.databaseUser, 'app_rw');
      expect(api.databaseName, 'app_db');
      expect(api.databasePassword, 'secret');
      expect(api.sortOrder, 0);

      final mail = rows[1];
      expect(mail.id, 'worker-mail');
      expect(mail.enabled, isFalse);
      expect(mail.sortOrder, 1);
    }, skip: !sqliteAvailable);

    test('replace drops invalid rows and clears stale rows', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: 'worker-a',
            projectId: 'project-a',
            name: 'A',
            startCommand: 'npm run a',
          ),
        ],
      );

      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: '   ',
            projectId: 'project-a',
            name: 'Missing id',
            startCommand: 'npm run ignored',
          ),
          WorkerInstanceRecord(
            id: 'worker-a',
            projectId: 'project-a',
            name: 'A updated',
            startCommand: '   ',
          ),
          WorkerInstanceRecord(
            id: 'worker-b',
            projectId: 'project-a',
            name: 'B',
            startCommand: 'npm run b',
            databaseUser: '',
            databaseName: 'db_should_clear',
            databasePassword: 'pw_should_clear',
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows, hasLength(1));
      expect(rows.single.id, 'worker-b');
      expect(rows.single.databaseUser, isNull);
      expect(rows.single.databaseName, isNull);
      expect(rows.single.databasePassword, isNull);
    }, skip: !sqliteAvailable);

    test('clamps resource limits at both ends', () async {
      WorkerInstanceRecord worker({
        required String id,
        required double cpuLimit,
        required int memoryMb,
        required int diskMb,
      }) {
        return WorkerInstanceRecord(
          id: id,
          projectId: 'project-a',
          name: id,
          startCommand: 'run $id',
          cpuLimit: cpuLimit,
          memoryMb: memoryMb,
          diskMb: diskMb,
        );
      }

      await repository.replaceForProject(
        projectId: 'project-a',
        rows: [
          worker(
            id: 'over',
            cpuLimit: 100,
            memoryMb: 2 * 1024 * 1024,
            diskMb: 2 * 1024 * 1024,
          ),
          worker(id: 'edges', cpuLimit: 64, memoryMb: 1048576, diskMb: 1048576),
          worker(id: 'low-edges', cpuLimit: 0.1, memoryMb: 128, diskMb: 256),
        ],
      );

      final rows = await repository.listForProject('project-a');
      final byId = {for (final row in rows) row.id: row};
      expect(byId['over']!.cpuLimit, 64);
      expect(byId['over']!.memoryMb, 1048576);
      expect(byId['over']!.diskMb, 1048576);
      expect(byId['edges']!.cpuLimit, 64);
      expect(byId['edges']!.memoryMb, 1048576);
      expect(byId['edges']!.diskMb, 1048576);
      expect(byId['low-edges']!.cpuLimit, 0.1);
      expect(byId['low-edges']!.memoryMb, 128);
      expect(byId['low-edges']!.diskMb, 256);
    }, skip: !sqliteAvailable);

    test('falls back to the default cpu limit for non-finite values', () async {
      WorkerInstanceRecord worker(String id, double cpuLimit) {
        return WorkerInstanceRecord(
          id: id,
          projectId: 'project-a',
          name: id,
          startCommand: 'run $id',
          cpuLimit: cpuLimit,
        );
      }

      await repository.replaceForProject(
        projectId: 'project-a',
        rows: [
          worker('nan', double.nan),
          worker('pos-inf', double.infinity),
          worker('neg-inf', double.negativeInfinity),
        ],
      );

      final rows = await repository.listForProject('project-a');
      final byId = {for (final row in rows) row.id: row};
      expect(byId['nan']!.cpuLimit, 0.5);
      expect(byId['pos-inf']!.cpuLimit, 0.5);
      expect(byId['neg-inf']!.cpuLimit, 0.5);
    }, skip: !sqliteAvailable);

    test('last duplicate id wins while keeping its first position', () async {
      WorkerInstanceRecord worker(String id, String name) {
        return WorkerInstanceRecord(
          id: id,
          projectId: 'project-a',
          name: name,
          startCommand: 'run $id',
        );
      }

      await repository.replaceForProject(
        projectId: 'project-a',
        rows: [
          worker('worker-a', 'first'),
          worker('worker-b', 'only'),
          worker('  worker-a  ', 'last'),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows.map((row) => row.id), ['worker-a', 'worker-b']);
      expect(rows[0].name, 'last');
      expect(rows[1].name, 'only');
    }, skip: !sqliteAvailable);

    test('falls back to the id for a blank worker name', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: 'worker-a',
            projectId: 'project-a',
            name: '   ',
            startCommand: 'run a',
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      expect(rows.single.name, 'worker-a');
    }, skip: !sqliteAvailable);

    test('ignores blank project ids on list and replace', () async {
      expect(await repository.listForProject('   '), isEmpty);

      await repository.replaceForProject(
        projectId: '   ',
        rows: const [
          WorkerInstanceRecord(
            id: 'worker-a',
            projectId: 'project-a',
            name: 'A',
            startCommand: 'run a',
          ),
        ],
      );
      expect(await repository.listForProject('project-a'), isEmpty);
    }, skip: !sqliteAvailable);

    test('keeps postgres engines and drops unknown ones', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: 'pg-worker',
            projectId: 'project-a',
            name: 'PG',
            startCommand: 'run pg',
            databaseUser: 'app_rw',
            databaseEngine: ' Postgres ',
          ),
          WorkerInstanceRecord(
            id: 'mysql-worker',
            projectId: 'project-a',
            name: 'My',
            startCommand: 'run my',
            databaseUser: 'app_rw',
            databaseEngine: 'mysql',
          ),
          WorkerInstanceRecord(
            id: 'userless-worker',
            projectId: 'project-a',
            name: 'No user',
            startCommand: 'run nu',
            databaseEngine: 'postgres',
          ),
        ],
      );

      final rows = await repository.listForProject('project-a');
      final byId = {for (final row in rows) row.id: row};
      expect(byId['pg-worker']!.databaseEngine, 'postgres');
      expect(byId['mysql-worker']!.databaseEngine, isNull);
      expect(byId['userless-worker']!.databaseEngine, isNull);
    }, skip: !sqliteAvailable);

    test('same worker id remains isolated across projects', () async {
      await repository.replaceForProject(
        projectId: 'project-a',
        rows: const [
          WorkerInstanceRecord(
            id: 'shared-worker',
            projectId: 'project-a',
            name: 'Project A worker',
            startCommand: 'npm run a',
          ),
        ],
      );
      await repository.replaceForProject(
        projectId: 'project-b',
        rows: const [
          WorkerInstanceRecord(
            id: 'shared-worker',
            projectId: 'project-b',
            name: 'Project B worker',
            startCommand: 'npm run b',
          ),
        ],
      );

      final projectA = await repository.listForProject('project-a');
      final projectB = await repository.listForProject('project-b');

      expect(projectA.single.id, 'shared-worker');
      expect(projectA.single.name, 'Project A worker');
      expect(projectA.single.startCommand, 'npm run a');
      expect(projectB.single.id, 'shared-worker');
      expect(projectB.single.name, 'Project B worker');
      expect(projectB.single.startCommand, 'npm run b');
    }, skip: !sqliteAvailable);

    test('provider resolves repository from the database provider', () async {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);

      final provided = container.read(workerInstanceRepositoryProvider);
      await provided.replaceForProject(
        projectId: 'project-provider',
        rows: const [
          WorkerInstanceRecord(
            id: 'worker-a',
            projectId: 'project-provider',
            name: 'A',
            startCommand: 'run a',
          ),
        ],
      );

      final rows = await provided.listForProject('project-provider');
      expect(rows.single.id, 'worker-a');
    }, skip: !sqliteAvailable);
  });
}
