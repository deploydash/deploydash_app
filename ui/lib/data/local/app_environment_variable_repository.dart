import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/dedupe_rows.dart';
import 'app_database.dart';

/// One environment variable a project's app is deployed with.
///
/// These are the *only* variables a deploy sends. Managed database credentials
/// are not injected behind the user's back -- if an app needs them, the user
/// puts them here, where they can see and change them.
class AppEnvironmentVariableRecord {
  /// Creates one variable row.
  const AppEnvironmentVariableRecord({
    required this.projectId,
    required this.key,
    required this.value,
    this.secret = false,
    this.sortOrder = 0,
  });

  /// Which project it belongs to.
  final String projectId;

  /// The variable name. Unique within a project; a later duplicate wins.
  final String key;

  /// The value, stored as typed.
  final String value;

  /// Whether to mask it in the editor. A display concern only -- every row
  /// is stored the same way, inside the encrypted database.
  final bool secret;

  /// Display position, renumbered from zero on every save.
  final int sortOrder;
}

/// Stores a project's environment variables as one ordered list.
class AppEnvironmentVariableRepository {
  /// Creates the repository over the app database.
  const AppEnvironmentVariableRepository(this._database);

  final AppDatabase _database;

  /// A project's variables in display order.
  Future<List<AppEnvironmentVariableRecord>> listForProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }

    final rows =
        await (_database.select(_database.appEnvironmentVariables)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.asc(table.sortOrder),
                (table) => OrderingTerm.asc(table.id),
              ]))
            .get();
    return rows
        .map(
          (row) => AppEnvironmentVariableRecord(
            projectId: row.projectId,
            key: row.envKey,
            value: row.envValue,
            secret: row.isSecret,
            sortOrder: row.sortOrder,
          ),
        )
        .toList(growable: false);
  }

  /// Replaces a project's variables wholesale, in one transaction.
  ///
  /// Replace rather than merge because the editor edits the whole list: a
  /// merge would make deleting a row impossible to express. Blank keys are
  /// dropped, duplicates collapse to the last one given, and positions are
  /// renumbered from the list's order.
  Future<void> replaceForProject({
    required String projectId,
    required List<AppEnvironmentVariableRecord> rows,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final normalizedRows = dedupeRowsByKey<AppEnvironmentVariableRecord>(
      rows: rows,
      keyOf: (row) {
        final key = row.key.trim();
        return key.isEmpty ? null : key;
      },
      rebuild: (row, key) => AppEnvironmentVariableRecord(
        projectId: normalizedProjectId,
        key: key,
        value: row.value,
        secret: row.secret,
        sortOrder: row.sortOrder,
      ),
    );
    final now = DateTime.now();

    await _database.transaction(() async {
      await (_database.delete(
        _database.appEnvironmentVariables,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();
      for (int index = 0; index < normalizedRows.length; index += 1) {
        final row = normalizedRows[index];
        await _database
            .into(_database.appEnvironmentVariables)
            .insert(
              AppEnvironmentVariablesCompanion.insert(
                projectId: row.projectId,
                envKey: row.key,
                envValue: row.value,
                isSecret: Value(row.secret),
                sortOrder: Value(index),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      }
    });
  }
}

/// The app-wide environment variable repository.
final appEnvironmentVariableRepositoryProvider =
    Provider<AppEnvironmentVariableRepository>((ref) {
      final database = ref.watch(appDatabaseProvider);
      return AppEnvironmentVariableRepository(database);
    });
