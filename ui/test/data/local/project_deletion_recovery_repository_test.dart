import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_deletion_recovery_repository.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectDeletionRecoveryRepository', () {
    late AppDatabase database;
    late ProjectDeletionRecoveryRepository repository;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = ProjectDeletionRecoveryRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('step state JSON parsing is strict and stable', () {
      expect(ProjectDeletionStepState.fromJson(null), isNull);
      expect(
        ProjectDeletionStepState.fromJson(const <String, Object?>{}),
        isNull,
      );

      final pending = ProjectDeletionStepState.fromJson(const <String, Object?>{
        'id': ' app ',
        'label': ' Remove app ',
        'status': 'unknown',
        'message': ' waiting ',
      })!;
      expect(pending.id, 'app');
      expect(pending.label, 'Remove app');
      expect(pending.status, ProjectDeletionStepStatus.pending);
      expect(pending.message, 'waiting');

      final success = ProjectDeletionStepState.fromJson(const <String, Object?>{
        'id': 'app',
        'label': 'Remove app',
        'status': 'success',
      })!;
      expect(success.status, ProjectDeletionStepStatus.success);
      expect(success.toJson(), <String, Object?>{
        'id': 'app',
        'label': 'Remove app',
        'status': 'success',
      });

      final failed = success.copyWith(
        status: ProjectDeletionStepStatus.failed,
        message: 'failed',
      );
      expect(failed.status, ProjectDeletionStepStatus.failed);
      expect(failed.toJson()['message'], 'failed');
      expect(failed.copyWith().status, ProjectDeletionStepStatus.failed);
      expect(failed.copyWith().message, isNull);
    });

    test(
      'persists, retries, watches, and removes deletion recovery state',
      () async {
        await expectLater(
          repository.startRecovery(
            projectId: ' ',
            serverId: null,
            projectName: 'Project',
            projectSlug: 'project',
          ),
          throwsArgumentError,
        );
        expect(await repository.getRecovery(' '), isNull);
        await expectLater(repository.beginAttempt('missing'), throwsStateError);
        await repository.saveProgress(
          projectId: ' ',
          steps: const [],
          failed: false,
        );
        await repository.removeRecovery(' ');

        final emissions = <List<ProjectDeletionRecoveryRecord>>[];
        final subscription = repository.watchRecoveries().listen(emissions.add);
        addTearDown(subscription.cancel);

        final started = await repository.startRecovery(
          projectId: ' project-1 ',
          serverId: ' server-1 ',
          projectName: ' !!! ',
          projectSlug: ' ',
        );
        expect(started.projectId, 'project-1');
        expect(started.serverId, 'server-1');
        expect(started.projectSlug, 'project-app');
        expect(started.status, 'pending_remote');
        expect(started.attemptCount, 0);

        final attempt = await repository.beginAttempt('project-1');
        expect(attempt.attemptCount, 1);
        expect(attempt.lastAttemptAt, isNotNull);

        const steps = <ProjectDeletionStepState>[
          ProjectDeletionStepState(
            id: 'app',
            label: 'Remove app',
            status: ProjectDeletionStepStatus.success,
          ),
          ProjectDeletionStepState(
            id: 'database',
            label: 'Remove database',
            status: ProjectDeletionStepStatus.failed,
            message: 'database unavailable',
          ),
        ];
        await repository.saveProgress(
          projectId: 'project-1',
          steps: steps,
          failed: true,
          lastError: ' database unavailable ',
        );
        final failed = (await repository.getRecovery('project-1'))!;
        expect(failed.needsAttention, isTrue);
        expect(failed.lastError, 'database unavailable');
        expect(failed.steps, hasLength(2));

        final restarted = await repository.startRecovery(
          projectId: 'project-1',
          serverId: '',
          projectName: 'Renamed project',
          projectSlug: 'renamed-project',
        );
        expect(restarted.requestedAt, started.requestedAt);
        expect(restarted.attemptCount, 1);
        expect(restarted.steps, hasLength(2));
        expect(restarted.lastError, isNull);

        final second = await repository.startRecovery(
          projectId: 'project-2',
          serverId: null,
          projectName: 'Second',
          projectSlug: 'Second',
        );
        expect(second.serverId, isNull);
        expect(
          (await repository.listRecoveries()).map((item) => item.projectId),
          <String>['project-1', 'project-2'],
        );

        await (database.update(
          database.projectDeletionRecoveryStates,
        )..where((table) => table.projectId.equals('project-2'))).write(
          const ProjectDeletionRecoveryStatesCompanion(
            stepStatesJson: Value('{malformed'),
          ),
        );
        expect((await repository.getRecovery('project-2'))!.steps, isEmpty);

        await repository.removeRecovery('project-1');
        expect(await repository.getRecovery('project-1'), isNull);
        expect(emissions, isNotEmpty);
      },
      skip: !sqliteAvailable,
    );

    test(
      'providers expose the database repository and refreshable recovery list',
      () async {
        final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(database)],
        );
        addTearDown(container.dispose);
        final providedRepository = container.read(
          projectDeletionRecoveryRepositoryProvider,
        );
        await providedRepository.startRecovery(
          projectId: 'provider-project',
          serverId: 'server-1',
          projectName: 'Provider project',
          projectSlug: 'provider-project',
        );
        container.invalidate(projectDeletionRecoveriesProvider);
        final recoveries = await container.read(
          projectDeletionRecoveriesProvider.future,
        );

        expect(providedRepository, isA<ProjectDeletionRecoveryRepository>());
        expect(recoveries.single.projectId, 'provider-project');
      },
      skip: !sqliteAvailable,
    );
  });
}
