import '../../../../providers/worker_instance_provider.dart';

/// The worker tab's pure logic: the values it edits, and the rule that names a
/// new worker.
///
/// Extracted by T-3.3.6. These were private types inside a `part` of
/// `project_workspace.dart`, so the only way to exercise `WorkerDraft`'s
/// round trip to and from a persisted `ProjectWorkerInstance` -- or the
/// de-duplicating id rule -- was to pump the whole workspace widget. They are
/// public here for the same reason the file exists: so a test can construct
/// one and assert on it.

class WorkerDatabaseUser {
  const WorkerDatabaseUser({
    required this.engine,
    required this.username,
    required this.database,
    required this.accessMode,
  });

  final String engine;
  final String username;
  final String database;
  final String accessMode;

  String get key => '$engine::$username::$database';

  String get accessLabel =>
      accessMode == 'read_only' ? 'Read only' : 'Read and write';

  String get engineLabel => 'PostgreSQL';
}

class WorkerDatabaseDiscoveryResult {
  const WorkerDatabaseDiscoveryResult({required this.users});

  final List<WorkerDatabaseUser> users;
}

class WorkerDraft {
  const WorkerDraft({
    required this.id,
    required this.name,
    required this.startCommand,
    required this.cpuLimit,
    required this.memoryMb,
    required this.diskMb,
    this.databaseUser,
    this.databaseName,
    this.databasePassword,
    this.databaseEngine,
    this.enabled = true,
  });

  final String id;
  final String name;
  final String startCommand;
  final double cpuLimit;
  final int memoryMb;
  final int diskMb;
  final String? databaseUser;
  final String? databaseName;
  final String? databasePassword;
  final String? databaseEngine;
  final bool enabled;

  WorkerDraft copyWith({
    String? id,
    String? name,
    String? startCommand,
    double? cpuLimit,
    int? memoryMb,
    int? diskMb,
    Object? databaseUser = ProjectWorkerInstance.noChange,
    Object? databaseName = ProjectWorkerInstance.noChange,
    Object? databasePassword = ProjectWorkerInstance.noChange,
    Object? databaseEngine = ProjectWorkerInstance.noChange,
    required bool enabled,
  }) {
    return WorkerDraft(
      id: id ?? this.id,
      name: name ?? this.name,
      startCommand: startCommand ?? this.startCommand,
      cpuLimit: cpuLimit ?? this.cpuLimit,
      memoryMb: memoryMb ?? this.memoryMb,
      diskMb: diskMb ?? this.diskMb,
      databaseUser: identical(databaseUser, ProjectWorkerInstance.noChange)
          ? this.databaseUser
          : databaseUser as String?,
      databaseName: identical(databaseName, ProjectWorkerInstance.noChange)
          ? this.databaseName
          : databaseName as String?,
      databasePassword:
          identical(databasePassword, ProjectWorkerInstance.noChange)
          ? this.databasePassword
          : databasePassword as String?,
      databaseEngine: identical(databaseEngine, ProjectWorkerInstance.noChange)
          ? this.databaseEngine
          : databaseEngine as String?,
      enabled: enabled,
    );
  }

  ProjectWorkerInstance toWorkerInstance({
    required String projectId,
    required int sortOrder,
  }) {
    return ProjectWorkerInstance(
      id: id,
      projectId: projectId,
      name: name,
      startCommand: startCommand,
      cpuLimit: cpuLimit,
      memoryMb: memoryMb,
      diskMb: diskMb,
      databaseUser: databaseUser,
      databaseName: databaseName,
      databasePassword: databasePassword,
      databaseEngine: databaseEngine,
      enabled: enabled,
      sortOrder: sortOrder,
    );
  }

  static WorkerDraft fromWorker(ProjectWorkerInstance worker) {
    return WorkerDraft(
      id: worker.id,
      name: worker.name,
      startCommand: worker.startCommand,
      cpuLimit: worker.cpuLimit,
      memoryMb: worker.memoryMb,
      diskMb: worker.diskMb,
      databaseUser: worker.databaseUser,
      databaseName: worker.databaseName,
      databasePassword: worker.databasePassword,
      databaseEngine: worker.databaseEngine,
      enabled: worker.enabled,
    );
  }
}

/// A worker id derived from [name], unique against [existingIds].
///
/// The id is what addresses the worker's container on the server, so it is
/// slugified and then suffixed until it does not collide. A blank name falls
/// back to `worker` rather than producing an empty id.
String nextWorkerId(String name, Set<String> existingIds) {
  final base = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final candidateBase = base.isEmpty ? 'worker' : base;
  var candidate = candidateBase;
  var counter = 2;
  while (existingIds.contains(candidate)) {
    candidate = '$candidateBase-$counter';
    counter += 1;
  }
  return candidate;
}
