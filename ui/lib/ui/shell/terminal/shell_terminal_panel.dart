import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/github_integration_provider.dart';
import '../../../providers/server_provider.dart';
import '../../../providers/server_terminal_transcript.dart'
    as server_transcript;
import '../../../providers/shell_terminal_provider.dart';
import '../../../providers/terminal_view_preferences_provider.dart';
import '../../terminal/github_deployment_transcript.dart' as github_transcript;
import '../../terminal/terminal_bottom_sheet.dart';

/// Renders the shell terminal from provider-owned output and queue sources.
class ShellTerminalPanel extends ConsumerWidget {
  const ShellTerminalPanel({super.key, required this.maxHeight});

  static const double reservedInset = TerminalBottomSheet.collapsedHeight + 12;

  final double maxHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final terminal = ref.watch(shellTerminalControllerProvider);
    final queueStreams = ref.watch(shellTerminalQueueStreamsProvider);
    final serverState = ref.watch(serverProvider);
    final gitHubState = ref.watch(gitHubIntegrationProvider);
    final showDetails = ref.watch(terminalDebugViewProvider);
    final isGitHubDeployRunning = isDeployStatusRunning(
      gitHubState.deployStatus,
    );

    ref.listen<ServerState>(serverProvider, (previous, next) {
      for (final line in server_transcript.serverTerminalLinesForTransition(
        previous,
        next,
      )) {
        terminal.writeLine(
          line.message,
          source: line.source,
          taskType: line.taskType,
          detail: line.detail,
        );
      }
    });
    ref.listen<GitHubIntegrationState>(gitHubIntegrationProvider, (
      previous,
      next,
    ) {
      for (final line
          in github_transcript.githubDeploymentTerminalLinesForTransition(
            previous,
            next,
          )) {
        terminal.writeLine(
          line.message,
          source: line.source,
          taskType: line.taskType,
        );
      }
    });

    return TerminalBottomSheet(
      outputStream: terminal.outputStream,
      queueStream: queueStreams.queueStream,
      queueMetricsStream: queueStreams.metricsStream,
      initialQueueSnapshot: queueStreams.initialQueueSnapshot,
      initialQueueMetrics: queueStreams.initialMetrics,
      showDetails: showDetails,
      onShowDetailsChanged: (enabled) {
        unawaited(
          ref.read(terminalDebugViewProvider.notifier).setEnabled(enabled),
        );
      },
      isTaskRunning: serverState.isLoading || isGitHubDeployRunning,
      expandForTask: isGitHubDeployRunning,
      maxHeight: maxHeight,
    );
  }
}
