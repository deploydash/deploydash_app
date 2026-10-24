import 'package:flutter/material.dart';

/// Publishes a stable native accessibility identifier for package-boundary
/// automation without changing the visible or spoken label.
class AppAccessibilityIdentifier extends StatelessWidget {
  /// Creates an always-on identifier that is identical in every build mode.
  const AppAccessibilityIdentifier({
    super.key,
    required this.identifier,
    required this.child,
  });

  /// The platform identifier used by native UI automation.
  final String identifier;

  /// The production control or status surface being identified.
  final Widget child;

  /// Keeps identifier publication in one owner so release and debug builds
  /// expose the same accessibility contract.
  @override
  Widget build(BuildContext context) {
    return Semantics(identifier: identifier, child: child);
  }
}

/// Returns the stable string carried by a Flutter key when it can safely be
/// mirrored into the native accessibility tree.
String? appAccessibilityIdentifierForKey(Key? key) {
  return key is ValueKey<String> ? key.value : null;
}

/// Mirrors a field key, or its owning widget key as fallback, while leaving
/// controls with non-string keys unchanged.
Widget appAccessibilityIdentifierForKeys({
  required Key? widgetKey,
  required Key? fieldKey,
  required Widget child,
}) {
  final identifier =
      appAccessibilityIdentifierForKey(fieldKey) ??
      appAccessibilityIdentifierForKey(widgetKey);
  if (identifier == null) {
    return child;
  }
  return AppAccessibilityIdentifier(identifier: identifier, child: child);
}
