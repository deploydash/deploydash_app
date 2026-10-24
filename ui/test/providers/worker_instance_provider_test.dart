import 'dart:io';

import 'package:ui/data/local/worker_instance_repository.dart';
import 'package:ui/providers/worker_instance_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

void main() {
  late ProviderContainer container;
  late _FakeWorkerInstanceRepository repository;

  setUp(() {
    repository = _FakeWorkerInstanceRepository();
    container = ProviderContainer(
      overrides: [
        workerInstanceRepositoryProvider.overrideWithValue(repository),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('loadProject hydrates workers into provider state', () async {
    await repository.replaceForProject(
      projectId: 'project-a',
      rows: const [
        WorkerInstanceRecord(
          id: 'worker-queue',
          projectId: 'project-a',
          name: 'Queue worker',
          startCommand: 'npm run worker:queue',
          cpuLimit: 1.5,
          memoryMb: 512,
          diskMb: 1024,
        ),
      ],
    );

    final notifier = container.read(projectWorkerInstancesProvider.notifier);
    await notifier.loadProject('project-a');

    final workers = notifier.workersForProject('project-a');
    expect(workers, hasLength(1));
    expect(workers.single.id, 'worker-queue');
    expect(workers.single.startCommand, 'npm run worker:queue');
  });

  test('replaceProject updates state and persists to repository', () async {
    final notifier = container.read(projectWorkerInstancesProvider.notifier);

    await notifier.replaceProject('project-a', const [
      ProjectWorkerInstance(
        id: 'worker-mailer',
        projectId: 'project-a',
        name: 'Mailer',
        startCommand: 'npm run worker:mail',
        cpuLimit: 0.75,
        memoryMb: 384,
        diskMb: 2048,
        databaseUser: 'app_rw',
        databaseName: 'app_db',
        databasePassword: 'super-secret',
      ),
    ]);

    final state = container.read(projectWorkerInstancesProvider);
    expect(state['project-a'], hasLength(1));
    expect(state['project-a']!.single.id, 'worker-mailer');

    final persisted = await repository.listForProject('project-a');
    expect(persisted, hasLength(1));
    expect(persisted.single.name, 'Mailer');
    expect(persisted.single.databaseUser, 'app_rw');
    expect(persisted.single.databaseName, 'app_db');
    expect(persisted.single.databasePassword, 'super-secret');
  });

  test('worker mapping round-trips every field (D-83)', () async {
    const record = WorkerInstanceRecord(
      id: 'worker-full',
      projectId: 'project-a',
      name: 'Full',
      startCommand: 'run-full',
      cpuLimit: 2.5,
      memoryMb: 512,
      diskMb: 2048,
      databaseUser: 'user',
      databaseName: 'name',
      databasePassword: 'password',
      databaseEngine: 'postgres',
      enabled: false,
      sortOrder: 7,
    );
    const sparse = WorkerInstanceRecord(
      id: 'worker-sparse',
      projectId: 'project-a',
      name: 'Sparse',
      startCommand: 'run-sparse',
    );
    await repository.replaceForProject(
      projectId: 'project-a',
      rows: const [record, sparse],
    );

    final notifier = container.read(projectWorkerInstancesProvider.notifier);
    await notifier.loadProject('project-a');
    final workers = notifier.workersForProject('project-a');
    expect(workers, hasLength(2));

    // Record -> instance: all 13 fields, values and nulls alike.
    final full = workers.firstWhere((worker) => worker.id == 'worker-full');
    expect(full.projectId, 'project-a');
    expect(full.name, 'Full');
    expect(full.startCommand, 'run-full');
    expect(full.cpuLimit, 2.5);
    expect(full.memoryMb, 512);
    expect(full.diskMb, 2048);
    expect(full.databaseUser, 'user');
    expect(full.databaseName, 'name');
    expect(full.databasePassword, 'password');
    expect(full.databaseEngine, 'postgres');
    expect(full.enabled, isFalse);
    expect(full.sortOrder, 7);
    final sparseWorker = workers.firstWhere(
      (worker) => worker.id == 'worker-sparse',
    );
    expect(sparseWorker.databaseUser, isNull);
    expect(sparseWorker.enabled, isTrue);
    expect(sparseWorker.sortOrder, 0);

    // Instance -> record: the same 13 fields back.
    await notifier.replaceProject('project-a', workers);
    final persisted = await repository.listForProject('project-a');
    expect(persisted, hasLength(2));
    final roundTripped = persisted.firstWhere((row) => row.id == 'worker-full');
    expect(roundTripped.projectId, 'project-a');
    expect(roundTripped.name, 'Full');
    expect(roundTripped.startCommand, 'run-full');
    expect(roundTripped.cpuLimit, 2.5);
    expect(roundTripped.memoryMb, 512);
    expect(roundTripped.diskMb, 2048);
    expect(roundTripped.databaseUser, 'user');
    expect(roundTripped.databaseName, 'name');
    expect(roundTripped.databasePassword, 'password');
    expect(roundTripped.databaseEngine, 'postgres');
    expect(roundTripped.enabled, isFalse);
    expect(roundTripped.sortOrder, 7);
    final sparsePersisted = persisted.firstWhere(
      (row) => row.id == 'worker-sparse',
    );
    expect(sparsePersisted.databaseEngine, isNull);
  });

  test('worker mappers share one field list (D-83 structural)', () {
    // The two mirror mappers cannot share constructor code in Dart, so the
    // mapped-field set is declared once and pinned by the round-trip test.
    final root = findRepositoryRoot();
    final source = File(
      '${root.path}/ui/lib/providers/worker_instance_provider.dart',
    ).readAsStringSync();
    expect('workerFieldNames'.allMatches(source).length, 1);
    expect(ProjectWorkerInstancesNotifier.workerFieldNames, hasLength(13));
  });
}

class _FakeWorkerInstanceRepository implements WorkerInstanceRepository {
  final Map<String, List<WorkerInstanceRecord>> _rowsByProject = {};

  @override
  Future<List<WorkerInstanceRecord>> listForProject(String projectId) async {
    return List<WorkerInstanceRecord>.from(
      _rowsByProject[projectId] ?? const [],
    );
  }

  @override
  Future<void> replaceForProject({
    required String projectId,
    required List<WorkerInstanceRecord> rows,
  }) async {
    _rowsByProject[projectId] = List<WorkerInstanceRecord>.from(rows);
  }
}
