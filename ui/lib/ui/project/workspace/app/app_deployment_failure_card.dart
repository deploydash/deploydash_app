import 'package:flutter/material.dart';

import '../../../../models/deploy_failure_evidence.dart';

// coverage-gate: app_deploy_failure_card
/// Maps an engine phase to stable, novice-facing language for failure UI.
String? deployFailurePhaseLabel(DeployFailurePhase phase) => switch (phase) {
  DeployFailurePhase.prepare => 'preparation',
  DeployFailurePhase.repositorySync => 'code download',
  DeployFailurePhase.build => 'build',
  DeployFailurePhase.candidateStart => 'app startup',
  DeployFailurePhase.candidateReadiness => 'app readiness check',
  DeployFailurePhase.trafficSwitch => 'traffic switch',
  DeployFailurePhase.postCutoverStabilization => 'public readiness check',
  DeployFailurePhase.rollback => 'rollback',
  DeployFailurePhase.engine => 'deployment',
  DeployFailurePhase.unknown => null,
};

/// Builds the honest heading without inventing a phase for unknown evidence.
String deployFailureHeading(DeployFailurePhase phase) {
  final phaseLabel = deployFailurePhaseLabel(phase);
  return phaseLabel == null
      ? 'Deployment stopped'
      : 'Deployment stopped during $phaseLabel';
}

/// Presents at most twelve already-sanitized lines, adding safe probe facts
/// only when the engine excerpt has room for them.
List<String> deployFailureOutputLines(DeployFailureEvidence evidence) {
  final lines = evidence.lines
      .take(deployFailureEvidenceMaxLines)
      .toList(growable: true);
  final probe = evidence.probe;
  if (probe == null || lines.length == deployFailureEvidenceMaxLines) {
    return List<String>.unmodifiable(lines);
  }
  final probeLines = <String>[
    if (probe.path != null) 'Probe path: ${probe.path}',
    if (probe.curlExit != null) 'Probe exit code: ${probe.curlExit}',
    if (probe.httpStatus != null) 'HTTP status: ${probe.httpStatus}',
  ];
  for (final line in probeLines) {
    if (lines.length == deployFailureEvidenceMaxLines) {
      break;
    }
    lines.add(line);
  }
  return List<String>.unmodifiable(lines);
}

/// Explains missing evidence according to the boundary the engine recovered.
String deployFailureFallbackMessage(DeployFailureEvidence evidence) {
  if (evidence.completeness == DeployFailureCompleteness.boundaryOnly) {
    final phaseLabel = deployFailurePhaseLabel(evidence.phase);
    return phaseLabel == null
        ? 'The deployment operation failed, but it did not return diagnostic output.'
        : 'The $phaseLabel operation failed, but it did not return diagnostic output.';
  }
  return 'The deployment ended before diagnostic output could be recovered.';
}

/// Builds the clipboard payload solely from typed, sanitized deploy state.
String deployFailureCopyDetails({
  required DeployFailureEvidence evidence,
  required String statusMessage,
}) {
  final details = <String>[deployFailureHeading(evidence.phase)];
  final normalizedStatus = statusMessage.trim();
  if (normalizedStatus.isNotEmpty) {
    details.add(normalizedStatus);
  }
  final outputLines = deployFailureOutputLines(evidence);
  if (evidence.completeness == DeployFailureCompleteness.diagnostic &&
      outputLines.isNotEmpty) {
    details
      ..add('Relevant failure output')
      ..addAll(outputLines);
  } else {
    details.add(deployFailureFallbackMessage(evidence));
  }
  return details.join('\n');
}

/// Shows one accessible, responsive summary of typed deploy failure evidence.
class AppDeployFailureCard extends StatelessWidget {
  /// Creates a card whose actions copy typed details and open the full logs.
  const AppDeployFailureCard({
    super.key,
    required this.evidence,
    required this.statusMessage,
    required this.onCopyDetails,
    required this.onOpenLogs,
    this.suggestedNextStep,
  });

  /// The project-scoped, sanitized evidence to present.
  final DeployFailureEvidence evidence;

  /// The normal failure status, copied with the evidence but shown above it.
  final String statusMessage;

  /// Copies the prepared text through the application's clipboard boundary.
  final Future<void> Function(String details) onCopyDetails;

  /// Opens the existing full deployment-log surface when available.
  final VoidCallback? onOpenLogs;

  /// Optional exact advice, visually separate from evidence and base status.
  final String? suggestedNextStep;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outputLines = deployFailureOutputLines(evidence);
    final showsDiagnosticOutput =
        evidence.completeness == DeployFailureCompleteness.diagnostic &&
        outputLines.isNotEmpty;
    final suggestedNextStep = this.suggestedNextStep?.trim();
    return Semantics(
      key: const Key('deploy-failure-card'),
      container: true,
      liveRegion: true,
      label: 'Deployment failure details',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
          border: Border.all(color: theme.colorScheme.error),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline,
                  color: theme.colorScheme.error,
                  semanticLabel: 'Deployment failed',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    deployFailureHeading(evidence.phase),
                    key: const Key('deploy-failure-heading'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (showsDiagnosticOutput) ...[
              Text(
                'Relevant failure output',
                style: theme.textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              Container(
                key: const Key('deploy-failure-output'),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  outputLines.join('\n'),
                  key: const Key('deploy-failure-output-text'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ] else
              Text(
                deployFailureFallbackMessage(evidence),
                key: const Key('deploy-failure-fallback'),
                style: theme.textTheme.bodySmall,
              ),
            if (suggestedNextStep != null && suggestedNextStep.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('Suggested next step', style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(
                suggestedNextStep,
                key: const Key('deploy-failure-suggested-next-step'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('deploy-failure-copy-button'),
                  onPressed: () async {
                    await onCopyDetails(
                      deployFailureCopyDetails(
                        evidence: evidence,
                        statusMessage: statusMessage,
                      ),
                    );
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Deployment details copied.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy details'),
                ),
                OutlinedButton.icon(
                  key: const Key('deploy-failure-open-logs-button'),
                  onPressed: onOpenLogs,
                  icon: const Icon(Icons.receipt_long, size: 16),
                  label: const Text('Open deployment logs'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
// end coverage-gate
