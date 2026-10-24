import '../../providers/github_integration_provider.dart';
import '../../utils/terminal_output_filter.dart';
import 'deploy_timeline_summary.dart';

/// A terminal entry derived from a GitHub deployment state transition.
class GitHubDeploymentTerminalLine {
  const GitHubDeploymentTerminalLine({
    required this.message,
    required this.source,
    required this.taskType,
  });

  final String message;
  final String source;
  final String taskType;
}

/// Converts deployment-state changes into terminal rows outside ShellPage.
// D-84 (T-016): transition-loop twin recorded, not merged — this file guards
// deploy status with no detail field; the server twin guards the loading
// lifecycle and carries detail; completion builders differ; the shared
// startIndex skeleton (~3 lines) sits below the merge floor.
List<GitHubDeploymentTerminalLine> githubDeploymentTerminalLinesForTransition(
  GitHubIntegrationState? previous,
  GitHubIntegrationState next,
) {
  final lines = <GitHubDeploymentTerminalLine>[];
  final previousStatus = previous?.deployStatus ?? GitHubDeployStatus.idle;
  final wasRunning = isDeployStatusRunning(previousStatus);
  final isRunning = isDeployStatusRunning(next.deployStatus);

  if (!wasRunning && isRunning) {
    lines.add(
      const GitHubDeploymentTerminalLine(
        message: 'Starting web app deploy.',
        source: 'engine',
        taskType: 'app_deploy',
      ),
    );
  }

  final previousTimeline = previous?.deployTimeline ?? const <String>[];
  final startIndex = next.deployTimeline.length < previousTimeline.length
      ? 0
      : previousTimeline.length;
  for (var index = startIndex; index < next.deployTimeline.length; index += 1) {
    final line = _compactDeployTimelineLine(next.deployTimeline[index]);
    if (line.isEmpty) {
      continue;
    }
    lines.add(
      GitHubDeploymentTerminalLine(
        message: line,
        source: 'app_deploy',
        taskType: 'app_deploy',
      ),
    );
  }

  if (wasRunning && !isRunning) {
    if (next.deployStatus == GitHubDeployStatus.success) {
      lines.addAll([
        const GitHubDeploymentTerminalLine(
          message: 'Web app deploy completed.',
          source: 'engine',
          taskType: 'app_deploy',
        ),
        GitHubDeploymentTerminalLine(
          message: formatGitHubDeploySummaryTerminalMessage(next),
          source: 'engine',
          taskType: 'app_deploy',
        ),
      ]);
    } else if (next.deployStatus == GitHubDeployStatus.error) {
      lines.addAll([
        GitHubDeploymentTerminalLine(
          message: formatGitHubDeploySummaryTerminalMessage(next),
          source: 'engine',
          taskType: 'app_deploy',
        ),
        GitHubDeploymentTerminalLine(
          message: next.statusMessage,
          source: 'engine',
          taskType: 'app_deploy',
        ),
      ]);
    }
  }
  return lines;
}

String formatGitHubDeploySummaryTerminalMessage(GitHubIntegrationState state) {
  final status = state.deployStatus == GitHubDeployStatus.success
      ? 'succeeded'
      : 'failed';
  final summary = summarizeDeployTimeline(
    succeeded: state.deployStatus == GitHubDeployStatus.success,
    timeline: state.deployTimeline,
  );

  return 'Deploy summary: $status • timeline ${state.deployTimeline.length} '
      'lines • warnings ${summary.warningCount} • errors ${summary.errorCount}';
}

String _compactDeployTimelineLine(String input) {
  final compact = withoutEventPrefix(input);
  if (isInternalTerminalControlLine(compact)) {
    return '';
  }
  final pipeIndex = compact.indexOf(' | ');
  if (pipeIndex <= 0) {
    return compact;
  }

  final step = compact.substring(0, pipeIndex).trim();
  final details = compact.substring(pipeIndex + 3).trim();
  final compactStep = _compactDeployStep(step);
  if (details.isEmpty) {
    return compactStep;
  }
  return '$compactStep | $details';
}

String _compactDeployStep(String input) {
  final step = input.trim();
  final normalized = step.toLowerCase();
  if (normalized ==
      'sync repository, build image with railpack, and run container') {
    return 'Build image & run container';
  }
  if (normalized == 'publish app through caddy over http and https') {
    return 'Publish via Caddy';
  }
  if (normalized == 'verify prerequisites and ensure caddy is running') {
    return 'Verify prerequisites';
  }
  return step;
}
