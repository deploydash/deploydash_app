import 'package:ui/providers/server_provider.dart';
import 'package:ui/providers/server_terminal_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'server transition emits verification start, event, and summary rows',
    () {
      final starting = ServerState(
        isLoading: true,
        taskType: ServerTaskType.verification,
      );
      final completed = ServerState(
        isLoading: false,
        taskType: ServerTaskType.verification,
        events: const [
          {
            'type': 'facts_start',
            'level': 'info',
            'message': '[engine] collecting facts',
          },
        ],
        result: const {
          'compatibility': {'status': 'pass'},
          'os': 'Ubuntu 24.04',
          'cpu': 'x86_64',
          'memory_mb': 4096,
        },
      );

      final startingLines = serverTerminalLinesForTransition(null, starting);
      final completionLines = serverTerminalLinesForTransition(
        starting,
        completed,
      );

      expect(startingLines.map((line) => line.message), [
        'Starting server verification',
        'Step 1/3: Connect to server via SSH',
      ]);
      expect(completionLines.first.message, 'Step 2/3: Collect server facts');
      expect(
        completionLines.map((line) => line.message),
        contains('Verification complete.'),
      );
      expect(
        completionLines.map((line) => line.message).join('\n'),
        contains('Verification summary: passed'),
      );
    },
  );

  test('server transition emits failed setup summary and error', () {
    final running = ServerState(
      isLoading: true,
      taskType: ServerTaskType.setup,
    );
    final failed = ServerState(
      isLoading: false,
      taskType: ServerTaskType.setup,
      error: 'Provisioning failed',
      events: const [
        {'level': 'warning'},
        {'level': 'error'},
      ],
    );

    final lines = serverTerminalLinesForTransition(running, failed);

    expect(lines.first.message, contains('Setup summary: failed'));
    expect(lines.last.message, 'Provisioning failed');
  });

  test('server event lines carry detail flags and stripped messages', () {
    // D-84 characterization: the server-5 detail set (pyinfra x3 via the
    // early arm + task x2 via the set) with the operation_schedule_decision
    // boundary pinned false (backup-6 only).
    final next = ServerState(
      isLoading: false,
      taskType: ServerTaskType.setup,
      events: const [
        {'type': 'task_started', 'message': '[engine] task began'},
        {'type': 'operation_schedule_decision', 'message': 'decision made'},
        {'type': 'connection_error', 'message': '[engine] boom'},
        {'type': 'pyinfra_log', 'message': 'raw stays'},
        {'type': 'task_finished', 'message': '[x] done'},
      ],
    );

    final lines = serverTerminalLinesForTransition(null, next);

    expect(lines.map((line) => (line.message, line.detail)).toList(), [
      ('task began', true),
      ('decision made', false),
      ('boom', false),
      ('raw stays', true),
      ('done', true),
    ]);
  });
}
