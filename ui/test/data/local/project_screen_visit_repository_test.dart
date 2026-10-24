import 'package:ui/data/local/app_database.dart';
import 'package:ui/data/local/project_repository.dart';
import 'package:ui/data/local/project_deletion_recovery_repository.dart';
import 'package:ui/data/local/project_screen_visit_repository.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_support/sqlite_test_harness.dart';

void main() {
  final sqliteAvailable = ensureSqliteRuntimeAvailable();

  group('ProjectScreenVisitRepository', () {
    late AppDatabase database;
    late ProjectScreenVisitRepository repository;
    late ProjectRepository projects;

    setUp(() {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = ProjectScreenVisitRepository(database);
      projects = ProjectRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    Future<void> seedProject({
      required String id,
      required String name,
      String? serverId = 'server-1',
    }) {
      return projects.createProject(
        Project(
          id: id,
          serverId: serverId,
          name: name,
          type: 'app',
          gitUrl: 'git@github.com:acme/$id.git',
          primaryDomain: '$id.example.com',
        ),
      );
    }

    test('ignores blank identifiers', () async {
      await repository.recordVisit(projectId: '  ', destinationId: 'web-app');
      await repository.recordVisit(projectId: 'project-1', destinationId: ' ');
      await repository.forgetProject('   ');
      expect(
        await database.select(database.projectScreenVisits).get(),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('upserts one row per project and screen', () async {
      await seedProject(id: 'project-1', name: 'Billing');
      await repository.recordVisit(
        projectId: 'project-1',
        destinationId: 'web-app',
      );
      final first = await repository.listRecentVisits();
      expect(first, hasLength(1));

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repository.recordVisit(
        projectId: ' project-1 ',
        destinationId: ' web-app ',
      );
      final second = await repository.listRecentVisits();
      expect(second, hasLength(1));
      expect(
        second.single.visitedAt.isAfter(first.single.visitedAt) ||
            second.single.visitedAt == first.single.visitedAt,
        isTrue,
      );
      expect(second.single.projectName, 'Billing');
      expect(second.single.serverId, 'server-1');
    }, skip: !sqliteAvailable);

    test('orders newest first and honours the limit', () async {
      await seedProject(id: 'project-1', name: 'Billing');
      await seedProject(id: 'project-2', name: 'Marketing');
      await _insertVisit(
        database,
        projectId: 'project-1',
        destinationId: 'web-app',
        visitedAt: DateTime.utc(2026, 8, 10),
      );
      await _insertVisit(
        database,
        projectId: 'project-2',
        destinationId: 'database',
        visitedAt: DateTime.utc(2026, 8, 12),
      );

      final all = await repository.listRecentVisits();
      expect(all.map((visit) => visit.projectId), <String>[
        'project-2',
        'project-1',
      ]);

      final limited = await repository.listRecentVisits(limit: 1);
      expect(limited.single.projectId, 'project-2');
    }, skip: !sqliteAvailable);

    test('excludes projects that are missing or pending deletion', () async {
      await seedProject(id: 'project-1', name: 'Billing', serverId: null);
      await seedProject(id: 'project-2', name: 'Marketing');
      await _insertVisit(
        database,
        projectId: 'project-1',
        destinationId: 'web-app',
        visitedAt: DateTime.utc(2026, 8, 10),
      );
      await _insertVisit(
        database,
        projectId: 'project-2',
        destinationId: 'web-app',
        visitedAt: DateTime.utc(2026, 8, 11),
      );
      await _insertVisit(
        database,
        projectId: 'project-missing',
        destinationId: 'web-app',
        visitedAt: DateTime.utc(2026, 8, 12),
      );

      await ProjectDeletionRecoveryRepository(database).startRecovery(
        projectId: 'project-2',
        serverId: 'server-1',
        projectName: 'Marketing',
        projectSlug: 'marketing',
      );

      final visible = await repository.listRecentVisits();
      expect(visible.single.projectId, 'project-1');
      expect(visible.single.serverId, isNull);
    }, skip: !sqliteAvailable);

    test('does not record visits for projects pending deletion', () async {
      await seedProject(id: 'project-1', name: 'Billing');
      await ProjectDeletionRecoveryRepository(database).startRecovery(
        projectId: 'project-1',
        serverId: 'server-1',
        projectName: 'Billing',
        projectSlug: 'billing',
      );

      await repository.recordVisit(
        projectId: 'project-1',
        destinationId: 'web-app',
      );
      expect(
        await database.select(database.projectScreenVisits).get(),
        isEmpty,
      );
    }, skip: !sqliteAvailable);

    test('forgetProject removes every screen for one project', () async {
      await seedProject(id: 'project-1', name: 'Billing');
      await seedProject(id: 'project-2', name: 'Marketing');
      await repository.recordVisit(
        projectId: 'project-1',
        destinationId: 'web-app',
      );
      await repository.recordVisit(
        projectId: 'project-1',
        destinationId: 'database',
      );
      await repository.recordVisit(
        projectId: 'project-2',
        destinationId: 'web-app',
      );

      await repository.forgetProject(' project-1 ');
      final remaining = await repository.listRecentVisits();
      expect(remaining.single.projectId, 'project-2');
    }, skip: !sqliteAvailable);

    test('provider resolves against the shared database', () {
      final container = ProviderContainer(
        overrides: [appDatabaseProvider.overrideWithValue(database)],
      );
      addTearDown(container.dispose);
      expect(
        container.read(projectScreenVisitRepositoryProvider),
        isA<ProjectScreenVisitRepository>(),
      );
    }, skip: !sqliteAvailable);

    test('deleting a project prunes its recorded screen visits', () async {
      await seedProject(id: 'project-1', name: 'Billing');
      await repository.recordVisit(
        projectId: 'project-1',
        destinationId: 'web-app',
      );
      await projects.deleteProjectAndRelatedRecords('project-1');
      expect(
        await database.select(database.projectScreenVisits).get(),
        isEmpty,
      );
    }, skip: !sqliteAvailable);
  });
}

Future<void> _insertVisit(
  AppDatabase database, {
  required String projectId,
  required String destinationId,
  required DateTime visitedAt,
}) {
  return database
      .into(database.projectScreenVisits)
      .insertOnConflictUpdate(
        ProjectScreenVisitsCompanion.insert(
          projectId: projectId,
          destinationId: destinationId,
          visitedAt: Value(visitedAt),
        ),
      );
}
