import 'package:flutter/material.dart';

/// One full-width workspace card: margin, padding, rounded border or fill.
///
/// The single owner of the workspace-kit card container (D-46). The
/// deployment tab, database tab, sharing card, and SQLite card each carried
/// the same full-width Container with a rounded BoxDecoration, differing
/// only in margin, padding, radius, border, and fill -- so those travel
/// with the caller as parameters instead of forking the container.
///
/// Defaults reproduce the bordered history-entry set: an 8-gap below, 12
/// padding, an 8 radius. Border and fill are both absent by default; a
/// site passes exactly one of [borderColor] or [fillColor].
class AppCard extends StatelessWidget {
  /// Creates one workspace card.
  const AppCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.only(bottom: 8),
    this.padding = const EdgeInsets.all(12),
    this.radius = 8,
    this.borderColor,
    this.fillColor,
  });

  /// The card body.
  final Widget child;

  /// The space around the card. Bordered list cards keep the 8-gap below;
  /// standalone cards (connection details, output boxes) pass zero.
  final EdgeInsetsGeometry margin;

  /// The space inside the card. Most cards share all-12; the connection
  /// and access cards pass all-16.
  final EdgeInsetsGeometry padding;

  /// The corner radius. Per-site radii (8/10/12) are preserved here rather
  /// than unified: each surface sized its own corners.
  final double radius;

  /// The border color, or null for a borderless (filled or bare) card.
  final Color? borderColor;

  /// The fill color, or null for an unfilled (bordered or bare) card.
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: fillColor,
        borderRadius: BorderRadius.circular(radius),
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: child,
    );
  }
}
