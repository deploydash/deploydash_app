import '../../../../providers/worker_instance_provider.dart';
import '../../../../domain/worker_runtime_snapshot.dart';

export '../../../../domain/worker_runtime_snapshot.dart';

const String workerRuntimeDefaultDatabaseHost = 'host.docker.internal';
const int workerRuntimeDefaultDatabasePort = 5432;

List<Map<String, dynamic>> buildWorkersWorkflowPayload({
  required List<ProjectWorkerInstance> workers,
  String defaultDatabaseHost = workerRuntimeDefaultDatabaseHost,
  int defaultDatabasePort = workerRuntimeDefaultDatabasePort,
}) {
  final normalized = <Map<String, dynamic>>[];
  for (final worker in workers) {
    final id = worker.id.trim();
    final startCommand = worker.startCommand.trim();
    if (id.isEmpty || startCommand.isEmpty) {
      continue;
    }

    final entry = <String, dynamic>{
      'id': id,
      'name': worker.name.trim().isEmpty ? id : worker.name.trim(),
      'start_cmd': startCommand,
      'cpu_limit': worker.cpuLimit,
      'memory_mb': worker.memoryMb,
      'disk_mb': worker.diskMb,
      'enabled': worker.enabled,
    };

    final databaseUser = worker.databaseUser?.trim();
    final databaseName = worker.databaseName?.trim();
    final databasePassword = worker.databasePassword?.trim();
    final databaseEngine = worker.databaseEngine?.trim().toLowerCase();
    if (databaseUser != null &&
        databaseUser.isNotEmpty &&
        databaseName != null &&
        databaseName.isNotEmpty &&
        databasePassword != null &&
        databasePassword.isNotEmpty) {
      if (databaseEngine == null || databaseEngine == 'postgres') {
        entry['database_engine'] = 'postgres';
        entry['database_user'] = databaseUser;
        entry['database_name'] = databaseName;
        entry['database_password'] = databasePassword;
        entry['database_host'] = defaultDatabaseHost;
        entry['database_port'] = defaultDatabasePort;
      }
    }

    normalized.add(entry);
  }
  return normalized;
}

bool workerRuntimeSnapshotMatches({
  required List<ProjectWorkerInstance> workers,
  required WorkerRuntimeSnapshot snapshot,
}) {
  bool numericValueMatches(Object? value, num expected) {
    final parsed = double.tryParse(value?.toString() ?? '');
    return parsed != null && parsed == expected.toDouble();
  }

  if (workers.length != snapshot.configured.length) {
    return false;
  }
  final observedById = <String, Map<String, dynamic>>{
    for (final row in snapshot.configured)
      if ((row['id']?.toString().trim() ?? '').isNotEmpty)
        row['id'].toString().trim(): row,
  };
  for (final worker in workers) {
    final row = observedById[worker.id.trim()];
    if (row == null ||
        row['start_cmd']?.toString() != worker.startCommand ||
        row['enabled'] != worker.enabled ||
        !numericValueMatches(row['cpu_limit'], worker.cpuLimit) ||
        !numericValueMatches(row['memory_mb'], worker.memoryMb) ||
        !numericValueMatches(row['disk_mb'], worker.diskMb)) {
      return false;
    }
  }
  return true;
}
