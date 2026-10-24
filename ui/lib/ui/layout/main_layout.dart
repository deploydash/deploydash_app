import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/app_analytics_service.dart';

class MainLayout extends ConsumerStatefulWidget {
  final Widget title;
  final Widget child;

  const MainLayout({super.key, required this.title, required this.child});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout>
    with WindowListener, WidgetsBindingObserver {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
    _checkMaximized();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    super.dispose();
  }

  /// Ends the launch session and pushes queued analytics out when the
  /// window closes.
  ///
  /// Best-effort by design: the desktop backend also persists its queue, so
  /// events that miss this window upload on next launch instead of being
  /// lost. [endAnalyticsSessionOnClose] never throws, so closing can never
  /// hang or crash on analytics. Every detach forwards; the backends own
  /// ending exactly once.
  // coverage-gate: main_layout_detach
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      unawaited(endAnalyticsSessionOnClose());
    }
  }
  // end coverage-gate

  Future<void> _checkMaximized() async {
    final isMaximized = await windowManager.isMaximized();
    if (mounted) {
      setState(() {
        _isMaximized = isMaximized;
      });
    }
  }

  @override
  void onWindowMaximize() {
    setState(() {
      _isMaximized = true;
    });
  }

  @override
  void onWindowUnmaximize() {
    setState(() {
      _isMaximized = false;
    });
  }

  @override
  void onWindowRestore() {
    setState(() {
      _isMaximized = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderRadius = _isMaximized
        ? BorderRadius.zero
        : const BorderRadius.vertical(top: Radius.circular(12));

    return ClipRRect(
      borderRadius: borderRadius,
      child: Scaffold(
        backgroundColor: Theme.of(context).canvasColor,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: YaruWindowTitleBar(
            title: widget.title,
            border: BorderSide(
              color: Theme.of(context).dividerColor,
              width: 0.5,
            ),
          ),
        ),
        body: widget.child,
      ),
    );
  }
}
