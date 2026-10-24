import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/app_deployment_history_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('AppDeploymentHistoryRepository', () {
    late AppDatabase database;
    late AppDeploymentHistoryRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = AppDeploymentHistoryRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test(
      'append persists entries and listForProject returns newest first',
      () async {
        await repository.append(
          projectId: 'project-a',
          status: 'success',
          releaseId: 'release-1',
          deployedAt: DateTime.utc(2026, 2, 14, 10, 0, 0),
          durationSeconds: 21,
          actor: 'alice',
          branch: 'main',
          commit: '111aaa',
        );
        await repository.append(
          projectId: 'project-a',
          status: 'failed',
          releaseId: 'release-2',
          deploymentKind: 'rollback',
          rollbackFromReleaseId: 'release-1',
          deployedAt: DateTime.utc(2026, 2, 14, 10, 1, 0),
          durationSeconds: 9,
          actor: 'alice',
          branch: 'main',
          commit: '222bbb',
        );

        final rows = await repository.listForProject('project-a', limit: 5);
        expect(rows, hasLength(2));
        expect(rows.first.status, 'failed');
        expect(rows.first.commit, '222bbb');
        expect(rows.first.releaseId, 'release-2');
        expect(rows.first.deploymentKind, 'rollback');
        expect(rows.first.rollbackFromReleaseId, 'release-1');
        expect(rows.last.status, 'success');
        expect(rows.last.commit, '111aaa');
        expect(rows.last.releaseId, 'release-1');
        expect(rows.last.deploymentKind, 'deploy');
      },
      skip: !sqliteAvailable,
    );

    test('append normalizes values and ignores invalid rows', () async {
      await repository.append(
        projectId: '   ',
        status: 'success',
        deployedAt: DateTime.utc(2026, 2, 14, 10, 0, 0),
        durationSeconds: 10,
        actor: 'alice',
        branch: 'main',
        commit: '111aaa',
      );
      await repository.append(
        projectId: 'project-a',
        status: 'running',
        deployedAt: DateTime.utc(2026, 2, 14, 10, 1, 0),
        durationSeconds: 10,
        actor: 'alice',
        branch: 'main',
        commit: '222bbb',
      );
      await repository.append(
        projectId: 'project-a',
        status: 'SUCCESS',
        deployedAt: DateTime.utc(2026, 2, 14, 10, 2, 0),
        durationSeconds: -12,
        actor: ' ',
        branch: ' ',
        commit: ' ',
      );

      final rows = await repository.listForProject('project-a', limit: 5);
      expect(rows, hasLength(1));
      expect(rows.single.status, 'success');
      expect(rows.single.durationSeconds, 0);
      expect(rows.single.actor, 'local-user');
      expect(rows.single.branch, 'main');
      expect(rows.single.commit, 'unknown');
      expect(rows.single.deploymentKind, 'deploy');
    }, skip: !sqliteAvailable);

    test(
      'listForProject uses default limit when caller passes non-positive',
      () async {
        for (int i = 0; i < 7; i += 1) {
          await repository.append(
            projectId: 'project-a',
            status: 'success',
            deployedAt: DateTime.utc(2026, 2, 14, 11, i, 0),
            durationSeconds: i,
            actor: 'alice',
            branch: 'main',
            commit: 'commit-$i',
          );
        }

        final rows = await repository.listForProject('project-a', limit: 0);
        expect(rows, hasLength(5));
        expect(rows.first.commit, 'commit-6');
        expect(rows.last.commit, 'commit-2');
      },
      skip: !sqliteAvailable,
    );

    test('listForProject never caps the limit', () async {
      for (var index = 0; index < 1001; index++) {
        await repository.append(
          projectId: 'project-a',
          status: 'success',
          deployedAt: DateTime.utc(2026, 2, 14).add(Duration(seconds: index)),
          durationSeconds: 1,
          actor: 'alice',
          branch: 'main',
          commit: 'commit-$index',
        );
      }

      // One-sided: huge passes through (the non-positive fallback to 5 is
      // pinned by the existing default-limit test).
      expect(
        await repository.listForProject('project-a', limit: 1000000),
        hasLength(1001),
      );
    }, skip: !sqliteAvailable);

    test(
      'countSuccessfulDeploysSince counts recent successful deploys only',
      () async {
        final now = DateTime.now().toUtc();
        Future<void> seed({
          required String commit,
          required String status,
          String deploymentKind = 'deploy',
          required Duration age,
        }) {
          return repository.append(
            projectId: 'project-a',
            status: status,
            deploymentKind: deploymentKind,
            deployedAt: now.subtract(age),
            durationSeconds: 10,
            actor: 'alice',
            branch: 'main',
            commit: commit,
          );
        }

        await seed(
          commit: 'recent-1',
          status: 'success',
          age: Duration(days: 1),
        );
        await seed(
          commit: 'recent-2',
          status: 'success',
          age: Duration(days: 6),
        );
        await seed(
          commit: 'failed-1',
          status: 'failed',
          age: Duration(days: 1),
        );
        await seed(
          commit: 'rollback-1',
          status: 'success',
          deploymentKind: 'rollback',
          age: Duration(days: 1),
        );
        await seed(
          commit: 'fallback-1',
          status: 'success',
          deploymentKind: 'auto_fallback',
          age: Duration(days: 1),
        );
        await seed(commit: 'old-1', status: 'success', age: Duration(days: 8));

        expect(
          await repository.countSuccessfulDeploysSince(
            now.subtract(const Duration(days: 7)),
          ),
          2,
        );
        expect(
          await repository.countSuccessfulDeploysSince(
            now.subtract(const Duration(days: 2)),
          ),
          1,
        );
        expect(
          await repository.countSuccessfulDeploysSince(
            now.add(const Duration(days: 1)),
          ),
          0,
        );
      },
      skip: !sqliteAvailable,
    );
  });
}
