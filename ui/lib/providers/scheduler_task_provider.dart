import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/scheduler_task_repository.dart';

class ProjectScheduledTask {
  static const Object noChange = Object();

  const ProjectScheduledTask({
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

  final String id;
  final String projectId;
  final String sourceType;
  final bool managedByService;
  final String name;
  final String targetType;
  final String? targetRef;
  final String command;
  final String scheduleType;
  final int? intervalValue;
  final String? dailyTime;
  final bool enabled;
  final String? lastKnownState;
  final String? lastKnownMessage;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final int sortOrder;

  ProjectScheduledTask copyWith({
    String? id,
    String? projectId,
    String? sourceType,
    bool? managedByService,
    String? name,
    String? targetType,
    Object? targetRef = noChange,
    String? command,
    String? scheduleType,
    Object? intervalValue = noChange,
    Object? dailyTime = noChange,
    bool? enabled,
    Object? lastKnownState = noChange,
    Object? lastKnownMessage = noChange,
    Object? lastRunAt = noChange,
    Object? nextRunAt = noChange,
    int? sortOrder,
  }) {
    return ProjectScheduledTask(
      id: id ?? this.id,
      projectId: projectId ?? this.projectId,
      sourceType: sourceType ?? this.sourceType,
      managedByService: managedByService ?? this.managedByService,
      name: name ?? this.name,
      targetType: targetType ?? this.targetType,
      targetRef: identical(targetRef, noChange)
          ? this.targetRef
          : targetRef as String?,
      command: command ?? this.command,
      scheduleType: scheduleType ?? this.scheduleType,
      intervalValue: identical(intervalValue, noChange)
          ? this.intervalValue
          : intervalValue as int?,
      dailyTime: identical(dailyTime, noChange)
          ? this.dailyTime
          : dailyTime as String?,
      enabled: enabled ?? this.enabled,
      lastKnownState: identical(lastKnownState, noChange)
          ? this.lastKnownState
          : lastKnownState as String?,
      lastKnownMessage: identical(lastKnownMessage, noChange)
          ? this.lastKnownMessage
          : lastKnownMessage as String?,
      lastRunAt: identical(lastRunAt, noChange)
          ? this.lastRunAt
          : lastRunAt as DateTime?,
      nextRunAt: identical(nextRunAt, noChange)
          ? this.nextRunAt
          : nextRunAt as DateTime?,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}

class ProjectScheduledTaskRun {
  const ProjectScheduledTaskRun({
    this.id,
    required this.taskId,
    required this.projectId,
    required this.status,
    this.message,
    this.triggeredManually = false,
    required this.triggeredAt,
    this.createdAt,
  });

  final int? id;
  final String taskId;
  final String projectId;
  final String status;
  final String? message;
  final bool triggeredManually;
  final DateTime triggeredAt;
  final DateTime? createdAt;
}

class ProjectSchedulerState {
  const ProjectSchedulerState({
    this.tasksByProject = const <String, List<ProjectScheduledTask>>{},
    this.runsByProject = const <String, List<ProjectScheduledTaskRun>>{},
  });

  final Map<String, List<ProjectScheduledTask>> tasksByProject;
  final Map<String, List<ProjectScheduledTaskRun>> runsByProject;

  List<ProjectScheduledTask> tasksForProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectScheduledTask>[];
    }
    return tasksByProject[normalizedProjectId] ??
        const <ProjectScheduledTask>[];
  }

  List<ProjectScheduledTaskRun> runsForProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return const <ProjectScheduledTaskRun>[];
    }
    return runsByProject[normalizedProjectId] ??
        const <ProjectScheduledTaskRun>[];
  }

  ProjectSchedulerState copyWith({
    Map<String, List<ProjectScheduledTask>>? tasksByProject,
    Map<String, List<ProjectScheduledTaskRun>>? runsByProject,
  }) {
    return ProjectSchedulerState(
      tasksByProject: tasksByProject ?? this.tasksByProject,
      runsByProject: runsByProject ?? this.runsByProject,
    );
  }
}

class ProjectSchedulerNotifier extends Notifier<ProjectSchedulerState> {
  @override
  ProjectSchedulerState build() => const ProjectSchedulerState();

  List<ProjectScheduledTask> tasksForProject(String projectId) {
    return state.tasksForProject(projectId);
  }

  List<ProjectScheduledTaskRun> runsForProject(String projectId) {
    return state.runsForProject(projectId);
  }

  Future<void> loadProject(String projectId) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    final repository = ref.read(schedulerTaskRepositoryProvider);
    final tasks = await repository.listTasksForProject(normalizedProjectId);
    final runs = await repository.listRunsForProject(normalizedProjectId);

    if (!ref.mounted) {
      return;
    }

