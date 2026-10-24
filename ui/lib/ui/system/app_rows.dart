import 'package:flutter/material.dart';

/// One labeled value in a single row: a fixed-width label, a gap, a value.
///
/// The single owner of the workspace-kit labeled-value row (D-39). The
/// deployment tab, workers tab, database surfaces, and server onboarding
/// each carried their own spelling, differing only in label width, text
/// styles, alignment, value clamping, and trailing actions -- so those
/// travel with the caller as parameters instead of forking the row.
///
/// Defaults reproduce the common set: a 120-wide semibold label in the
/// variant surface color, an 8-gap, and a medium-body value.
class AppLabeledValueRow extends StatelessWidget {
  /// Creates one labeled-value row.
  const AppLabeledValueRow({
    super.key,
    required this.label,
    required this.value,
    this.width = 120,
    this.labelStyle,
    this.valueStyle,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.valueSelectable = false,
    this.valueMaxLines,
    this.valueOverflow,
    this.gap = 8,
    this.trailing,
  });

  /// The label text, shown in the fixed-width cell.
  final String label;

  /// The value text, shown expanded beside the label.
  final String value;

  /// The label cell width. Per-site widths (96/110/120/170) are preserved
  /// here rather than unified: each surface aligned its own column.
  final double width;

  /// The label style, or the semibold variant-body default when null.
  final TextStyle? labelStyle;

  /// The value style, or the medium-body default when null.
  final TextStyle? valueStyle;

  /// The row alignment. Most rows top-align; centered rows (metric and
  /// onboarding shapes) pass [CrossAxisAlignment.center] explicitly.
  final CrossAxisAlignment crossAxisAlignment;

  /// Whether the value renders as selectable text.
  final bool valueSelectable;

  /// Value line clamp, when the row must not grow (the deployment URL row).
  final int? valueMaxLines;

  /// How a clamped value overflows.
  final TextOverflow? valueOverflow;

  /// The space between label cell and value. One site (the onboarding spec
  /// list) packs its rows gapless and passes 0; the rest share the 8-gap.
  final double gap;

  /// An optional action after the value (the deployment URL row's opener).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedLabelStyle =
        labelStyle ??
        theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
    // A null valueStyle means the Text default (medium body); the
    // selectable branch keeps its ambient default instead, reproducing the
    // onboarding shape's bare `SelectableText(value)` exactly.
    final resolvedValueStyle = valueStyle ?? theme.textTheme.bodyMedium;
    return Row(
      crossAxisAlignment: crossAxisAlignment,
      children: [
        SizedBox(
          width: width,
          child: Text(label, style: resolvedLabelStyle),
        ),
        SizedBox(width: gap),
        Expanded(
          child: valueSelectable
              ? SelectableText(value, style: valueStyle)
              : Text(
                  value,
                  style: resolvedValueStyle,
                  maxLines: valueMaxLines,
                  overflow: valueOverflow,
                ),
        ),
        ?trailing,
      ],
    );
  }
}
