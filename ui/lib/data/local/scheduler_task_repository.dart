import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/bounded_int.dart';
import '../../utils/trim_or_null.dart';
import 'app_database.dart';

/// One recurring command a project runs on its server.
///
/// Two kinds share this table. A *custom* task is one the user wrote. A
/// *managed* task is one a Deploy Dash feature created and owns -- a backup
/// plan's schedule, for instance -- and is replaced wholesale by that feature
/// rather than edited. [managedByService] is what separates them, and it also
/// keeps managed tasks below custom ones in every listing.
class SchedulerTaskRecord {
  /// Records one scheduled task.
  const SchedulerTaskRecord({
    required this.id,
    required this.projectId,
    required this.name,
    required this.targetType,
    required this.command,
    required this.scheduleType,
    this.sourceType = 'custom',
    this.managedByService = false,
    this.targetRef,
    this.intervalValue,
    this.dailyTime,
    this.enabled = true,
    this.lastKnownState,
    this.lastKnownMessage,
    this.lastRunAt,
    this.nextRunAt,
    this.sortOrder = 0,
  });

  /// Stable id, and how the server addresses this task.
  final String id;

  /// Which project it belongs to.
  final String projectId;

  /// `custom` or `service`, saying which feature created it.
  final String sourceType;

  /// Whether a Deploy Dash feature owns this task.
  ///
  /// A managed task must not be hand-edited: the feature that created it
  /// replaces every one of its tasks on each save, so an edit would be
  /// silently reverted.
  final bool managedByService;

  /// What the user calls it.
  final String name;

  /// What the command runs against -- the app container, or a worker.
  final String targetType;

  /// Which worker, when [targetType] is `worker`. Cleared for any other
  /// target, so a task retargeted at the app cannot keep pointing at a worker
  /// that may no longer exist.
  final String? targetRef;

  /// The command to run.
  final String command;

  /// `daily_at`, or an interval schedule.
  final String scheduleType;

  /// Minutes between runs, clamped to 1-1440. Null for a `daily_at` schedule;
  /// the two are mutually exclusive and cleared accordingly on save.
  final int? intervalValue;

  /// `HH:MM` for a `daily_at` schedule, defaulting to `02:00` when
  /// unparseable. Null for an interval schedule.
  final String? dailyTime;

  /// Whether the task should run.
  final bool enabled;

  /// What the server last reported about it.
  final String? lastKnownState;

  /// The detail behind that state.
  final String? lastKnownMessage;

  /// When it last ran, as the server reported.
  final DateTime? lastRunAt;

  /// When it is next due, as the server reported.
  final DateTime? nextRunAt;

  /// Display position within its group.
  final int sortOrder;
}

/// One execution of a scheduled task.
class SchedulerTaskRunRecord {
  /// Records one run.
  const SchedulerTaskRunRecord({
    this.id,
    required this.taskId,
    required this.projectId,
    required this.status,
    this.message,
    this.triggeredManually = false,
    required this.triggeredAt,
    this.createdAt,
  });

  /// Autoincrement row id, null before the run is stored. Also the tiebreak
  /// for runs sharing a timestamp.
  final int? id;

  /// Which task ran.
  final String taskId;

  /// Which project it belongs to.
  final String projectId;

  /// How it ended, as the server reported.
  final String status;

  /// The detail behind that status.
  final String? message;

  /// Whether a person pressed "run now" rather than the schedule firing.
  /// Kept because an unexpected run is explained by this and nothing else.
  final bool triggeredManually;

  /// When the run started.
  final DateTime triggeredAt;

  /// When the row was written. Defaults to now.
  final DateTime? createdAt;
}

/// Stores a project's scheduled tasks and their run history.
///
/// Schedules are normalized on write: an interval is clamped to 1-1440
/// minutes, a daily time that will not parse becomes `02:00`, and whichever of
/// the two does not apply is cleared. A task carrying both would be ambiguous
/// on the server, where it actually runs.
class SchedulerTaskRepository {
  /// Creates the repository over the app database.
  const SchedulerTaskRepository(this._database);

  final AppDatabase _database;

