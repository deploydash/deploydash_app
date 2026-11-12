import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../../providers/worker_instance_provider.dart';
import '../../../../domain/worker_runtime_snapshot.dart';

export '../../../../domain/worker_runtime_snapshot.dart';

/// Fingerprint of a worker's environment for applied-state comparison.
///
/// The backend stamps the same hex digest on each snapshot row (see
/// `release_observability._environment_fingerprint`), so the desktop can
/// tell a changed environment from an applied one without values ever
/// travelling in status payloads. Canonical form: `key=value` lines for
/// keys in byte order, joined by `\n`. Keys are ASCII-only and values
/// never contain a newline (the backend rejects them), so the form is
/// unambiguous on both sides.
String workerEnvironmentFingerprint(Map<String, String> environment) {
  final keys = environment.keys.toList()..sort();
  final canonical = keys.map((key) => '$key=${environment[key]}').join('\n');
  return sha256.convert(utf8.encode(canonical)).toString();
}

List<Map<String, dynamic>> buildWorkersWorkflowPayload({
  required List<ProjectWorkerInstance> workers,
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

    if (worker.environment.isNotEmpty) {
      entry['environment'] = Map<String, String>.of(worker.environment);
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
    // A row without a fingerprint predates environment tracking and can
    // never match: one apply re-baselines it.
    final fingerprint = row?['environment_sha256']?.toString();
    if (row == null ||
        row['start_cmd']?.toString() != worker.startCommand ||
        row['enabled'] != worker.enabled ||
        !numericValueMatches(row['cpu_limit'], worker.cpuLimit) ||
        !numericValueMatches(row['memory_mb'], worker.memoryMb) ||
        !numericValueMatches(row['disk_mb'], worker.diskMb) ||
        fingerprint != workerEnvironmentFingerprint(worker.environment)) {
      return false;
    }
  }
  return true;
}
