import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/ui/terminal/github_deployment_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'deployment transcript renders only new timeline entries and completion',
    () {
      const running = GitHubIntegrationState(
        deployStatus: GitHubDeployStatus.buildingRelease,
        deployTimeline: [
          '[engine] Verify prerequisites and ensure Caddy is running | healthy',
        ],
      );
      const completed = GitHubIntegrationState(
        deployStatus: GitHubDeployStatus.success,
        deployTimeline: [
          '[engine] Verify prerequisites and ensure Caddy is running | healthy',
          '[engine] Sync repository, build image with Railpack, and run container | warning: cached layer',
        ],
      );

      final startingLines = githubDeploymentTerminalLinesForTransition(
        null,
        running,
      );
      final completionLines = githubDeploymentTerminalLinesForTransition(
        running,
        completed,
      );

      expect(startingLines.first.message, 'Starting web app deploy.');
      expect(startingLines.last.message, 'Verify prerequisites | healthy');
      expect(
        completionLines.first.message,
        'Build image & run container | warning: cached layer',
      );
      expect(
        completionLines.map((line) => line.message),
        contains('Web app deploy completed.'),
      );
      expect(
        completionLines.map((line) => line.message).join('\n'),
        contains(
          'Deploy summary: succeeded • timeline 2 lines • warnings 1 • errors 0',
        ),
      );
    },
  );

  test('deployment transcript keeps failure summary and status message', () {
    const running = GitHubIntegrationState(
      deployStatus: GitHubDeployStatus.buildingRelease,
    );
    const failed = GitHubIntegrationState(
      deployStatus: GitHubDeployStatus.error,
      statusMessage: 'Build failed.',
      deployTimeline: ['error: process exited'],
    );

    final lines = githubDeploymentTerminalLinesForTransition(running, failed);

    expect(
      lines.map((line) => line.message),
      contains(contains('Deploy summary: failed')),
    );
    expect(lines.last.message, 'Build failed.');
  });
}
