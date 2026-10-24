import '../providers/server_provider.dart';
import '../utils/terminal_output_filter.dart';
import '../utils/trim_or_null.dart';

/// A terminal entry derived from a server-provider state transition.
class ServerTerminalLine {
  const ServerTerminalLine({
    required this.message,
    required this.source,
    required this.taskType,
    this.detail = false,
  });

  final String message;
  final String source;
  final String taskType;
  final bool detail;
}

/// Converts server workflow state changes to presentation-neutral terminal rows.
// D-84 (T-016): transition-loop twin recorded, not merged — this file guards
// the loading lifecycle and carries detail; the github twin guards deploy
// status with no detail field; completion builders differ; the shared
// startIndex skeleton (~3 lines) sits below the merge floor.
List<ServerTerminalLine> serverTerminalLinesForTransition(
  ServerState? previous,
  ServerState next,
) {
  final lines = <ServerTerminalLine>[];
  final wasLoading = previous?.isLoading ?? false;
  if (!wasLoading && next.isLoading) {
    if (next.taskType == ServerTaskType.setup) {
      lines.add(
        const ServerTerminalLine(
          message: 'Starting server setup tasks',
          source: 'engine',
          taskType: 'setup',
        ),
      );
    } else {
      lines.addAll(const [
        ServerTerminalLine(
          message: 'Starting server verification',
          source: 'engine',
          taskType: 'verification',
        ),
        ServerTerminalLine(
          message: 'Step 1/3: Connect to server via SSH',
          source: 'engine',
          taskType: 'verification',
        ),
      ]);
    }
  }

  final previousEvents = previous?.events ?? const <Map<String, dynamic>>[];
  final startIndex = next.events.length < previousEvents.length
      ? 0
      : previousEvents.length;
  for (var index = startIndex; index < next.events.length; index += 1) {
    final rendered = _terminalLineForServerEvent(
      next.events[index],
      next.taskType,
    );
    if (rendered != null) {
      lines.add(
        ServerTerminalLine(
          message: rendered.message,
          source: 'pyinfra',
          taskType: next.taskType.name,
          detail: rendered.detail,
        ),
      );
    }
  }

  if (wasLoading && !next.isLoading) {
    final succeeded = next.taskType == ServerTaskType.setup
        ? next.setupResult != null
        : next.result != null;
    if (succeeded) {
      if (next.taskType == ServerTaskType.setup) {
        lines.add(
          const ServerTerminalLine(
            message: 'Server setup completed.',
            source: 'engine',
            taskType: 'setup',
          ),
        );
        lines.add(
          ServerTerminalLine(
            message: _setupSummary(next, succeeded: true),
            source: 'engine',
            taskType: 'setup',
          ),
        );
      } else {
        lines.addAll([
          const ServerTerminalLine(
            message: 'Step 3/3: Finalize verification',
            source: 'engine',
            taskType: 'verification',
          ),
          const ServerTerminalLine(
            message: 'Verification complete.',
            source: 'engine',
            taskType: 'verification',
          ),
          ServerTerminalLine(
            message: serverVerificationSummaryTerminalMessage(
              next,
              succeeded: true,
            ),
            source: 'engine',
            taskType: 'verification',
          ),
        ]);
      }
    } else if (trimOrNull(next.error) case final errorMessage?) {
      if (next.taskType == ServerTaskType.setup) {
        lines.add(
          ServerTerminalLine(
            message: _setupSummary(next, succeeded: false),
            source: 'engine',
            taskType: 'setup',
          ),
        );
      } else if (next.taskType == ServerTaskType.verification) {
        lines.add(
          ServerTerminalLine(
            message: serverVerificationSummaryTerminalMessage(
              next,
              succeeded: false,
            ),
            source: 'engine',
            taskType: 'verification',
          ),
        );
      }
      lines.add(
        ServerTerminalLine(
          message: errorMessage,
          source: 'engine',
          taskType: next.taskType.name,
        ),
      );
    }
  }
  return lines;
}

String serverVerificationSummaryTerminalMessage(
  ServerState state, {
  required bool succeeded,
}) {
  final warnings = state.events
      .where((event) => event['level']?.toString().toLowerCase() == 'warning')
      .length;
  final errors = state.events
      .where((event) => event['level']?.toString().toLowerCase() == 'error')
      .length;
  final result = state.result ?? const <String, dynamic>{};
  final compatibility = result['compatibility'];
  final compatibilityStatus = compatibility is Map
      ? compatibility['status']?.toString().toLowerCase()
      : null;
  final failedChecks = compatibility is Map
      ? compatibility['failed_checks']
      : null;
  final failedCheckCount = failedChecks is List ? failedChecks.length : 0;
  final statusLabel = !succeeded
      ? 'failed'
      : compatibilityStatus == 'pass'
      ? 'passed'
      : 'blocked';
  final blockedDetails = statusLabel == 'blocked' && failedCheckCount > 0
      ? ' • failed checks $failedCheckCount'
      : '';
  final os = result['os']?.toString();
  final cpu = result['cpu']?.toString();
  final memoryMb = result['memory_mb'];
  final hardwareDetails =
      succeeded && os != null && cpu != null && memoryMb != null
      ? ' • $os • $cpu • ${memoryMb}MB RAM'
      : '';

  return 'Verification summary: $statusLabel$blockedDetails • '
      'warnings $warnings • errors $errors$hardwareDetails';
}

_RenderedServerTerminalLine? _terminalLineForServerEvent(
  Map<String, dynamic> event,
  ServerTaskType taskType,
) {
  final type = event['type']?.toString() ?? '';
  final message = event['message']?.toString().trim() ?? '';
  if (message.isEmpty) {
    return null;
  }

  if (taskType == ServerTaskType.verification && type == 'facts_start') {
    return const _RenderedServerTerminalLine('Step 2/3: Collect server facts');
  }
  if (taskType == ServerTaskType.verification && type == 'facts_collected') {
    return const _RenderedServerTerminalLine('Step 3/3: Finalize verification');
  }
  if (type == 'connection_error' || type == 'facts_error') {
    return _RenderedServerTerminalLine(withoutEventPrefix(message));
  }
  if (type == 'pyinfra_log' ||
      type == 'pyinfra_operation_stdout' ||
      type == 'pyinfra_operation_stderr') {
    return _RenderedServerTerminalLine(message, detail: true);
  }
  return _RenderedServerTerminalLine(
    withoutEventPrefix(message),
    detail: serverDetailEventTypes.contains(type),
  );
}

String _setupSummary(ServerState state, {required bool succeeded}) {
  final result = state.setupResult;
  final totalSteps = _listLength(result?['steps']);
  final completedSteps = _listLength(result?['completed_step_ids']);
  final totalActions = _listLength(result?['scheduled_action_ids']);
  final completedActions = _listLength(result?['completed_action_ids']);
  final warnings = _countEventsByLevel(state.events, 'warning');
  final errors = _countEventsByLevel(state.events, 'error');
  final statusLabel = succeeded ? 'succeeded' : 'failed';
  return 'Setup summary: $statusLabel • steps $completedSteps/$totalSteps • '
      'actions $completedActions/$totalActions • warnings $warnings • errors $errors';
}

int _listLength(Object? value) => value is List ? value.length : 0;

int _countEventsByLevel(List<Map<String, dynamic>> events, String level) {
  return events
      .where((event) => event['level']?.toString().toLowerCase() == level)
      .length;
}

class _RenderedServerTerminalLine {
  const _RenderedServerTerminalLine(this.message, {this.detail = false});

  final String message;
  final bool detail;
}
