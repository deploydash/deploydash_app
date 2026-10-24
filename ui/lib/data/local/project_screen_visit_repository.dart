import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_database.dart';

/// One remembered visit to a screen inside a project.
///
/// What the rail's "recent" list is built from, joined with the project so a
/// row can name both the screen and the project it belongs to.
class ProjectScreenVisitRecord {
  /// Records one visit.
  const ProjectScreenVisitRecord({
    required this.projectId,
    required this.destinationId,
    required this.visitedAt,
    required this.projectName,
    this.serverId,
  });

  /// The project that was open.
  final String projectId;

  /// Which screen within it, by [ProjectDestination.id].
  final String destinationId;

  /// When it was last opened. Updated in place, so one row per screen.
  final DateTime visitedAt;

  /// The project's name at read time, for the rail's label.
  final String projectName;

  /// The project's server, when it has one.
  final String? serverId;
}

/// Remembers which project screens the user has been on.
///
/// Backs the rail's recent list and "resume where you left off". Deleted
/// projects and projects mid-deletion are excluded on both the write and the
/// read side, so a torn-down project cannot reappear as a recent destination.
class ProjectScreenVisitRepository {
  /// Creates the repository over the app database.
  ProjectScreenVisitRepository(this._database);

  final AppDatabase _database;

  /// Records that a screen was opened, replacing that screen's previous visit.
  ///
  /// One row per project and screen, so the list stays short and a repeatedly
  /// visited screen does not crowd out everything else. Does nothing for a
  /// project whose deletion is in progress.
  Future<void> recordVisit({
    required String projectId,
    required String destinationId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedDestinationId = destinationId.trim();
    if (normalizedProjectId.isEmpty || normalizedDestinationId.isEmpty) {
      return;
    }
    final pending =
        await (_database.select(_database.projectDeletionRecoveryStates)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..limit(1))
            .getSingleOrNull();
    if (pending != null) {
      return;
    }
    await _database
        .into(_database.projectScreenVisits)
        .insertOnConflictUpdate(
          ProjectScreenVisitsCompanion.insert(
            projectId: normalizedProjectId,
            destinationId: normalizedDestinationId,
            visitedAt: Value(DateTime.now()),
          ),
        );
  }

  /// The most recent visits, newest first, joined with their projects.
  ///
  /// An inner join on projects and a null check against the deletion table do
  /// the filtering, so a visit whose project has been deleted or is being
  /// deleted is dropped by the query rather than by the caller.
  Future<List<ProjectScreenVisitRecord>> listRecentVisits({
    int limit = 200,
  }) async {
    final query =
        _database.select(_database.projectScreenVisits).join([
            innerJoin(
              _database.projects,
              _database.projects.id.equalsExp(
                _database.projectScreenVisits.projectId,
              ),
            ),
            leftOuterJoin(
              _database.projectDeletionRecoveryStates,
              _database.projectDeletionRecoveryStates.projectId.equalsExp(
                _database.projectScreenVisits.projectId,
              ),
            ),
          ])
          ..where(_database.projectDeletionRecoveryStates.projectId.isNull())
          ..orderBy([
            OrderingTerm.desc(_database.projectScreenVisits.visitedAt),
          ])
          ..limit(limit);
    final rows = await query.get();
    return rows
        .map((row) {
          final visit = row.readTable(_database.projectScreenVisits);
          final project = row.readTable(_database.projects);
          final serverId = project.serverId?.trim();
          return ProjectScreenVisitRecord(
            projectId: visit.projectId,
            destinationId: visit.destinationId,
            visitedAt: visit.visitedAt,
            projectName: project.name,
            serverId: serverId == null || serverId.isEmpty ? null : serverId,
          );
        })
        .toList(growable: false);
  }

  /// Forgets every visit for a project. Part of project deletion.
  Future<void> forgetProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    await (_database.delete(
      _database.projectScreenVisits,
    )..where((table) => table.projectId.equals(normalizedProjectId))).go();
  }
}

/// The app-wide screen-visit repository.
final projectScreenVisitRepositoryProvider =
    Provider<ProjectScreenVisitRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return ProjectScreenVisitRepository(database);
    });
