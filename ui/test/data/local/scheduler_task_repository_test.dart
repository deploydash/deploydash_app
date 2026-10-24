import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/scheduler_task_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('SchedulerTaskRepository', () {
    late AppDatabase database;
    late SchedulerTaskRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = SchedulerTaskRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('same task id remains isolated across projects', () async {
      await repository.upsertTask(
        const SchedulerTaskRecord(
          id: 'shared-task',
          projectId: 'project-a',
          name: 'Project A task',
          targetType: 'host',
          command: 'echo a',
          scheduleType: 'every_minutes',
          intervalValue: 5,
        ),
      );
      await repository.upsertTask(
        const SchedulerTaskRecord(
          id: 'shared-task',
          projectId: 'project-b',
          name: 'Project B task',
          targetType: 'host',
          command: 'echo b',
          scheduleType: 'every_minutes',
          intervalValue: 10,
        ),
      );

      await repository.updateTaskRuntimeStatus(
        projectId: 'project-a',
        taskId: 'shared-task',
        lastKnownState: 'active',
      );
      await repository.appendRun(
        SchedulerTaskRunRecord(
          projectId: 'project-a',
          taskId: 'shared-task',
          status: 'success',
          triggeredAt: DateTime(2026, 4, 13, 10),
        ),
      );
      await repository.appendRun(
        SchedulerTaskRunRecord(
          projectId: 'project-b',
          taskId: 'shared-task',
          status: 'failed',
          triggeredAt: DateTime(2026, 4, 13, 11),
        ),
      );
      await repository.deleteTask(
        projectId: 'project-a',
        taskId: 'shared-task',
      );

      final projectA = await repository.listTasksForProject('project-a');
      final projectB = await repository.listTasksForProject('project-b');
      final projectARuns = await repository.listRunsForProject('project-a');
      final projectBRuns = await repository.listRunsForProject('project-b');

      expect(projectA, isEmpty);
      expect(projectARuns, isEmpty);
      expect(projectB.single.id, 'shared-task');
      expect(projectB.single.name, 'Project B task');
      expect(projectB.single.intervalValue, 10);
      expect(projectB.single.lastKnownState, isNull);
      expect(projectBRuns.single.status, 'failed');
    }, skip: !sqliteAvailable);
  });

  group('SchedulerTaskRepository run bounds (D-20)', () {
    late AppDatabase database;
    late SchedulerTaskRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = SchedulerTaskRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> appendRun(String taskId, int second) {
      return repository.appendRun(
        SchedulerTaskRunRecord(
          projectId: 'project-a',
          taskId: taskId,
          status: 'success',
          triggeredAt: DateTime(2026, 4, 13, 10).add(Duration(seconds: second)),
        ),
        maxRunsPerTask: 500,
      );
    }

    test('run lists clamp to 1-1000', () async {
      // Three tasks: the per-task trim caps each at 500, so one task can
      // never hold the 1001 rows this list bound needs.
      for (var task = 0; task < 3; task++) {
        for (var index = 0; index < 334; index++) {
          await appendRun('task-$task', task * 334 + index);
        }
      }

      expect(
        await repository.listRunsForProject('project-a', limit: 2001),
        hasLength(1000),
      );
      expect(
        await repository.listRunsForProject('project-a', limit: 0),
        hasLength(1),
      );
    }, skip: !sqliteAvailable);

    test('appendRun trims each task to the bounded max', () async {
      for (var index = 0; index < 505; index++) {
        await repository.appendRun(
          SchedulerTaskRunRecord(
            projectId: 'project-a',
            taskId: 'task-1',
            status: 'success',
            triggeredAt: DateTime(
              2026,
              4,
              13,
              10,
            ).add(Duration(seconds: index)),
          ),
          maxRunsPerTask: 2000,
        );
      }

      // The list default is 300, so ask past the 500 trim bound.
      expect(
        await repository.listRunsForProject('project-a', limit: 2000),
        hasLength(500),
      );
    }, skip: !sqliteAvailable);

    test('appendRun keeps one run when the max is non-positive', () async {
      for (var index = 0; index < 3; index++) {
        await repository.appendRun(
          SchedulerTaskRunRecord(
            projectId: 'project-a',
            taskId: 'task-1',
            status: 'success',
            triggeredAt: DateTime(
              2026,
              4,
              13,
              10,
            ).add(Duration(seconds: index)),
          ),
          maxRunsPerTask: 0,
        );
      }

      expect(await repository.listRunsForProject('project-a'), hasLength(1));
    }, skip: !sqliteAvailable);
  });
}
