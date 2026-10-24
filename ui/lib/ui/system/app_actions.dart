import 'package:flutter/material.dart';

import 'app_theme.dart';

/// An action in the left rail, which collapses to an icon when the rail does.
///
/// One widget covering both shapes rather than two, so a rail action cannot
/// look or behave differently depending on how wide the window happens to be.
class AppRailActionButton extends StatelessWidget {
  /// Creates a rail action.
  const AppRailActionButton({
    super.key,
    required this.extended,
    required this.icon,
    required this.label,
    this.onPressed,
    this.tooltip,
    this.selected = false,
  });

  /// Whether the rail is wide. Collapsed renders icon-only, extended renders
  /// an outlined button with the label beside the icon.
  final bool extended;

  /// The icon, shown in both shapes.
  final IconData icon;

  /// The action in plain English, shown when extended and used as the
  /// accessible name when there is no [tooltip].
  final String label;

  /// What the action does. Null disables the button.
  final VoidCallback? onPressed;

  /// Overrides [label] for the tooltip and the accessible name, for a rail
  /// action whose collapsed meaning needs more words than fit.
  final String? tooltip;

  /// Whether this action is the current one, which tints its background.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    final foregroundColor = appSidebarForegroundColor(Theme.of(context));
    if (!extended) {
      return IconButton(
        tooltip: tooltip ?? label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: foregroundColor,
          backgroundColor: selected
              ? foregroundColor.withValues(alpha: 0.12)
              : Colors.transparent,
          minimumSize: const Size(44, 44),
          maximumSize: const Size(44, 44),
          visualDensity: VisualDensity.standard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tokens.radiusMd),
          ),
        ),
        // The label a screen reader reads. A tooltip is not one: Flutter
        // sets it as `SemanticsProperties.tooltip`, which assistive tech
        // may or may not announce. T-3.7.5.
        icon: Icon(
          icon,
          color: foregroundColor,
          semanticLabel: tooltip ?? label,
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          alignment: Alignment.centerLeft,
          foregroundColor: foregroundColor,
          side: BorderSide(
            color: foregroundColor.withValues(alpha: selected ? 0.24 : 0.14),
          ),
          backgroundColor: foregroundColor.withValues(
            alpha: selected ? 0.12 : 0.02,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spaceSm,
            vertical: tokens.spaceSm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(tokens.radiusMd),
          ),
        ),
        icon: Icon(icon, color: foregroundColor, size: 18),
        label: Text(label, style: TextStyle(color: foregroundColor)),
      ),
    );
  }
}
