import 'package:flutter/material.dart';

/// The quiet bottom-left restore entry.
///
/// One widget for both surfaces that offer it -- the unlock screen's
/// overlay and the onboarding intro -- so the automation key, tooltip,
/// and icon cannot drift between them.
class RestoreLaunchButton extends StatelessWidget {
  /// Creates the restore entry.
  const RestoreLaunchButton({super.key, required this.onPressed});

  /// What the entry does. Never null: the entry hides instead of
  /// disabling when restore is unavailable.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      key: const Key('database-restore-launch-button'),
      tooltip: 'Restore a downloaded backup',
      onPressed: onPressed,
      icon: const Icon(Icons.restore),
    );
  }
}