    state = state.copyWith(
      tasksByProject: {
        ...state.tasksByProject,
        normalizedProjectId: tasks.map(_taskFromRecord).toList(growable: false),
      },
      runsByProject: {
        ...state.runsByProject,
        normalizedProjectId: runs.map(_runFromRecord).toList(growable: false),
      },
    );
  }

  Future<void> upsertTask(ProjectScheduledTask task) async {
    final normalizedProjectId = task.projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    await ref
        .read(schedulerTaskRepositoryProvider)
        .upsertTask(_taskToRecord(task));
    await loadProject(normalizedProjectId);
  }

  Future<void> deleteTask({
    required String projectId,
    required String taskId,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedTaskId = taskId.trim();
    if (normalizedProjectId.isEmpty || normalizedTaskId.isEmpty) {
      return;
    }

    await ref
        .read(schedulerTaskRepositoryProvider)
        .deleteTask(projectId: normalizedProjectId, taskId: normalizedTaskId);
    await loadProject(normalizedProjectId);
  }

  Future<void> replaceManagedTasks({
    required String projectId,
    required List<ProjectScheduledTask> tasks,
  }) async {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    await ref
        .read(schedulerTaskRepositoryProvider)
        .replaceManagedTasksForProject(
          projectId: normalizedProjectId,
          tasks: tasks.map(_taskToRecord).toList(growable: false),
        );
    await loadProject(normalizedProjectId);
  }

  Future<void> updateTaskRuntimeStatus({
    required String projectId,
    required String taskId,
    String? lastKnownState,
    String? lastKnownMessage,
    DateTime? lastRunAt,
    DateTime? nextRunAt,
    bool? enabled,
  }) async {
    final normalizedProjectId = projectId.trim();
    final normalizedTaskId = taskId.trim();
    if (normalizedProjectId.isEmpty || normalizedTaskId.isEmpty) {
      return;
    }

    await ref
        .read(schedulerTaskRepositoryProvider)
        .updateTaskRuntimeStatus(
          projectId: normalizedProjectId,
          taskId: normalizedTaskId,
          lastKnownState: lastKnownState,
          lastKnownMessage: lastKnownMessage,
          lastRunAt: lastRunAt,
          nextRunAt: nextRunAt,
          enabled: enabled,
        );
    await loadProject(normalizedProjectId);
  }

  Future<void> appendRun(ProjectScheduledTaskRun run) async {
    final normalizedProjectId = run.projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }

    await ref
        .read(schedulerTaskRepositoryProvider)
        .appendRun(_runToRecord(run));
    await loadProject(normalizedProjectId);
  }

  void forgetProject(String projectId) {
    final normalizedProjectId = projectId.trim();
    if (normalizedProjectId.isEmpty) {
      return;
    }
    if (!state.tasksByProject.containsKey(normalizedProjectId) &&
        !state.runsByProject.containsKey(normalizedProjectId)) {
      return;
    }
    final nextTasks = Map<String, List<ProjectScheduledTask>>.from(
      state.tasksByProject,
    )..remove(normalizedProjectId);
    final nextRuns = Map<String, List<ProjectScheduledTaskRun>>.from(
      state.runsByProject,
    )..remove(normalizedProjectId);
    state = state.copyWith(tasksByProject: nextTasks, runsByProject: nextRuns);
  }

  static ProjectScheduledTask _taskFromRecord(SchedulerTaskRecord record) {
    return ProjectScheduledTask(
      id: record.id,
      projectId: record.projectId,
      sourceType: record.sourceType,
      managedByService: record.managedByService,
      name: record.name,
      targetType: record.targetType,
      targetRef: record.targetRef,
      command: record.command,
      scheduleType: record.scheduleType,
      intervalValue: record.intervalValue,
      dailyTime: record.dailyTime,
      enabled: record.enabled,
      lastKnownState: record.lastKnownState,
      lastKnownMessage: record.lastKnownMessage,
      lastRunAt: record.lastRunAt,
      nextRunAt: record.nextRunAt,
      sortOrder: record.sortOrder,
    );
  }

  static SchedulerTaskRecord _taskToRecord(ProjectScheduledTask task) {
    return SchedulerTaskRecord(
      id: task.id,
      projectId: task.projectId,
      sourceType: task.sourceType,
      managedByService: task.managedByService,
      name: task.name,
      targetType: task.targetType,
      targetRef: task.targetRef,
      command: task.command,
      scheduleType: task.scheduleType,
      intervalValue: task.intervalValue,
      dailyTime: task.dailyTime,
      enabled: task.enabled,
      lastKnownState: task.lastKnownState,
      lastKnownMessage: task.lastKnownMessage,
      lastRunAt: task.lastRunAt,
      nextRunAt: task.nextRunAt,
      sortOrder: task.sortOrder,
    );
  }

  static ProjectScheduledTaskRun _runFromRecord(SchedulerTaskRunRecord record) {
    return ProjectScheduledTaskRun(
      id: record.id,
      taskId: record.taskId,
      projectId: record.projectId,
      status: record.status,
      message: record.message,
      triggeredManually: record.triggeredManually,
      triggeredAt: record.triggeredAt,
      createdAt: record.createdAt,
    );
  }

  static SchedulerTaskRunRecord _runToRecord(ProjectScheduledTaskRun run) {
    return SchedulerTaskRunRecord(
      id: run.id,
      taskId: run.taskId,
      projectId: run.projectId,
      status: run.status,
      message: run.message,
      triggeredManually: run.triggeredManually,
      triggeredAt: run.triggeredAt,
      createdAt: run.createdAt,
    );
  }
}

final projectSchedulerProvider =
    NotifierProvider<ProjectSchedulerNotifier, ProjectSchedulerState>(
      ProjectSchedulerNotifier.new,
    );
