import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/project_sqlite_database_repository.dart';

export '../domain/project_sqlite_database.dart';

class ProjectSqliteDatabasesNotifier
    extends Notifier<Map<String, List<ProjectSqliteDatabase>>> {
  @override
  Map<String, List<ProjectSqliteDatabase>> build() => const {};

  List<ProjectSqliteDatabase> forProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectSqliteDatabase>[];
    }
    return state[normalizedProjectId] ?? const <ProjectSqliteDatabase>[];
  }

  ProjectSqliteDatabase? primaryForProject(String projectId) {
    final rows = forProject(projectId);
    for (final row in rows) {
      if (row.isPrimary) {
        return row;
      }
    }
    return null;
  }

  Future<void> loadProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    final rows = await ref
        .read(projectSqliteDatabaseRepositoryProvider)
        .listForProject(normalizedProjectId);
    if (!ref.mounted) {
      return;
    }
    state = {...state, normalizedProjectId: rows};
  }

  Future<void> upsert(ProjectSqliteDatabase sqliteDatabase) async {
    await ref
        .read(projectSqliteDatabaseRepositoryProvider)
        .upsert(sqliteDatabase);
    await loadProject(sqliteDatabase.projectId);
  }

  Future<void> setPrimary({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    await ref
        .read(projectSqliteDatabaseRepositoryProvider)
        .setPrimary(projectId: projectId, sqliteDatabaseId: sqliteDatabaseId);
    await loadProject(projectId);
  }

  Future<void> updateRuntimeMetadata({
    required String projectId,
    required String sqliteDatabaseId,
    bool? volumeExists,
    String? volumeMountpoint,
    int? volumeSizeBytes,
    DateTime? checkedAt,
  }) async {
    await ref
        .read(projectSqliteDatabaseRepositoryProvider)
        .updateRuntimeMetadata(
          projectId: projectId,
          sqliteDatabaseId: sqliteDatabaseId,
          volumeExists: volumeExists,
          volumeMountpoint: volumeMountpoint,
          volumeSizeBytes: volumeSizeBytes,
          checkedAt: checkedAt,
        );
    await loadProject(projectId);
  }

  Future<void> delete({
    required String projectId,
    required String sqliteDatabaseId,
  }) async {
    await ref
        .read(projectSqliteDatabaseRepositoryProvider)
        .delete(projectId: projectId, sqliteDatabaseId: sqliteDatabaseId);
    await loadProject(projectId);
  }

  void forgetProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty ||
        !state.containsKey(normalizedProjectId)) {
      return;
    }
    final next = Map<String, List<ProjectSqliteDatabase>>.from(state);
    next.remove(normalizedProjectId);
    state = next;
  }
}

final projectSqliteDatabasesProvider =
    NotifierProvider<
      ProjectSqliteDatabasesNotifier,
      Map<String, List<ProjectSqliteDatabase>>
    >(ProjectSqliteDatabasesNotifier.new);
