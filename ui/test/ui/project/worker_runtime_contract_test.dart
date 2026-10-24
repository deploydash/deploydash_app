import 'package:ui/providers/worker_instance_provider.dart';
import 'package:ui/ui/project/workspace/workers/worker_runtime_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildWorkersWorkflowPayload', () {
    test('builds normalized payload and includes database credentials', () {
      final payload = buildWorkersWorkflowPayload(
        workers: const [
          ProjectWorkerInstance(
            id: ' queue-worker ',
            projectId: 'project-a',
            name: ' Queue Worker ',
            startCommand: ' npm run worker:queue ',
            cpuLimit: 1.5,
            memoryMb: 512,
            diskMb: 2048,
            databaseUser: ' app_rw ',
            databaseName: ' app_db ',
            databasePassword: ' pw-123 ',
            enabled: true,
          ),
        ],
      );

      expect(payload, hasLength(1));
      expect(payload.first['id'], 'queue-worker');
      expect(payload.first['name'], 'Queue Worker');
      expect(payload.first['start_cmd'], 'npm run worker:queue');
      expect(payload.first['database_user'], 'app_rw');
      expect(payload.first['database_name'], 'app_db');
      expect(payload.first['database_password'], 'pw-123');
      expect(payload.first['database_host'], workerRuntimeDefaultDatabaseHost);
      expect(payload.first['database_port'], workerRuntimeDefaultDatabasePort);
    });

    test('omits invalid workers and partial database fields', () {
      final payload = buildWorkersWorkflowPayload(
        workers: const [
          ProjectWorkerInstance(
            id: 'worker-a',
            projectId: 'project-a',
            name: 'A',
            startCommand: 'npm run a',
            cpuLimit: 1,
            memoryMb: 256,
            diskMb: 1024,
            databaseUser: 'app_rw',
            databaseName: 'app_db',
            databasePassword: '',
          ),
          ProjectWorkerInstance(
            id: '',
            projectId: 'project-a',
            name: 'missing',
            startCommand: 'npm run missing',
            cpuLimit: 1,
            memoryMb: 256,
            diskMb: 1024,
          ),
        ],
      );

      expect(payload, hasLength(1));
      expect(payload.first['id'], 'worker-a');
      expect(payload.first.containsKey('database_user'), isFalse);
      expect(payload.first.containsKey('database_name'), isFalse);
      expect(payload.first.containsKey('database_password'), isFalse);
    });

    test('ignores unsupported database engines', () {
      final payload = buildWorkersWorkflowPayload(
        workers: const [
          ProjectWorkerInstance(
            id: 'vector-worker',
            projectId: 'project-a',
            name: 'Vector Worker',
            startCommand: 'python worker.py',
            cpuLimit: 1,
            memoryMb: 512,
            diskMb: 2048,
            databaseUser: 'vector_rw',
            databaseName: 'vector_db',
            databasePassword: 'secret',
            databaseEngine: 'other',
          ),
        ],
      );

      expect(payload, hasLength(1));
      expect(payload.first.containsKey('database_engine'), isFalse);
      expect(payload.first.containsKey('database_host'), isFalse);
      expect(payload.first.containsKey('database_port'), isFalse);
    });
  });

  group('WorkerRuntimeSnapshot', () {
    test('parses configured and orphan worker rows', () {
      final snapshot = WorkerRuntimeSnapshot.fromResponse({
        'workers': {
          'configured': [
            {
              'id': 'queue-worker',
              'runtime': {'state': 'running'},
            },
          ],
          'orphans': [
            {'container_name': 'deploydash_worker_project-old'},
          ],
        },
      });

      expect(snapshot.configured, hasLength(1));
      expect(snapshot.configured.first['id'], 'queue-worker');
      expect(snapshot.orphans, hasLength(1));
      expect(
        snapshot.orphans.first['container_name'],
        'deploydash_worker_project-old',
      );
    });

    test('returns empty for missing and malformed worker payloads', () {
      expect(WorkerRuntimeSnapshot.fromResponse(const {}).configured, isEmpty);
      expect(
        WorkerRuntimeSnapshot.fromResponse({
          'workers': <Object?, Object?>{
            'configured': <Object?>[
              <Object?, Object?>{'id': 'worker-a'},
              'ignored',
            ],
            'orphans': 'ignored',
          },
        }).configured,
        [
          <String, dynamic>{'id': 'worker-a'},
        ],
      );
    });
  });

  group('workerRuntimeSnapshotMatches', () {
    const worker = ProjectWorkerInstance(
      id: 'worker-a',
      projectId: 'project-a',
      name: 'Worker A',
      startCommand: 'php artisan queue:work',
      cpuLimit: 2,
      memoryMb: 1024,
      diskMb: 4096,
      enabled: true,
    );

    test('accepts normalized integer and decimal runtime values', () {
      final snapshot = WorkerRuntimeSnapshot.fromResponse({
        'workers': {
          'configured': [
            {
              'id': ' worker-a ',
              'start_cmd': 'php artisan queue:work',
              'enabled': true,
              'cpu_limit': '2.0',
              'memory_mb': 1024.0,
              'disk_mb': '4096',
            },
          ],
          'orphans': const <dynamic>[],
        },
      });

      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: snapshot,
        ),
        isTrue,
      );
    });

    test('rejects count, identity, configuration, and numeric drift', () {
      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: WorkerRuntimeSnapshot.empty,
        ),
        isFalse,
      );

      WorkerRuntimeSnapshot snapshotWith(Map<String, dynamic> row) {
        return WorkerRuntimeSnapshot(configured: [row], orphans: const []);
      }

      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: snapshotWith(const {'id': 'other'}),
        ),
        isFalse,
      );
      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: snapshotWith(const {
            'id': 'worker-a',
            'start_cmd': 'wrong',
            'enabled': true,
            'cpu_limit': 2,
            'memory_mb': 1024,
            'disk_mb': 4096,
          }),
        ),
        isFalse,
      );
      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: snapshotWith(const {
            'id': 'worker-a',
            'start_cmd': 'php artisan queue:work',
            'enabled': true,
            'cpu_limit': 'not-a-number',
            'memory_mb': 1024,
            'disk_mb': 4096,
          }),
        ),
        isFalse,
      );
    });
  });
}
