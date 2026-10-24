import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/dedupe_rows.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// One background worker a project runs alongside its web app.
///
/// A worker is a long-running command in its own container -- a queue consumer,
/// a scheduler daemon -- with its own resource limits and, optionally, its own
/// managed database user.
class WorkerInstanceRecord {
  /// Creates one worker definition.
  const WorkerInstanceRecord({
    required this.id,
    required this.projectId,
    required this.name,
    required this.startCommand,
    this.cpuLimit = 0.5,
    this.memoryMb = 256,
    this.diskMb = 1024,
    this.databaseUser,
    this.databaseName,
    this.databasePassword,
    this.databaseEngine,
    this.enabled = true,
    this.sortOrder = 0,
  });

  /// Stable id, used to name the worker's container. A row with a blank id is
  /// dropped on save, since there would be nothing to address it by.
  final String id;

  /// Which project it belongs to.
  final String projectId;

  /// What the user calls it. Falls back to [id] when left blank.
  final String name;

  /// The command the container runs. A worker without one is dropped on save:
  /// there would be nothing for it to do.
  final String startCommand;

  /// CPU cores, clamped to 0.1-64. A worker that could claim every core would
  /// starve the web app on the same machine.
  final double cpuLimit;

  /// Memory in MB, clamped to 128-1048576.
  final int memoryMb;

  /// Disk in MB, clamped to 256-1048576.
  final int diskMb;

  /// The managed database user this worker connects as, when it has one.
  ///
  /// The four database fields stand or fall together: without a user, the
  /// other three are cleared on save rather than kept as a partial credential.
  final String? databaseUser;

  /// The database that user connects to.
  final String? databaseName;

  /// That user's password.
  final String? databasePassword;

  /// Which engine, or null. Only `postgres` is recognised; anything else
  /// normalizes to null rather than being stored as an engine nothing
  /// implements.
  final String? databaseEngine;

  /// Whether the worker should be running.
  final bool enabled;

  /// Display position, renumbered from zero on every save.
  final int sortOrder;
}

/// Stores a project's workers as one ordered list.
class WorkerInstanceRepository {
  /// Creates the repository over the app database.
  const WorkerInstanceRepository(this._database);

  final AppDatabase _database;

  /// A project's workers in display order.
  Future<List<WorkerInstanceRecord>> listForProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }

    final rows =
        await (_database.select(_database.workerInstances)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.asc(table.sortOrder),
                (table) => OrderingTerm.asc(table.name),
              ]))
            .get();

    return rows
        .map(
          (row) => WorkerInstanceRecord(
            id: row.id,
            projectId: row.projectId,
            name: row.name,
            startCommand: row.startCommand,
            cpuLimit: row.cpuLimit,
            memoryMb: row.memoryMb,
            diskMb: row.diskMb,
            databaseUser: trimOrNull(row.databaseUser),
            databaseName: trimOrNull(row.databaseName),
            databasePassword: trimOrNull(row.databasePassword),
            databaseEngine: _normalizeDatabaseEngine(row.databaseEngine),
            enabled: row.enabled,
            sortOrder: row.sortOrder,
          ),
        )
        .toList(growable: false);
  }

  /// Replaces a project's workers wholesale, in one transaction.
  ///
  /// Replace rather than merge, because the editor edits the whole list --
  /// merging would make deleting a worker impossible to express. Rows without
  /// an id or a start command are dropped, duplicate ids collapse to the last
  /// one given, resource limits are clamped, and positions are renumbered.
  Future<void> replaceForProject({
    required String projectId,
    required List<WorkerInstanceRecord> rows,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    // The rows below are already normalized and in order. A second pass
    // rebuilding each one only to renumber `sortOrder` was ten repeated map
    // lookups producing a field the insert loop overwrites with its own index
    // before it reaches the database.
    final normalizedRows = dedupeRowsByKey<WorkerInstanceRecord>(
      rows: rows,
      keep: (row) => row.startCommand.trim().isNotEmpty,
      keyOf: (row) {
        final id = row.id.trim();
        return id.isEmpty ? null : id;
      },
      rebuild: (row, id) {
        final startCommand = row.startCommand.trim();
        final databaseUser = trimOrNull(row.databaseUser);
        return WorkerInstanceRecord(
          id: id,
          projectId: normalizedProjectId,
          name: row.name.trim().isEmpty ? id : row.name.trim(),
          startCommand: startCommand,
          cpuLimit: _clampNum(row.cpuLimit, 0.1, 64.0, 0.5),
          memoryMb: _clampNum(row.memoryMb, 128, 1024 * 1024, 128),
          diskMb: _clampNum(row.diskMb, 256, 1024 * 1024, 256),
          databaseUser: databaseUser,
          databaseName: databaseUser == null
              ? null
              : trimOrNull(row.databaseName),
          databasePassword: databaseUser == null
              ? null
              : trimOrNull(row.databasePassword),
          databaseEngine: databaseUser == null
              ? null
              : _normalizeDatabaseEngine(row.databaseEngine),
          enabled: row.enabled,
          sortOrder: row.sortOrder,
        );
      },
    );
    final now = DateTime.now();

    await _database.transaction(() async {
      await (_database.delete(
        _database.workerInstances,
      )..where((table) => table.projectId.equals(normalizedProjectId))).go();

      for (int index = 0; index < normalizedRows.length; index += 1) {
        final row = normalizedRows[index];
        await _database
            .into(_database.workerInstances)
            .insert(
              WorkerInstancesCompanion.insert(
                id: row.id,
                projectId: normalizedProjectId,
                name: row.name,
                startCommand: row.startCommand,
                cpuLimit: Value(row.cpuLimit),
                memoryMb: Value(row.memoryMb),
                diskMb: Value(row.diskMb),
                databaseUser: Value(row.databaseUser),
                databaseName: Value(row.databaseName),
                databasePassword: Value(row.databasePassword),
                databaseEngine: Value(row.databaseEngine),
                enabled: Value(row.enabled),
                sortOrder: Value(index),
                createdAt: Value(now),
                updatedAt: Value(now),
              ),
            );
      }
    });
  }

  static String? _normalizeDatabaseEngine(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == 'postgres') {
      return 'postgres';
    }
    return null;
  }

  /// Clamps [value] into [[min], [max]], falling back on non-finite input.
  ///
  /// Why one generic owner: cpu, memory, and disk each carried the same
  /// clamp body with different bounds. The generic keeps each site's type
  /// (doubles stay doubles, ints stay ints); [fallback] answers only the
  /// double path -- ints can never be NaN, so the int sites pass [min],
  /// which is unreachable there.
  static T _clampNum<T extends num>(T value, T min, T max, T fallback) {
    final asDouble = value.toDouble();
    if (asDouble.isNaN || asDouble.isInfinite) {
      return fallback;
    }
    if (value < min) {
      return min;
    }
    if (value > max) {
      return max;
    }
    return value;
  }
}

/// The app-wide worker repository.
final workerInstanceRepositoryProvider = Provider<WorkerInstanceRepository>((
  ref,
) {
  final database = ref.watch(appDatabaseProvider);
  return WorkerInstanceRepository(database);
});
