import 'package:ui/utils/terminal_output_filter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('internal terminal control lines are rejected', () {
    expect(
      isInternalTerminalControlLine(
        '__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=payload',
      ),
      isTrue,
    );
    expect(
      isInternalTerminalControlLine(
        '{"repository_host_key_confirmation_required":true}',
      ),
      isTrue,
    );
    expect(
      isInternalTerminalControlLine(
        '{"repository_host_key_confirmation":{"host":"github.com"}}',
      ),
      isTrue,
    );
    expect(
      isInternalTerminalControlLine(
        'APP_REPOSITORY_HOST_KEY_CONFIRMATION_REQUIRED',
      ),
      isTrue,
    );
    expect(isInternalTerminalControlLine('Deployment completed.'), isFalse);
  });

  test('only UI navigation is classified as technical activity', () {
    expect(
      isTechnicalNavigationActivity(source: 'ui', taskType: 'navigation'),
      isTrue,
    );
    expect(
      isTechnicalNavigationActivity(source: 'engine', taskType: 'navigation'),
      isFalse,
    );
    expect(
      isTechnicalNavigationActivity(source: 'ui', taskType: 'app_deploy'),
      isFalse,
    );
  });

  test('terminal lifecycle plumbing is classified across workspaces', () {
    expect(
      isTechnicalTerminalActivity(
        message: 'Opening selected project workspace',
        source: 'ui',
        taskType: 'navigation',
      ),
      isTrue,
    );
    for (final source in <String>[
      'services:task_started',
      'updates:task_finished',
      'firewall:operation_schedule_decision',
      'services:connection_start',
      'services:connection_ready',
      'pyinfra:pyinfra_host_before_connect',
      'pyinfra:pyinfra_host_connected',
      'pyinfra:pyinfra_host_disconnected',
      'pyinfra:pyinfra_log',
      'pyinfra:pyinfra_operation_stdout',
      'pyinfra:pyinfra_operation_stderr',
      'firewall:firewall_runtime_plan_ready',
    ]) {
      expect(
        isTechnicalTerminalActivity(
          message: 'Technical event',
          source: source,
          taskType: 'status',
        ),
        isTrue,
        reason: source,
      );
    }
  });

  test('generic lifecycle messages are technical without event metadata', () {
    for (final message in <String>[
      'Operation accepted.',
      'Connection established.',
      'Task completed',
      'Task completed.',
      'Connected to 10.147.160.96',
      'Connecting to 10.147.160.96:22 as ubuntu',
      'Disconnected from 10.147.160.96',
      'Preparing connection for 10.147.160.96',
      "Runtime operation 'status' prepared.",
    ]) {
      expect(
        isTechnicalTerminalActivity(
          message: message,
          source: 'services',
          taskType: 'status',
        ),
        isTrue,
        reason: message,
      );
    }
    expect(
      isTechnicalTerminalActivity(
        message: 'PostgreSQL is ready.',
        source: 'services',
        taskType: 'status',
      ),
      isFalse,
    );
  });

  test('withoutEventPrefix strips one bracketed prefix and trims', () {
    expect(withoutEventPrefix('[engine] collecting facts'), 'collecting facts');
    expect(withoutEventPrefix('[engine]  spaced  '), 'spaced');
    expect(withoutEventPrefix('no prefix here'), 'no prefix here');
    expect(withoutEventPrefix('  padded  '), 'padded');
    expect(withoutEventPrefix(''), '');
    expect(withoutEventPrefix('   '), '');
    expect(withoutEventPrefix('[a] [b] kept'), '[b] kept');
  });

  test(
    'detail vocabulary nests service-3 ⊂ server-5 ⊂ backup-6 ⊂ technical',
    () {
      // D-84 subset proof: each level equals the exact literal set it
      // replaces, and each level differs from the next by exactly the atoms
      // the ticket's nesting proof names.
      expect(serviceDetailEventTypes, {
        'pyinfra_log',
        'pyinfra_operation_stdout',
        'pyinfra_operation_stderr',
      });
      expect(serverDetailEventTypes.difference(serviceDetailEventTypes), {
        'task_started',
        'task_finished',
      });
      expect(backupDetailEventTypes.difference(serverDetailEventTypes), {
        'operation_schedule_decision',
      });
      expect(technicalDetailEventTypes.difference(backupDetailEventTypes), {
        'connection_ready',
        'connection_start',
        'pyinfra_host_before_connect',
        'pyinfra_host_connected',
        'pyinfra_host_disconnected',
      });
      expect(serviceDetailEventTypes.length, 3);
      expect(serverDetailEventTypes.length, 5);
      expect(backupDetailEventTypes.length, 6);
      expect(technicalDetailEventTypes.length, 11);
    },
  );
}
