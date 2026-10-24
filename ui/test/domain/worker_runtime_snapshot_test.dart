import 'package:ui/domain/worker_runtime_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WorkerRuntimeSnapshot normalizes configured and orphaned workers', () {
    final snapshot = WorkerRuntimeSnapshot.fromResponse({
      'workers': {
        'configured': [
          {'id': 'worker-1'},
        ],
        'orphans': [
          {'id': 2},
        ],
      },
    });

    expect(snapshot.configured, [
      {'id': 'worker-1'},
    ]);
    expect(snapshot.orphans, [
      {'id': 2},
    ]);
  });
}
