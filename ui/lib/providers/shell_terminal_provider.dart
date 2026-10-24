import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/terminal_stream_entry.dart';
import '../services/concurrency_engine.dart';
import '../utils/format_clock_time.dart';
import '../utils/terminal_output_filter.dart';
import 'project_provider.dart';
import 'server_list_provider.dart';
import 'server_provider.dart';
import 'terminal_log_provider.dart';

/// The terminal source and queue snapshots consumed by the shell panel.
final shellTerminalQueueStreamsProvider = Provider<ShellTerminalQueueStreams>((
  ref,
) {
  final sshService = ref.watch(sshServiceProvider);
  return ShellTerminalQueueStreams(
    queueStream: sshService.watchOperationQueue(),
    metricsStream: sshService.watchOperationMetrics(),
    initialQueueSnapshot: sshService.getOperationQueueSnapshot(),
    initialMetrics: sshService.getOperationMetricsSnapshot(),
  );
});

/// Stable operation-queue inputs for the rendered shell terminal.
class ShellTerminalQueueStreams {
  const ShellTerminalQueueStreams({
    required this.queueStream,
    required this.metricsStream,
    required this.initialQueueSnapshot,
    required this.initialMetrics,
  });

  final Stream<List<OperationQueueSnapshot>> queueStream;
  final Stream<OperationSchedulerMetricsSnapshot> metricsStream;
  final List<OperationQueueSnapshot> initialQueueSnapshot;
  final OperationSchedulerMetricsSnapshot initialMetrics;
}

/// Owns shell terminal output and persistence independently of [ShellPage].
final shellTerminalControllerProvider = Provider<ShellTerminalController>((
  ref,
) {
  final controller = ShellTerminalController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Writes presentation terminal lines to the shell stream and durable history.
class ShellTerminalController {
  ShellTerminalController(this._ref);

  final Ref _ref;
  final StreamController<TerminalStreamEntry> _outputController =
      StreamController<TerminalStreamEntry>.broadcast();
  var _isOnboarding = false;
  var _initialized = false;

  Stream<TerminalStreamEntry> get outputStream => _outputController.stream;

  /// Keeps context-sensitive terminal labels aligned with the active shell.
  void updateContext({required bool isOnboarding}) {
    _isOnboarding = isOnboarding;
  }

  /// Emits the one-time shell initialization line.
  void initialize() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    writeLine(
      '[info] Deploy Dash terminal initialized',
      source: 'ui',
      taskType: 'system',
    );
  }

  /// Renders, streams, and persists one non-control terminal line.
  void writeLine(
    String line, {
    String source = 'terminal',
    String? taskType,
    bool detail = false,
  }) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || isInternalTerminalControlLine(trimmed)) {
      return;
    }
    final now = DateTime.now();
    final timestamp = formatClockTime(now);
    final serverLabel = _currentServerLabel();
    final selectedProject = _ref.read(selectedProjectProvider);
    final selectedServer = _ref.read(selectedServerProvider);
    final renderedLine = '[$serverLabel $timestamp] $trimmed';
    _outputController.add(
      TerminalStreamEntry(
        renderedLine,
        isDetail:
            detail ||
            isTechnicalTerminalActivity(
              message: trimmed,
              source: source,
              taskType: taskType,
            ),
      ),
    );
    unawaited(
      _ref
          .read(terminalTranscriptActionsProvider)
          .append(
            message: trimmed,
            renderedLine: renderedLine,
            projectId: selectedProject?.id,
            serverId: selectedServer?.id,
            serverLabel: serverLabel,
            source: source,
            taskType: taskType,
            createdAt: now,
          ),
    );
  }

  String _currentServerLabel() {
    final catalog = _ref.read(serverCatalogProvider);
    if (_isOnboarding || !catalog.hasServers) {
      return 'New Server';
    }
    final selectedName = catalog.selectedServer?.name.trim() ?? '';
    return selectedName.isEmpty ? 'Server' : selectedName;
  }

  void dispose() {
    _outputController.close();
  }
}
