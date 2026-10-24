import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Sets the OS window title. Injectable so tests need no real window.
typedef AppWindowTitleSetter = Future<void> Function(String title);

AppWindowTitleSetter? _debugWindowTitleSetter;

/// Redirects the window title away from the real window manager. Null
/// restores it.
@visibleForTesting
void debugOverrideAppWindowTitleSetter(AppWindowTitleSetter? setter) {
  _debugWindowTitleSetter = setter;
}

/// Keeps the OS window title naming the screen its child shows.
///
/// A widget rather than a call at each navigation point, so the title follows
/// what is actually mounted -- a screen that is popped without anyone
/// remembering to reset the title cannot leave it stale.
///
/// Failures are swallowed: the title is cosmetic, and a window manager that
/// will not set it must not take a screen down with it.
class AppWindowTitle extends StatefulWidget {
  /// Titles the window after [screen] while [child] is shown.
  const AppWindowTitle({super.key, required this.screen, required this.child});

  /// The screen's name, rendered as `Deploy Dash - <screen>`.
  final String screen;

  /// The screen itself, built unchanged.
  final Widget child;

  @override
  State<AppWindowTitle> createState() => _AppWindowTitleState();
}

class _AppWindowTitleState extends State<AppWindowTitle> {
  @override
  void initState() {
    super.initState();
    _applyTitle();
  }

  @override
  void didUpdateWidget(covariant AppWindowTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.screen != widget.screen) {
      _applyTitle();
    }
  }

  void _applyTitle() {
    final expectedScreen = widget.screen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.screen != expectedScreen) {
        return;
      }
      final setter = _debugWindowTitleSetter ?? windowManager.setTitle;
      unawaited(
        setter('Deploy Dash - $expectedScreen').catchError((Object _) {}),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
