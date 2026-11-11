import 'package:ui/providers/worker_instance_provider.dart';
import 'package:ui/ui/project/workspace/workers/worker_runtime_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildWorkersWorkflowPayload', () {
    test('builds normalized payload and includes the environment map', () {
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
            environment: {
              'DATABASE_URL': 'postgresql://db/one',
              'ANOTHER_KEY': 'another value',
            },
            enabled: true,
          ),
        ],
      );

      expect(payload, hasLength(1));
      expect(payload.first['id'], 'queue-worker');
      expect(payload.first['name'], 'Queue Worker');
      expect(payload.first['start_cmd'], 'npm run worker:queue');
      expect(payload.first['environment'], {
        'DATABASE_URL': 'postgresql://db/one',
        'ANOTHER_KEY': 'another value',
      });
    });

    test('omits invalid workers and the environment key when empty', () {
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
      expect(payload.first.containsKey('environment'), isFalse);
    });
  });

  group('workerEnvironmentFingerprint', () {
    test('matches the backend digest for a fixed map', () {
      // Pinned on both sides: the backend stamps this same literal in
      // release_observability tests. If either side drifts, applied
      // workers read as unapplied (or the reverse).
      expect(
        workerEnvironmentFingerprint(const {
          'DATABASE_URL': 'postgresql://db/one',
          'ANOTHER_KEY': 'another value',
        }),
        'f6e3eb4119824e891c0d2400c6fe70a6d70ed08717be466167aabf4dc0f4108d',
      );
    });

    test('is order-independent and empty-aware', () {
      expect(
        workerEnvironmentFingerprint(const {'B': '2', 'A': '1'}),
        workerEnvironmentFingerprint(const {'A': '1', 'B': '2'}),
      );
      expect(
        workerEnvironmentFingerprint(const {}),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
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
              'environment_sha256':
                  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
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

    Map<String, String>? fingerprintEntry(String? fingerprint) {
      if (fingerprint == null) {
        return null;
      }
      return {'environment_sha256': fingerprint};
    }

    test('rejects environment drift and fingerprint-less rows', () {
      WorkerRuntimeSnapshot snapshotWith(String? fingerprint) {
        return WorkerRuntimeSnapshot.fromResponse({
          'workers': {
            'configured': [
              {
                'id': 'worker-a',
                'start_cmd': 'php artisan queue:work',
                'enabled': true,
                'cpu_limit': 2,
                'memory_mb': 1024,
                'disk_mb': 4096,
                ...?fingerprintEntry(fingerprint),
              },
            ],
            'orphans': const <dynamic>[],
          },
        });
      }

      const changed = ProjectWorkerInstance(
        id: 'worker-a',
        projectId: 'project-a',
        name: 'Worker A',
        startCommand: 'php artisan queue:work',
        cpuLimit: 2,
        memoryMb: 1024,
        diskMb: 4096,
        enabled: true,
        environment: {'DATABASE_URL': 'postgresql://db/one'},
      );

      // The row's fingerprint is for an empty environment; the worker now
      // carries a variable, so it reads as unapplied.
      expect(
        workerRuntimeSnapshotMatches(
          workers: const [changed],
          snapshot: snapshotWith(
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          ),
        ),
        isFalse,
      );
      // A row without any fingerprint predates tracking entirely.
      expect(
        workerRuntimeSnapshotMatches(
          workers: const [worker],
          snapshot: snapshotWith(null),
        ),
        isFalse,
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
      // Fingerprints below match the worker's empty environment, so each
      // rejection below pins its named reason rather than the fingerprint.
      const emptyFingerprint =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
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
            'environment_sha256': emptyFingerprint,
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
            'environment_sha256': emptyFingerprint,
          }),
        ),
        isFalse,
      );
    });
  });
}
