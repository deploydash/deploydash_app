import '../../../../providers/terminal_log_provider.dart';
import '../../../../utils/terminal_output_filter.dart';

List<TerminalLogRecord> latestDeploymentAttemptLogs(
  List<TerminalLogRecord> records,
) {
  final safeRecords = records
      .where((record) => !isInternalTerminalControlLine(record.message))
      .toList(growable: false);
  var latestStart = -1;
  for (var index = 0; index < safeRecords.length; index += 1) {
    final message = safeRecords[index].message.trim().toLowerCase();
    if (message == 'starting web app deploy.' ||
        message == 'starting web app deploy') {
      latestStart = index;
    }
  }
  if (latestStart < 0) {
    return safeRecords;
  }
  return safeRecords.sublist(latestStart);
}

enum DeploymentLogOutcomeKind { succeeded, failed, inProgress }

class DeploymentLogOutcome {
  const DeploymentLogOutcome({required this.kind, required this.details});

  final DeploymentLogOutcomeKind kind;
  final String details;

  String get label => switch (kind) {
    DeploymentLogOutcomeKind.succeeded => 'Latest deployment succeeded',
    DeploymentLogOutcomeKind.failed => 'Latest deployment failed',
    DeploymentLogOutcomeKind.inProgress => 'Latest deployment activity',
  };
}

DeploymentLogOutcome? deploymentLogOutcome(List<TerminalLogRecord> records) {
  if (records.isEmpty) {
    return null;
  }
  for (final record in records.reversed) {
    final message = record.message.trim();
    final normalized = message.toLowerCase();
    if (normalized.contains('deploy summary: succeeded') ||
        normalized == 'web app deploy completed.') {
      return DeploymentLogOutcome(
        kind: DeploymentLogOutcomeKind.succeeded,
        details: message,
      );
    }
    if (normalized.contains('deploy summary: failed') ||
        normalized.contains('candidate release did not pass readiness') ||
        normalized == 'web app deploy failed.') {
      return DeploymentLogOutcome(
        kind: DeploymentLogOutcomeKind.failed,
        details: message,
      );
    }
  }
  return DeploymentLogOutcome(
    kind: DeploymentLogOutcomeKind.inProgress,
    details: records.last.message.trim(),
  );
}
