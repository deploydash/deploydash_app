import 'package:ui/providers/worker_instance_provider.dart';
import 'package:ui/ui/project/workspace/workers/workers_tab_logic.dart';
import 'package:flutter_test/flutter_test.dart';

/// The worker tab's logic, exercised without pumping a widget.
///
/// Before T-3.3.6 these were private types inside a `part` of
/// `project_workspace.dart`, reachable only through the workspace widget. That
/// is the whole reason `*_logic.dart` files exist, so this file is what the
/// extraction was for.
void main() {
  ProjectWorkerInstance worker({
    String id = 'queue',
    bool enabled = true,
    Map<String, String>? environment,
  }) {
    return ProjectWorkerInstance(
      id: id,
      projectId: 'project-blog',
      name: 'Queue',
      startCommand: 'php artisan queue:work',
      cpuLimit: 0.5,
      memoryMb: 512,
      diskMb: 1024,
      environment:
          environment ??
          const {
            'DATABASE_URL': 'postgresql://db/one',
            'ANOTHER_KEY': 'another value',
          },
      enabled: enabled,
      sortOrder: 3,
    );
  }

  group('WorkerDraft', () {
    test('round-trips a persisted worker without losing a field', () {
      final original = worker();

      final restored = WorkerDraft.fromWorker(
        original,
      ).toWorkerInstance(projectId: original.projectId, sortOrder: 3);

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.startCommand, original.startCommand);
      expect(restored.cpuLimit, original.cpuLimit);
      expect(restored.memoryMb, original.memoryMb);
      expect(restored.diskMb, original.diskMb);
      expect(restored.environment, original.environment);
      expect(restored.enabled, original.enabled);
      expect(restored.sortOrder, 3);
    });

    test('copyWith replaces the environment only when passed', () {
      final draft = WorkerDraft.fromWorker(worker());

      expect(draft.copyWith(enabled: true).environment, draft.environment);
      expect(
        draft
            .copyWith(environment: const {'FRESH': '1'}, enabled: true)
            .environment,
        {'FRESH': '1'},
      );
    });

    test(
      'enabled is required on copyWith, so a toggle cannot be forgotten',
      () {
        final draft = WorkerDraft.fromWorker(worker());

        expect(draft.copyWith(enabled: false).enabled, isFalse);
        expect(draft.copyWith(enabled: true).enabled, isTrue);
      },
    );
  });

  group('parseWorkerEnvironmentVariables', () {
    test('parses one KEY=VALUE per line', () {
      const raw =
          'DATABASE_URL=postgresql://db/one\nANOTHER_KEY=another value\n';

      final result = parseWorkerEnvironmentVariables(raw);

      expect(result.error, isNull);
      expect(result.variables, {
        'DATABASE_URL': 'postgresql://db/one',
        'ANOTHER_KEY': 'another value',
      });
    });

    test('ignores blank lines and full-line comments', () {
      const raw = '\n  \n# connection string\nDATABASE_URL=x\n';

      final result = parseWorkerEnvironmentVariables(raw);

      expect(result.error, isNull);
      expect(result.variables, {'DATABASE_URL': 'x'});
    });

    test('trims padding and strips one pair of matching quotes', () {
      const raw =
          '  PADDED  =  spaced out  \n'
          'SINGLE=\'quoted\'\n'
          'DOUBLE="quoted"\n';

      final result = parseWorkerEnvironmentVariables(raw);

      expect(result.error, isNull);
      expect(result.variables, {
        'PADDED': 'spaced out',
        'SINGLE': 'quoted',
        'DOUBLE': 'quoted',
      });
    });

    test('keeps hashes and extra equals inside values literally', () {
      const raw = 'PASSWORD=abc#123\nCOMPLEX=a=b=c\n';

      final result = parseWorkerEnvironmentVariables(raw);

      expect(result.error, isNull);
      expect(result.variables, {'PASSWORD': 'abc#123', 'COMPLEX': 'a=b=c'});
    });

    test('an empty box parses to no variables', () {
      final result = parseWorkerEnvironmentVariables('  \n# nothing\n');

      expect(result.error, isNull);
      expect(result.variables, isEmpty);
    });

    test('a line without an equals sign fails naming its line', () {
      final result = parseWorkerEnvironmentVariables('GOOD=1\nJUST_A_KEY\n');

      expect(result.error, contains('Line 2'));
      expect(result.variables, {'GOOD': '1'});
    });

    test('an invalid key fails naming its line and key', () {
      for (final bad in ['9LIVES=x', 'HAS-DASH=x', '=x']) {
        final result = parseWorkerEnvironmentVariables('$bad\n');

        expect(result.error, contains('Line 1'), reason: bad);
      }
      final digitStart = parseWorkerEnvironmentVariables('9LIVES=x\n');

      expect(digitStart.error, contains('9LIVES'));
    });

    test('a repeated key fails naming its line and key', () {
      final result = parseWorkerEnvironmentVariables('KEY=one\nKEY=two\n');

      expect(result.error, contains('Line 2'));
      expect(result.error, contains('KEY'));
    });

    test('rendered variables re-parse to the same map', () {
      const variables = {
        'DATABASE_URL': 'postgresql://db/one',
        'PADDED': '  spaced out  ',
        'QUOTED': '"literal quotes"',
        'EMPTY': '',
      };

      final rendered = renderWorkerEnvironment(variables);
      final reparsed = parseWorkerEnvironmentVariables(rendered);

      expect(reparsed.error, isNull);
      expect(reparsed.variables, variables);
    });
  });

  group('nextWorkerId', () {
    test('slugifies the name', () {
      expect(nextWorkerId('Queue Worker', const <String>{}), 'queue-worker');
      expect(nextWorkerId('  Emails!  ', const <String>{}), 'emails');
    });

    test('suffixes until it no longer collides', () {
      expect(nextWorkerId('Queue', const <String>{'queue'}), 'queue-2');
      expect(
        nextWorkerId('Queue', const <String>{'queue', 'queue-2', 'queue-3'}),
        'queue-4',
      );
    });

    test('a name that slugifies to nothing still yields a usable id', () {
      // The id addresses the worker's container on the server, so an empty
      // one is not an option.
      expect(nextWorkerId('***', const <String>{}), 'worker');
      expect(nextWorkerId('', const <String>{'worker'}), 'worker-2');
    });
  });
}
