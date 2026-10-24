part of '../../project_workspace.dart';

class _EmailTabView extends StatelessWidget {
  const _EmailTabView();

  @override
  Widget build(BuildContext context) {
    return const _UnavailablePlaceholder(
      key: Key('email-unavailable-state'),
      icon: YaruIcons.mail,
      title: 'Email management is not available yet',
      message:
          'This area is not included in this release. Deploy Dash will not '
          'show sample mailboxes or actions.',
    );
  }
}

class _DomainTabView extends StatelessWidget {
  const _DomainTabView();

  @override
  Widget build(BuildContext context) {
    return const _UnavailablePlaceholder(
      key: Key('domain-unavailable-state'),
      icon: YaruIcons.globe,
      title: 'Domain management is not available yet',
      message:
          'This area is not included in this release. Deploy Dash will not '
          'show sample DNS records or actions.',
    );
  }
}

/// One "not in this release" placeholder.
///
/// Why one owner: the email and domain tabs carried the same empty-state
/// construction with different key, icon, title, and message. The views
/// stay as thin delegates so each tab keeps its content and its extension
/// point for when its feature lands.
class _UnavailablePlaceholder extends StatelessWidget {
  const _UnavailablePlaceholder({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    // The key stays on this placeholder rather than forwarding: forwarding
    // would match key lookups twice (here and on the empty-state view).
    return AppEmptyStateView(icon: icon, title: title, message: message);
  }
}

/// The same-library labeled-value row, delegating to [AppLabeledValueRow].
///
/// Why an alias instead of converting every call site: 10+ sites across the
/// workspace use this name with defaults. The alias carries the params the
/// same-library sites need; cross-library-only params (selectable value,
/// gapless packing) stay on the public owner for its direct callers.
class _LabeledValueRow extends StatelessWidget {
  const _LabeledValueRow({
    required this.label,
    required this.value,
    this.width = 120,
    this.labelStyle,
    this.valueStyle,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.valueMaxLines,
    this.valueOverflow,
    this.trailing,
  });

  final String label;
  final String value;
  final double width;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;
  final CrossAxisAlignment crossAxisAlignment;
  final int? valueMaxLines;
  final TextOverflow? valueOverflow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return AppLabeledValueRow(
      label: label,
      value: value,
      width: width,
      labelStyle: labelStyle,
      valueStyle: valueStyle,
      crossAxisAlignment: crossAxisAlignment,
      valueMaxLines: valueMaxLines,
      valueOverflow: valueOverflow,
      trailing: trailing,
    );
  }
}