  /// A project's tasks, custom ones first, then by position and name.
  Future<List<SchedulerTaskRecord>> listTasksForProject(
    String projectId,
  ) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }

    final rows =
        await (_database.select(_database.schedulerTasks)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.asc(table.managedByService),
                (table) => OrderingTerm.asc(table.sortOrder),
                (table) => OrderingTerm.asc(table.name),
              ]))
            .get();

    return rows
        .map(
          (row) => SchedulerTaskRecord(
            id: row.id,
            projectId: row.projectId,
            sourceType: row.sourceType,
            managedByService: row.managedByService,
            name: row.name,
            targetType: row.targetType,
            targetRef: trimOrNull(row.targetRef),
            command: row.command,
            scheduleType: row.scheduleType,
            intervalValue: row.intervalValue,
            dailyTime: trimOrNull(row.dailyTime),
            enabled: row.enabled,
            lastKnownState: trimOrNull(row.lastKnownState),
            lastKnownMessage: trimOrNull(row.lastKnownMessage),
            lastRunAt: row.lastRunAt,
            nextRunAt: row.nextRunAt,
            sortOrder: row.sortOrder,
          ),
        )
        .toList(growable: false);
  }

  /// A project's recent runs, newest first.
  ///
  /// [limit] is clamped to 1-1000: the history is for a screen, and an
  /// unbounded read of it would grow with the project's whole lifetime.
  Future<List<SchedulerTaskRunRecord>> listRunsForProject(
    String projectId, {
    int limit = 300,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const [];
    }

    final boundedLimit = boundedInt(limit, fallback: 1, max: 1000);
    final rows =
        await (_database.select(_database.schedulerTaskRuns)
              ..where((table) => table.projectId.equals(normalizedProjectId))
              ..orderBy([
                (table) => OrderingTerm.desc(table.triggeredAt),
                (table) => OrderingTerm.desc(table.id),
              ])
              ..limit(boundedLimit))
            .get();

    return rows
        .map(
          (row) => SchedulerTaskRunRecord(
            id: row.id,
            taskId: row.taskId,
            projectId: row.projectId,
            status: row.status,
            message: trimOrNull(row.message),
            triggeredManually: row.triggeredManually,
            triggeredAt: row.triggeredAt,
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  /// Creates or updates one task, preserving its original creation time.
  Future<void> upsertTask(SchedulerTaskRecord row) async {
    final normalized = _normalizeTaskRecord(row);
    final now = DateTime.now();

    final existing =
        await (_database.select(_database.schedulerTasks)
              ..where((table) => table.id.equals(normalized.id))
              ..where((table) => table.projectId.equals(normalized.projectId))
              ..limit(1))
            .getSingleOrNull();

    final companion = SchedulerTasksCompanion(
      id: Value(normalized.id),
      projectId: Value(normalized.projectId),
      sourceType: Value(normalized.sourceType),
      managedByService: Value(normalized.managedByService),
      name: Value(normalized.name),
      targetType: Value(normalized.targetType),
      targetRef: Value(normalized.targetRef),
      command: Value(normalized.command),
      scheduleType: Value(normalized.scheduleType),
      intervalValue: Value(normalized.intervalValue),
      dailyTime: Value(normalized.dailyTime),
      enabled: Value(normalized.enabled),
      lastKnownState: Value(normalized.lastKnownState),
      lastKnownMessage: Value(normalized.lastKnownMessage),
      lastRunAt: Value(normalized.lastRunAt),
      nextRunAt: Value(normalized.nextRunAt),
      sortOrder: Value(normalized.sortOrder),
      createdAt: Value(existing?.createdAt ?? now),
      updatedAt: Value(now),
    );

    await _database
        .into(_database.schedulerTasks)
        .insertOnConflictUpdate(companion);
  }

  /// Replaces every service-managed task for a project, in one transaction.
  ///
  /// Deletes then reinserts, so a task a feature no longer wants disappears --
  /// which merging could not express. Custom tasks are untouched. Every row is
  /// forced to `managedByService` and source `service` whatever it claimed, so
  /// this cannot quietly take ownership of a task the user wrote.
  Future<void> replaceManagedTasksForProject({
    required String projectId,
    required List<SchedulerTaskRecord> tasks,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final normalized = tasks
        .where((task) => task.id.trim().isNotEmpty)
        .map(
          (task) => _normalizeTaskRecord(
            task,
            projectIdOverride: normalizedProjectId,
            managedByServiceOverride: true,
            sourceTypeOverride: 'service',
          ),
        )
        .toList(growable: false);

    await _database.transaction(() async {
      await (_database.delete(_database.schedulerTasks)..where(
            (table) =>
                table.projectId.equals(normalizedProjectId) &
                table.managedByService.equals(true),
          ))
          .go();
      for (final task in normalized) {
        await upsertTask(task);
      }
    });
  }

  /// Deletes a task and its run history, in one transaction.
  Future<void> deleteTask({
    required String projectId,
    required String taskId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedTaskId = taskId.trim();
    if (normalizedProjectId.isEmpty || normalizedTaskId.isEmpty) {
      return;
    }

    await _database.transaction(() async {
      await (_database.delete(_database.schedulerTaskRuns)..where(
            (table) =>
                table.projectId.equals(normalizedProjectId) &
                table.taskId.equals(normalizedTaskId),
          ))
          .go();
      await (_database.delete(_database.schedulerTasks)..where(
            (table) =>
                table.projectId.equals(normalizedProjectId) &
                table.id.equals(normalizedTaskId),
          ))
          .go();
    });
  }

  /// Records what the server reports about a task.
  ///
  /// Separate from [upsertTask] because these are observations rather than
  /// configuration. [enabled] is the exception -- absent leaves it alone, since
  /// the server may report a task disabled for its own reasons.
  Future<void> updateTaskRuntimeStatus({
    required String taskId,
    required String projectId,
    String? lastKnownState,
    String? lastKnownMessage,
    DateTime? lastRunAt,
    DateTime? nextRunAt,
    bool? enabled,
  }) async {
    final normalizedTaskId = taskId.trim();
    final normalizedProjectId = projectId.trim();
    if (normalizedTaskId.isEmpty || normalizedProjectId.isEmpty) {
      return;
    }

    await (_database.update(_database.schedulerTasks)..where(
          (table) =>
              table.id.equals(normalizedTaskId) &
              table.projectId.equals(normalizedProjectId),
        ))
        .write(
          SchedulerTasksCompanion(
            lastKnownState: Value(trimOrNull(lastKnownState)),
            lastKnownMessage: Value(trimOrNull(lastKnownMessage)),
            lastRunAt: Value(lastRunAt),
            nextRunAt: Value(nextRunAt),
            enabled: enabled == null ? const Value.absent() : Value(enabled),
            updatedAt: Value(DateTime.now()),
          ),
        );
  }

  /// Records one run and trims that task's history to [maxRunsPerTask].
  ///
  /// Trimming is per task, not per project, so a frequently running task
  /// cannot push a daily one's entire history out of the list. The bound is
  /// clamped to 1-500. A run missing its task, project or status is dropped
  /// rather than stored as an unattributable row.
  Future<void> appendRun(
    SchedulerTaskRunRecord run, {
    int maxRunsPerTask = 100,
  }) async {
    final normalizedTaskId = run.taskId.trim();
    final normalizedProjectId = run.projectId.trim();
    final normalizedStatus = run.status.trim();
    if (normalizedTaskId.isEmpty ||
        normalizedProjectId.isEmpty ||
        normalizedStatus.isEmpty) {
      return;
    }

    final now = DateTime.now();
    await _database
        .into(_database.schedulerTaskRuns)
        .insert(
          SchedulerTaskRunsCompanion.insert(
            taskId: normalizedTaskId,
            projectId: normalizedProjectId,
            status: normalizedStatus,
            message: Value(trimOrNull(run.message)),
            triggeredManually: Value(run.triggeredManually),
            triggeredAt: Value(run.triggeredAt),
            createdAt: Value(run.createdAt ?? now),
          ),
        );

    final boundedMax = boundedInt(maxRunsPerTask, fallback: 1, max: 500);
    final rows =
        await (_database.select(_database.schedulerTaskRuns)
              ..where((table) {
                return table.projectId.equals(normalizedProjectId) &
                    table.taskId.equals(normalizedTaskId);
              })
              ..orderBy([
                (table) => OrderingTerm.desc(table.triggeredAt),
                (table) => OrderingTerm.desc(table.id),
              ]))
            .get();
    if (rows.length <= boundedMax) {
      return;
    }

    final staleIds = rows
        .skip(boundedMax)
        .map((row) => row.id)
        .toList(growable: false);
    await (_database.delete(
      _database.schedulerTaskRuns,
    )..where((table) => table.id.isIn(staleIds))).go();
  }

  SchedulerTaskRecord _normalizeTaskRecord(
    SchedulerTaskRecord row, {
    String? projectIdOverride,
    bool? managedByServiceOverride,
    String? sourceTypeOverride,
  }) {
    final targetType = row.targetType.trim().toLowerCase();
    final scheduleType = row.scheduleType.trim().toLowerCase();

    return SchedulerTaskRecord(
      id: row.id.trim(),
      projectId: (projectIdOverride ?? row.projectId).trim(),
      sourceType:
          trimOrNull(sourceTypeOverride)?.toLowerCase() ??
          row.sourceType.trim().toLowerCase(),
      managedByService: managedByServiceOverride ?? row.managedByService,
      name: row.name.trim(),
      targetType: targetType,
      targetRef: targetType == 'worker' ? trimOrNull(row.targetRef) : null,
      command: row.command.trim(),
      scheduleType: scheduleType,
      intervalValue: scheduleType == 'daily_at'
          ? null
          : _normalizeInterval(row.intervalValue),
      dailyTime: scheduleType == 'daily_at'
          ? _normalizeDailyTime(row.dailyTime)
          : null,
      enabled: row.enabled,
      lastKnownState: trimOrNull(row.lastKnownState),
      lastKnownMessage: trimOrNull(row.lastKnownMessage),
      lastRunAt: row.lastRunAt,
      nextRunAt: row.nextRunAt,
      sortOrder: row.sortOrder,
    );
  }

  static int _normalizeInterval(int? value) {
    if (value == null) {
      return 5;
    }
    if (value < 1) {
      return 1;
    }
    if (value > 24 * 60) {
      return 24 * 60;
    }
    return value;
  }

  static String _normalizeDailyTime(String? value) {
    final candidate = value?.trim() ?? '';
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(candidate);
    if (match == null) {
      return '02:00';
    }
    final hour = int.tryParse(match.group(1) ?? '');
    final minute = int.tryParse(match.group(2) ?? '');
    if (hour == null || minute == null) {
      return '02:00';
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return '02:00';
    }
    final hh = hour.toString().padLeft(2, '0');
    final mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// The app-wide scheduler repository.
final schedulerTaskRepositoryProvider = Provider<SchedulerTaskRepository>((
  ref,
) {
  final database = ref.watch(appDatabaseProvider);
  return SchedulerTaskRepository(database);
});
