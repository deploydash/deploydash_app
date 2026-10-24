import 'package:ui/data/local/terminal_log_repository.dart';
import 'package:ui/services/runtime_log_settings.dart';
import 'package:ui/ui/project/workspace/logs/log_tab_logic.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TerminalLogRecord record(int id, String message) {
    return TerminalLogRecord(
      id: id,
      message: message,
      renderedLine: '[server] $message',
      source: 'app_deploy',
      taskType: 'app_deploy',
      createdAt: DateTime(2026, 8, 5, 10, 0, id),
    );
  }

  test('slugifyProjectName normalizes names and falls back', () {
    expect(slugifyProjectName('Alpha App'), 'alpha-app');
    expect(slugifyProjectName('   '), 'project-app');
  });

  test('buildRuntimeLogSettings preserves valid repo, branch, and port', () {
    const project = Project(
      id: 'project-1',
      name: 'Alpha App',
      type: 'Web app',
      gitUrl: 'https://github.com/example/alpha',
      primaryDomain: 'alpha.example.com',
      repositoryFullName: 'example/alpha',
      deployBranch: 'release/v1',
      appPort: 8080,
    );

    final settings = buildRuntimeLogSettings(project);

    expect(settings['project_slug'], 'alpha-app');
    expect(settings['repository_full_name'], 'example/alpha');
    expect(settings['branch'], 'release/v1');
    expect(settings['app_port'], 8080);
    expect(settings['primary_domain'], isNull);
  });

  test(
    'buildRuntimeLogSettings falls back for invalid repo, branch, and port',
    () {
      const project = Project(
        id: 'project-1',
        name: '  ',
        type: 'Web app',
        gitUrl: '',
        primaryDomain: 'alpha.example.com',
        repositoryFullName: 'bad repo',
        deployBranch: 'bad branch!',
        appPort: 70000,
      );

      final settings = buildRuntimeLogSettings(project);

      expect(settings['project_slug'], 'project-app');
      expect(settings['repository_full_name'], 'example-org/example-repo');
      expect(settings['branch'], 'main');
      expect(settings['app_port'], 3000);
    },
  );

  test('latest deployment attempt excludes older and control output', () {
    final latest = latestDeploymentAttemptLogs(<TerminalLogRecord>[
      record(1, 'Starting web app deploy.'),
      record(2, 'Old attempt failed.'),
      record(3, 'Starting web app deploy.'),
      record(
        4,
        '__DEPLOYDASH_REPOSITORY_HOST_KEY_CONFIRMATION__=encoded-secret',
      ),
      record(5, 'Deploy summary: succeeded'),
    ]);

    expect(latest.map((entry) => entry.id), <int>[3, 5]);
  });

  test('deployment outcome recognizes success, failure, and active output', () {
    expect(
      deploymentLogOutcome(<TerminalLogRecord>[
        record(1, 'Deploy summary: succeeded'),
      ])?.kind,
      DeploymentLogOutcomeKind.succeeded,
    );
    expect(
      deploymentLogOutcome(<TerminalLogRecord>[
        record(1, 'Candidate release did not pass readiness probes.'),
      ])?.kind,
      DeploymentLogOutcomeKind.failed,
    );
    final active = deploymentLogOutcome(<TerminalLogRecord>[
      record(1, 'Building image.'),
    ]);
    expect(active?.kind, DeploymentLogOutcomeKind.inProgress);
    expect(active?.label, 'Latest deployment activity');
    expect(deploymentLogOutcome(const <TerminalLogRecord>[]), isNull);
  });
}
