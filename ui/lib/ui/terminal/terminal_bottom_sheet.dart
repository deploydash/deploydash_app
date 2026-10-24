import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/terminal_stream_entry.dart';
import '../../services/concurrency_engine.dart';
import '../../utils/format_clock_time.dart';
import '../system/operation_state_presentation.dart';

export '../../models/terminal_stream_entry.dart';

class TerminalBottomSheet extends StatefulWidget {
  const TerminalBottomSheet({
    super.key,
    this.outputStream,
    this.queueStream,
    this.queueMetricsStream,
    this.initialQueueSnapshot = const <OperationQueueSnapshot>[],
    this.initialQueueMetrics,
    this.showDetails = false,
    this.onShowDetailsChanged,
    this.isTaskRunning = false,
    this.expandForTask = false,
    this.initialHeight = 220,
    this.minHeight = 140,
    this.maxHeight = 420,
  });

  static const double collapsedHeight = 40.0;

  final Stream<TerminalStreamEntry>? outputStream;
  final Stream<List<OperationQueueSnapshot>>? queueStream;
  final Stream<OperationSchedulerMetricsSnapshot>? queueMetricsStream;
  final List<OperationQueueSnapshot> initialQueueSnapshot;
  final OperationSchedulerMetricsSnapshot? initialQueueMetrics;
  final bool showDetails;
  final ValueChanged<bool>? onShowDetailsChanged;
  final bool isTaskRunning;
  final bool expandForTask;
  final double initialHeight;
  final double minHeight;
  final double maxHeight;

  @override
  State<TerminalBottomSheet> createState() => _TerminalBottomSheetState();
}

enum _TerminalPanelTab { terminal, queue }

class _TerminalBottomSheetState extends State<TerminalBottomSheet> {
  static const _aubergine = Color(0xff380c2a);
  static const _collapsedHeight = TerminalBottomSheet.collapsedHeight;
  static const _terminalBottomTolerance = 24.0;

  late final ScrollController _terminalScrollController;
  late final ScrollController _queueScrollController;
  StreamSubscription<TerminalStreamEntry>? _outputSubscription;
  StreamSubscription<List<OperationQueueSnapshot>>? _queueSubscription;
  StreamSubscription<OperationSchedulerMetricsSnapshot>? _metricsSubscription;
  late double _height;
  double? _lastExpandedHeight;
  double? _heightBeforeMaximize;
  bool _isCollapsed = true;
  bool _showDetails = false;
  bool _shouldFollowTerminalBottom = true;
  _TerminalPanelTab _activeTab = _TerminalPanelTab.terminal;
  String _latestOutput = 'Advanced activity is ready.';
  final List<TerminalStreamEntry> _outputHistory = <TerminalStreamEntry>[];
  List<OperationQueueSnapshot> _queueSnapshots = <OperationQueueSnapshot>[];
  OperationSchedulerMetricsSnapshot _queueMetrics =
      OperationSchedulerMetricsSnapshot.empty();

  @override
  void initState() {
    super.initState();
    _height = widget.initialHeight.clamp(widget.minHeight, widget.maxHeight);
    _showDetails = widget.showDetails;
    _terminalScrollController = ScrollController();
    _terminalScrollController.addListener(
      _updateTerminalFollowBottomFromPosition,
    );
    _queueScrollController = ScrollController();
    _queueSnapshots = List<OperationQueueSnapshot>.from(
      widget.initialQueueSnapshot,
      growable: false,
    );
    _queueMetrics =
        widget.initialQueueMetrics ?? OperationSchedulerMetricsSnapshot.empty();
    _listenToOutput(widget.outputStream);
    _listenToQueue(widget.queueStream);
    _listenToMetrics(widget.queueMetricsStream);
  }

