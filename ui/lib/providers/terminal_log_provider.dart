import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/terminal_log_repository.dart';

// Provider-layer persistence API used by log presentation helpers.
export '../data/local/terminal_log_repository.dart';

final terminalTranscriptActionsProvider = Provider<TerminalTranscriptActions>(
  TerminalTranscriptActions.new,
);

/// Owns terminal-log persistence independently of shell presentation.
class TerminalTranscriptActions {
  TerminalTranscriptActions(this._ref);

  final Ref _ref;

  Future<void> append({
    required String message,
    required String renderedLine,
    String? serverLabel,
    String? projectId,
    String? serverId,
    String source = 'terminal',
    String? taskType,
    DateTime? createdAt,
  }) {
    return _ref
        .read(terminalLogRepositoryProvider)
        .appendLog(
          message: message,
          renderedLine: renderedLine,
          serverLabel: serverLabel,
          projectId: projectId,
          serverId: serverId,
          source: source,
          taskType: taskType,
          createdAt: createdAt,
        );
  }
}
