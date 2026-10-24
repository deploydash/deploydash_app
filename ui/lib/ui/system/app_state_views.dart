import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The whole-section loading state: a spinner and a line saying what is being
/// loaded.
///
/// The shared answer to "this section has nothing to show yet". Deliberately
/// not a skeleton or placeholder values -- fake numbers on a screen about
/// someone's live server read as real ones.
class AppLoadingStateView extends StatelessWidget {
  /// Creates a loading state labelled with what is loading.
  const AppLoadingStateView({super.key, required this.label});

  /// What is being loaded, in plain English.
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.8),
          ),
          SizedBox(height: tokens.spaceSm),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}

/// The shared empty state: an icon, a title, an explanation, and usually the
/// action that fills it.
///
/// Empty is a moment to tell a novice what this screen is for and what to do
/// next, which is why [message] is required and [action] is expected on any
/// screen the user can act on.
class AppEmptyStateView extends StatelessWidget {
  /// Creates an empty state.
  const AppEmptyStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  /// A small icon suggesting what would be here.
  final IconData icon;

  /// What is empty, in sentence case.
  final String title;

  /// Why it is empty and what to do about it.
  final String message;

  /// The action that fills it. Omitted only where the user cannot act -- a
  /// feature that is not available yet, for instance.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    // Hoisted so the `!= null` check promotes it; a widget field is never
    // promoted.
    final action = this.action;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        SizedBox(height: tokens.spaceSm),
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        SizedBox(height: tokens.spaceXs / 2),
        Text(message, style: Theme.of(context).textTheme.bodySmall),
        if (action != null) ...[SizedBox(height: tokens.spaceSm), action],
      ],
    );
  }
}