  @override
  void didUpdateWidget(covariant TerminalBottomSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.outputStream != widget.outputStream) {
      _listenToOutput(widget.outputStream);
    }
    if (oldWidget.queueStream != widget.queueStream) {
      _listenToQueue(widget.queueStream);
    }
    if (oldWidget.queueMetricsStream != widget.queueMetricsStream) {
      _listenToMetrics(widget.queueMetricsStream);
    }
    if (oldWidget.initialQueueSnapshot != widget.initialQueueSnapshot &&
        widget.queueStream == null) {
      setState(() {
        _queueSnapshots = List<OperationQueueSnapshot>.from(
          widget.initialQueueSnapshot,
          growable: false,
        );
      });
    }
    if (oldWidget.initialQueueMetrics != widget.initialQueueMetrics &&
        widget.queueMetricsStream == null) {
      setState(() {
        _queueMetrics =
            widget.initialQueueMetrics ??
            OperationSchedulerMetricsSnapshot.empty();
      });
    }
    if (oldWidget.showDetails != widget.showDetails &&
        widget.showDetails != _showDetails) {
      final shouldFollowBottom = _shouldFollowTerminalBottom;
      setState(() {
        _showDetails = widget.showDetails;
        _syncLatestOutputFromVisibleHistory();
      });
      _scheduleTerminalScrollToBottomIfNeeded(shouldFollowBottom);
    }
    if (!oldWidget.expandForTask && widget.expandForTask && _isCollapsed) {
      _shouldFollowTerminalBottom = true;
      setState(() {
        _isCollapsed = false;
        _height = (_lastExpandedHeight ?? widget.initialHeight).clamp(
          widget.minHeight,
          widget.maxHeight,
        );
      });
      _scheduleTerminalScrollToBottom();
    }
  }

  @override
  void dispose() {
    _outputSubscription?.cancel();
    _queueSubscription?.cancel();
    _metricsSubscription?.cancel();
    _terminalScrollController.removeListener(
      _updateTerminalFollowBottomFromPosition,
    );
    _terminalScrollController.dispose();
    _queueScrollController.dispose();
    super.dispose();
  }

  void _listenToOutput(Stream<TerminalStreamEntry>? stream) {
    _outputSubscription?.cancel();
    if (stream == null) {
      _outputSubscription = null;
      return;
    }

    _outputSubscription = stream.listen(_writeOutput);
  }

  void _listenToQueue(Stream<List<OperationQueueSnapshot>>? stream) {
    _queueSubscription?.cancel();
    if (stream == null) {
      _queueSubscription = null;
      return;
    }

    _queueSubscription = stream.listen((snapshot) {
      final normalized = List<OperationQueueSnapshot>.from(snapshot);
      setState(() {
        _queueSnapshots = normalized;
      });
    });
  }

  void _listenToMetrics(Stream<OperationSchedulerMetricsSnapshot>? stream) {
    _metricsSubscription?.cancel();
    if (stream == null) {
      _metricsSubscription = null;
      return;
    }

    _metricsSubscription = stream.listen((snapshot) {
      setState(() {
        _queueMetrics = snapshot;
      });
    });
  }

  bool _isEntryVisible(TerminalStreamEntry entry) {
    return _showDetails || !entry.isDetail;
  }

  List<String> _visibleHistory() {
    return _outputHistory
        .where(_isEntryVisible)
        .map((entry) => entry.message)
        .toList(growable: false);
  }

  String _lastSummaryOutput() {
    for (int i = _outputHistory.length - 1; i >= 0; i -= 1) {
      final entry = _outputHistory[i];
      if (!entry.isDetail) {
        return entry.message;
      }
    }
    return 'Advanced activity is ready.';
  }

  void _syncLatestOutputFromVisibleHistory() {
    _latestOutput = _lastSummaryOutput();
  }

  String _visibleOutputText() {
    final lines = _visibleHistory();
    if (lines.isEmpty) {
      return 'No activity yet.';
    }
    return lines.join('\n');
  }

  bool _isTerminalNearBottom() {
    if (!_terminalScrollController.hasClients) {
      return true;
    }
    final position = _terminalScrollController.position;
    return position.maxScrollExtent - position.pixels <=
        _terminalBottomTolerance;
  }

  void _updateTerminalFollowBottomFromPosition() {
    _shouldFollowTerminalBottom = _isTerminalNearBottom();
  }

  void _scheduleTerminalScrollToBottomIfNeeded(bool shouldFollowBottom) {
    if (!shouldFollowBottom) {
      return;
    }
    _scheduleTerminalScrollToBottom();
  }

  void _scheduleTerminalScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_terminalScrollController.hasClients) {
        return;
      }
      final position = _terminalScrollController.position;
      final target = position.maxScrollExtent;
      _terminalScrollController.jumpTo(target);
    });
  }

  void _writeOutput(TerminalStreamEntry entry) {
    final output = entry.message.trim();
    if (output.isEmpty) {
      return;
    }

    final normalizedEntry = TerminalStreamEntry(
      output,
      isDetail: entry.isDetail,
    );
    _outputHistory.add(normalizedEntry);
    if (_outputHistory.length > 5000) {
      _outputHistory.removeAt(0);
    }

    if (!_isEntryVisible(normalizedEntry)) {
      return;
    }

    final shouldFollowBottom = _shouldFollowTerminalBottom;
    setState(() {
      if (!normalizedEntry.isDetail) {
        _latestOutput = output;
      }
    });
    _scheduleTerminalScrollToBottomIfNeeded(shouldFollowBottom);
  }

  Future<void> _copyTerminalOutput() async {
    final lines = _visibleHistory();
    if (lines.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Activity copied')));
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final shouldFollowBottom = _shouldFollowTerminalBottom;
    setState(() {
      _isCollapsed = false;
      _heightBeforeMaximize = null;
      _height = (_height - details.delta.dy).clamp(
        widget.minHeight,
        widget.maxHeight,
      );
      _lastExpandedHeight = _height;
    });
    _scheduleTerminalScrollToBottomIfNeeded(shouldFollowBottom);
  }

  void _toggleCollapsed() {
    final wasCollapsed = _isCollapsed;
    setState(() {
      if (_isCollapsed) {
        _isCollapsed = false;
        _height = (_lastExpandedHeight ?? widget.initialHeight).clamp(
          widget.minHeight,
          widget.maxHeight,
        );
      } else {
        _lastExpandedHeight = _height;
        _heightBeforeMaximize = null;
        _isCollapsed = true;
      }
    });
    if (wasCollapsed) {
      _shouldFollowTerminalBottom = true;
      _scheduleTerminalScrollToBottom();
    }
  }

  void _maximize() {
    final isAtMaxHeight = (_height - widget.maxHeight).abs() < 0.01;
    // Hoisted so the `!= null` check promotes it; a State field is never
    // promoted.
    final heightBeforeMaximize = _heightBeforeMaximize;
    _shouldFollowTerminalBottom = true;
    setState(() {
      if (!_isCollapsed && isAtMaxHeight && heightBeforeMaximize != null) {
        _height = heightBeforeMaximize.clamp(
          widget.minHeight,
          widget.maxHeight,
        );
        _lastExpandedHeight = _height;
        _heightBeforeMaximize = null;
        return;
      }

      _heightBeforeMaximize = _isCollapsed
          ? (_lastExpandedHeight ?? widget.initialHeight).clamp(
              widget.minHeight,
              widget.maxHeight,
            )
          : _height.clamp(widget.minHeight, widget.maxHeight);
      _isCollapsed = false;
      _height = widget.maxHeight;
      _lastExpandedHeight = _height;
    });
    _scheduleTerminalScrollToBottom();
  }

  void _toggleDetails() {
    final nextValue = !_showDetails;
    final shouldFollowBottom = _shouldFollowTerminalBottom;
    setState(() {
      _showDetails = nextValue;
      _syncLatestOutputFromVisibleHistory();
    });
    _scheduleTerminalScrollToBottomIfNeeded(shouldFollowBottom);
    widget.onShowDetailsChanged?.call(nextValue);
  }

  void _clearTerminalOutput() {
    _shouldFollowTerminalBottom = true;
    setState(() {
      _outputHistory.clear();
      _latestOutput = 'Activity cleared.';
    });
    _scheduleTerminalScrollToBottom();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Activity cleared')));
  }

  void _setActiveTab(_TerminalPanelTab tab) {
    if (_activeTab == tab) {
      return;
    }
    setState(() {
      _activeTab = tab;
    });
    if (tab == _TerminalPanelTab.terminal) {
      _scheduleTerminalScrollToBottomIfNeeded(_shouldFollowTerminalBottom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAtMaxHeight =
        !_isCollapsed && (_height - widget.maxHeight).abs() < 0.01;
    final isTerminalTab = _activeTab == _TerminalPanelTab.terminal;
    final terminalTextStyle = GoogleFonts.getFont(
      'Google Sans Code',
      fontSize: 12,
      height: 1.35,
      color: Colors.white,
    );
    final terminalHeader = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: _collapsedHeight,
        child: Row(
          children: [
            const Icon(Icons.terminal, color: Colors.white70, size: 16),
            const SizedBox(width: 8),
            const Text(
              'Advanced activity',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
            if (_isCollapsed) ...[
              const SizedBox(width: 10),
              if (widget.isTaskRunning)
                const SizedBox(
                  key: Key('terminal-collapsed-running-indicator'),
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white70,
                  ),
                ),
              if (widget.isTaskRunning) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _latestOutput,
                  key: const Key('terminal-collapsed-latest-output'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
            if (!_isCollapsed) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Activity output',
                child: IconButton(
                  key: const Key('terminal-tab-button'),
                  onPressed: () => _setActiveTab(_TerminalPanelTab.terminal),
                  icon: Icon(
                    Icons.terminal,
                    color: isTerminalTab ? Colors.white : Colors.white54,
                    size: 18,
                  ),
                ),
              ),
              Tooltip(
                message: 'Background work queue',
                child: IconButton(
                  key: const Key('queue-tab-button'),
                  onPressed: () => _setActiveTab(_TerminalPanelTab.queue),
                  icon: Icon(
                    Icons.pending_actions,
                    color: isTerminalTab ? Colors.white54 : Colors.white,
                    size: 18,
                  ),
                ),
              ),
              const Spacer(),
            ],
            if (!_isCollapsed && isTerminalTab)
              Tooltip(
                message: _showDetails
                    ? 'Hide detailed lines'
                    : 'Show detailed lines',
                child: IconButton(
                  key: const Key('terminal-details-toggle'),
                  onPressed: _toggleDetails,
                  icon: Icon(
                    _showDetails ? Icons.visibility : Icons.visibility_off,
                    color: _showDetails ? Colors.white : Colors.white70,
                    size: 18,
                  ),
                ),
              ),
            if (isTerminalTab)
              IconButton(
                key: const Key('terminal-clear-button'),
                onPressed: _clearTerminalOutput,
                tooltip: 'Clear activity',
                icon: const Icon(
                  Icons.delete_sweep,
                  color: Colors.white70,
                  semanticLabel: 'Clear activity',
                ),
              ),
            if (isTerminalTab)
              IconButton(
                key: const Key('terminal-copy-button'),
                onPressed: _copyTerminalOutput,
                tooltip: 'Copy activity',
                icon: const Icon(
                  Icons.copy_all,
                  color: Colors.white70,
                  size: 16,
                  semanticLabel: 'Copy activity',
                ),
              ),
            IconButton(
              key: const Key('terminal-minimize-button'),
              onPressed: _toggleCollapsed,
              tooltip: _isCollapsed
                  ? 'Open advanced activity'
                  : 'Minimize advanced activity',
              icon: Icon(
                _isCollapsed ? Icons.expand_less : Icons.minimize,
                color: Colors.white70,
                size: 18,
              ),
            ),
            IconButton(
              key: const Key('terminal-maximize-button'),
              onPressed: _maximize,
              tooltip: isAtMaxHeight
                  ? 'Restore panel size'
                  : 'Maximize advanced activity',
              icon: Icon(
                isAtMaxHeight ? Icons.close_fullscreen : Icons.open_in_full,
                color: Colors.white70,
                size: 16,
              ),
            ),
          ],
        ),
      ),
    );

    return SizedBox(
      key: const Key('terminal-sheet'),
      width: double.infinity,
      height: _isCollapsed ? _collapsedHeight : _height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _aubergine,
          border: const Border(top: BorderSide(color: Color(0x33510040))),
        ),
        child: Column(
          children: [
            if (_isCollapsed) terminalHeader,
            if (!_isCollapsed)
              MouseRegion(
                key: const Key('terminal-resize-handle-cursor'),
                cursor: SystemMouseCursors.resizeUpDown,
                child: GestureDetector(
                  key: const Key('terminal-resize-handle'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: _onDragUpdate,
                  child: SizedBox(
                    height: 32,
                    child: Center(
                      child: Container(
                        width: 56,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white38,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (!_isCollapsed) terminalHeader,
            if (!_isCollapsed) const SizedBox(height: 6),
            if (!_isCollapsed)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: isTerminalTab
                        ? _TerminalPane(
                            controller: _terminalScrollController,
                            text: _visibleOutputText(),
                            textStyle: terminalTextStyle,
                          )
                        : _QueuePane(
                            controller: _queueScrollController,
                            metrics: _queueMetrics,
                            snapshots: _queueSnapshots,
                          ),
                  ),
                ),
              ),
            if (!_isCollapsed && isTerminalTab)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Latest activity: $_latestOutput',
                    key: const Key('terminal-latest-output'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
            if (!_isCollapsed && !isTerminalTab)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Background work: ${_queueMetrics.queueDepth} queued • '
                    '${_queueMetrics.running} running • '
                    '${_queueMetrics.stale} stalled',
                    key: const Key('terminal-queue-summary'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Pure formatters, at file scope so the private queue widgets below can
// use them without reaching back into the State. T-3.7.2.
// (State label/color now live in ui/system/operation_state_presentation.dart;
// the snapshot picker stays local per the D-45-pair-1 LEAVE, D-57 T-015.)
String _queueTimestampText(OperationQueueSnapshot entry) {
  final candidate = entry.completedAt ?? entry.startedAt ?? entry.submittedAt;
  final local = candidate.toLocal();
  return formatClockTime(local);
}

String _queueHostLabel(OperationQueueSnapshot entry) {
  final host = entry.hostKey?.trim();
  if (host == null || host.isEmpty) {
    return 'global';
  }
  return host;
}

class _TerminalPane extends StatelessWidget {
  const _TerminalPane({
    required this.controller,
    required this.text,
    required this.textStyle,
  });

  final ScrollController controller;
  final String text;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: SelectionArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Scrollbar(
              controller: controller,
              thumbVisibility: true,
              child: SingleChildScrollView(
                key: const Key('terminal-output-scroll-view'),
                controller: controller,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: constraints.maxWidth,
                    minHeight: constraints.maxHeight,
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SelectableText(
                      text,
                      key: const Key('terminal-selectable-output'),
                      style: textStyle,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _QueueMetricPill extends StatelessWidget {
  const _QueueMetricPill({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueEntry extends StatelessWidget {
  const _QueueEntry({required this.entry});

  final OperationQueueSnapshot entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.white70,
    );
    final mutedStyle = bodyStyle?.copyWith(color: Colors.white60);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.circle,
            size: 10,
            color: operationStateColor(
              entry.state,
              orange: Colors.orange,
              theme: theme,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${entry.operationType} • ${operationStateLabel(entry.state)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(entry.message, style: bodyStyle),
                const SizedBox(height: 2),
                Text(
                  'Host: ${_queueHostLabel(entry)} • ${_queueTimestampText(entry)}',
                  style: mutedStyle,
                ),
                if (entry.queuePosition != null)
                  Text(
                    'Queue position: ${entry.queuePosition}',
                    style: mutedStyle,
                  ),
                if (entry.isStale)
                  Text(
                    'Stale operation detected.',
                    style: mutedStyle?.copyWith(color: Colors.orange.shade300),
                  ),
                if (entry.blockingResources.isNotEmpty)
                  Text(
                    'Blocked resources: ${entry.blockingResources.join(', ')}',
                    style: mutedStyle,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueuePane extends StatelessWidget {
  const _QueuePane({
    required this.controller,
    required this.metrics,
    required this.snapshots,
  });

  final ScrollController controller;
  final OperationSchedulerMetricsSnapshot metrics;
  final List<OperationQueueSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showWarning = metrics.queueDepthWarning || metrics.queueWaitWarning;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: ListView(
          key: const Key('terminal-queue-list'),
          controller: controller,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _QueueMetricPill(
                  icon: Icons.pending_actions,
                  text: '${metrics.queueDepth} queued',
                  color: Colors.orange,
                ),
                _QueueMetricPill(
                  icon: Icons.play_circle_outline,
                  text: '${metrics.running} running',
                  color: Colors.green,
                ),
                _QueueMetricPill(
                  icon: Icons.warning_amber_rounded,
                  text: '${metrics.completedFailure} failed',
                  color: theme.colorScheme.error,
                ),
                _QueueMetricPill(
                  icon: Icons.hourglass_disabled_outlined,
                  text: '${metrics.stale} stale',
                  color: Colors.orange,
                ),
              ],
            ),
            if (showWarning) ...[
              const SizedBox(height: 8),
              Container(
                key: const Key('terminal-queue-warning'),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5),
                  ),
                ),
                child: const Text(
                  'Background work is taking longer than usual right now.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
            const SizedBox(height: 8),
            if (snapshots.isEmpty)
              const Text(
                'No background work to show yet.',
                key: Key('terminal-queue-empty'),
                style: TextStyle(color: Colors.white70, fontSize: 12),
              )
            else
              ...snapshots.map((entry) => _QueueEntry(entry: entry)),
          ],
        ),
      ),
    );
  }
}
