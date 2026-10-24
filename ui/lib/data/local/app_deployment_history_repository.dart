import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/bounded_int.dart';
import 'app_database.dart';

/// One completed deploy or rollback of a project's web app.
///
/// Written only when a deploy has finished, successfully or not, so the list is
/// a record of outcomes rather than of attempts in progress.
class AppDeploymentHistoryRecord {
  /// Records one finished deploy.
  const AppDeploymentHistoryRecord({
    required this.id,
    required this.projectId,
    required this.status,
    required this.releaseId,
    required this.deploymentKind,
    required this.rollbackFromReleaseId,
    required this.deployedAt,
    required this.durationSeconds,
    required this.actor,
    required this.branch,
    required this.commit,
    required this.createdAt,
  });

  /// Autoincrement row id. Also the tiebreak for same-second deploys.
  final int id;

  /// Which project was deployed.
  final String projectId;

  /// `success` or `failed`. Nothing else is stored -- see
  /// [AppDeploymentHistoryRepository.append].
  final String status;

  /// The release this produced, when one was created. Null for a deploy that
  /// failed before the release existed.
  final String? releaseId;

  /// `deploy` or a rollback, so the history can distinguish going forward from
  /// going back.
  final String deploymentKind;

  /// For a rollback, the release that was live before it. Null otherwise.
  final String? rollbackFromReleaseId;

  /// When the deploy ran.
  final DateTime deployedAt;

  /// How long it took, never negative.
  final int durationSeconds;

  /// Who started it. `local-user` for the desktop app, so an agent-initiated
  /// redeploy is distinguishable in the history.
  final String actor;

  /// The branch deployed. `main` when unstated.
  final String branch;

  /// The commit deployed. `unknown` when it could not be determined -- which
  /// is honest, and better than omitting the row.
  final String commit;

  /// When the row was written.
  final DateTime createdAt;
}

/// Stores and reads a project's deploy history.
class AppDeploymentHistoryRepository {
  /// Creates the repository over the app database.
  const AppDeploymentHistoryRepository(this._database);

  final AppDatabase _database;

  /// Records one finished deploy.
  ///
  /// A status other than `success` or `failed` is dropped rather than stored:
  /// this table is what the history screen counts, and an unrecognised status
  /// would show as a row that is neither.
  ///
  /// Missing actor, branch and commit are filled with `local-user`, `main` and
  /// `unknown`, so a row always says something rather than showing blanks.
  Future<void> append({
    required String projectId,
    required String status,
    String? releaseId,
    String deploymentKind = 'deploy',
    String? rollbackFromReleaseId,
    required DateTime deployedAt,
    required int durationSeconds,
    required String actor,
    required String branch,
    required String commit,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final normalizedStatus = status.trim().toLowerCase();
    if (normalizedStatus != 'success' && normalizedStatus != 'failed') {
      return;
    }

    final normalizedDuration = durationSeconds < 0 ? 0 : durationSeconds;
    final normalizedActor = actor.trim().isEmpty ? 'local-user' : actor.trim();
    final normalizedBranch = branch.trim().isEmpty ? 'main' : branch.trim();
    final normalizedCommit = commit.trim().isEmpty ? 'unknown' : commit.trim();
    final normalizedReleaseId = releaseId?.trim();
    final normalizedDeploymentKind = deploymentKind.trim().isEmpty
        ? 'deploy'
        : deploymentKind.trim();
    final normalizedRollbackFromReleaseId = rollbackFromReleaseId?.trim();

    await _database
        .into(_database.appDeploymentHistory)
        .insert(
          AppDeploymentHistoryCompanion.insert(
            projectId: normalizedProjectId,
            status: normalizedStatus,
            releaseId: Value(
              normalizedReleaseId == null || normalizedReleaseId.isEmpty
                  ? null
                  : normalizedReleaseId,
            ),
            deploymentKind: Value(normalizedDeploymentKind),
            rollbackFromReleaseId: Value(
              normalizedRollbackFromReleaseId == null ||
                      normalizedRollbackFromReleaseId.isEmpty
                  ? null
                  : normalizedRollbackFromReleaseId,
            ),
            deployedAt: deployedAt,
            durationSeconds: normalizedDuration,
            actor: normalizedActor,
            branch: normalizedBranch,
            commit: normalizedCommit,
          ),
        );
  }

  /// A project's most recent deploys, newest first.
  ///
  /// Ordered by row id after timestamp, because several deploys can share a
  /// second and insertion order is the true order.
  Future<List<AppDeploymentHistoryRecord>> listForProject(
    String projectId, {
    int limit = 5,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }

    final normalizedLimit = boundedInt(limit, fallback: 5);
    final rows =
        await (_database.select(_database.appDeploymentHistory)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.desc(table.deployedAt),
                (table) => OrderingTerm.desc(table.id),
              ])
              ..limit(normalizedLimit))
            .get();

    return rows
        .map(
          (row) => AppDeploymentHistoryRecord(
            id: row.id,
            projectId: row.projectId,
            status: row.status,
            releaseId: row.releaseId,
            deploymentKind: row.deploymentKind,
            rollbackFromReleaseId: row.rollbackFromReleaseId,
            deployedAt: row.deployedAt,
            durationSeconds: row.durationSeconds,
            actor: row.actor,
            branch: row.branch,
            commit: row.commit,
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  /// Successful deploys since [cutoff], across all projects.
  ///
  /// The trailing-week activity count behind the `deploysPerWeekBucket`
  /// attribute. Counts `success` rows of kind `deploy` only: rollbacks and
  /// auto-fallback markers are recovery, not deploys. A single integer, so
  /// callers never materialize history rows to count them.
  Future<int> countSuccessfulDeploysSince(DateTime cutoff) async {
    final table = _database.appDeploymentHistory;
    final countColumn = table.id.count();
    final query = _database.selectOnly(table)
      ..addColumns([countColumn])
      ..where(
        table.status.equals('success') &
            table.deploymentKind.equals('deploy') &
            table.deployedAt.isBiggerOrEqualValue(cutoff),
      );
    final row = await query.getSingle();
    return row.read(countColumn) ?? 0;
  }
}

/// The app-wide deploy history repository.
final appDeploymentHistoryRepositoryProvider =
    Provider<AppDeploymentHistoryRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return AppDeploymentHistoryRepository(database);
    });
