import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The title block every section starts with.
///
/// Used by [AppSectionCard] and [AppWorkspaceSection] rather than built by
/// hand, so a heading, its subtitle and its trailing action are spaced the
/// same everywhere.
class AppSectionHeader extends StatelessWidget {
  /// Creates a section header.
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
  });

  /// The section's name, in sentence case. Truncated rather than wrapped, so
  /// a long name cannot push the section's content down the screen.
  final String title;

  /// One line saying what the section is for. Omitted when blank.
  final String? subtitle;

  /// An optional icon before the title.
  final IconData? icon;

  /// A control aligned to the right of the header -- a refresh, or a
  /// secondary action. The section's primary action belongs in
  /// [AppPrimaryActionPanel] instead.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    // Hoisted so the `!= null` checks promote them; a widget field cannot be
    // promoted, which is what would otherwise force a `!` on every read.
    final subtitle = this.subtitle?.trim();
    final trailing = this.trailing;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18),
          SizedBox(width: tokens.spaceXs),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                SizedBox(height: tokens.spaceXs / 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[SizedBox(width: tokens.spaceSm), trailing],
      ],
    );
  }
}

/// A section on a card surface: a bordered, padded panel with a header.
///
/// The default for a section that stands apart from what surrounds it. Use
/// [AppWorkspaceSection] instead when several sections stack down one page
/// and a card each would read as visual noise.
class AppSectionCard extends StatelessWidget {
  /// Creates a card section.
  const AppSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.headerAction,
    this.primaryActionPanel,
    this.footer,
    this.margin,
    this.padding,
    this.contentSpacing,
  });

  /// The section's name.
  final String title;

  /// One line saying what it is for.
  final String? subtitle;

  /// An optional icon before the title.
  final IconData? icon;

  /// The section's content.
  final Widget child;

  /// A control in the header, to the right of the title.
  final Widget? headerAction;

  /// The panel carrying this section's current state and primary action --
  /// see [AppPrimaryActionPanel]. Sits between the header and the content.
  final Widget? primaryActionPanel;

  /// Content below the body, such as a note or a link.
  final Widget? footer;

  /// Overrides the gap below the card. Defaults to one medium step.
  final EdgeInsetsGeometry? margin;

  /// Overrides the card's inner padding. Defaults to one large step.
  final EdgeInsetsGeometry? padding;

  /// Overrides the gap between the header and the content. Defaults wider
  /// when there is a subtitle, so the two do not crowd.
  final double? contentSpacing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    final primaryActionPanel = this.primaryActionPanel;
    final footer = this.footer;
    return Card(
      margin: margin ?? EdgeInsets.only(bottom: tokens.spaceMd),
      child: Padding(
        padding: padding ?? EdgeInsets.all(tokens.spaceLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSectionHeader(
              title: title,
              subtitle: subtitle,
              icon: icon,
              trailing: headerAction,
            ),
            if (primaryActionPanel != null) ...[
              SizedBox(height: tokens.spaceMd),
              primaryActionPanel,
            ],
            SizedBox(
              height:
                  contentSpacing ??
                  (subtitle == null ? tokens.spaceSm : tokens.spaceMd),
            ),
            child,
            if (footer != null) ...[SizedBox(height: tokens.spaceMd), footer],
          ],
        ),
      ),
    );
  }
}

/// A section on the page itself, separated by a rule rather than a card.
///
/// The flat counterpart to [AppSectionCard], for pages made of several
/// stacked sections where a card each would be heavier than the content
/// warrants.
class AppWorkspaceSection extends StatelessWidget {
  /// Creates a flat section.
  const AppWorkspaceSection({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.headerAction,
    this.primaryActionPanel,
    this.footer,
    this.padding,
    this.contentSpacing,
  });

  /// The section's name.
  final String title;

  /// One line saying what it is for.
  final String? subtitle;

  /// An optional icon before the title.
  final IconData? icon;

  /// The section's content, below the rule.
  final Widget child;

  /// A control in the header.
  final Widget? headerAction;

  /// The section's state-and-action panel, above the rule.
  final Widget? primaryActionPanel;

  /// Content below the body.
  final Widget? footer;

  /// Overrides the gap below the section. Defaults to one extra-large step,
  /// which is what keeps stacked sections readable without cards.
  final EdgeInsetsGeometry? padding;

  /// Overrides the gap between the header and the rule.
  final double? contentSpacing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    final primaryActionPanel = this.primaryActionPanel;
    final footer = this.footer;
    return Padding(
      padding: padding ?? EdgeInsets.only(bottom: tokens.spaceXl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionHeader(
            title: title,
            subtitle: subtitle,
            icon: icon,
            trailing: headerAction,
          ),
          if (primaryActionPanel != null) ...[
            SizedBox(height: tokens.spaceMd),
            primaryActionPanel,
          ],
          SizedBox(height: contentSpacing ?? tokens.spaceSm),
          Divider(height: 1, color: appBorderColor(Theme.of(context))),
          SizedBox(height: tokens.spaceSm),
          child,
          if (footer != null) ...[SizedBox(height: tokens.spaceMd), footer],
        ],
      ),
    );
  }
}

/// The panel that says where a section stands and offers its one main action.
///
/// The shared answer to "one primary action per section": it puts the current
/// state, the action, and any reason the action is unavailable in one place,
/// so a disabled button always comes with the sentence explaining it.
///
/// Stacks the state above the actions below
/// [AppWorkspaceBreakpoints.stackedActions], rather than letting them
/// squeeze.
class AppPrimaryActionPanel extends StatelessWidget {
  /// Creates a state-and-action panel.
  const AppPrimaryActionPanel({
    super.key,
    required this.currentState,
    required this.primaryAction,
    this.description,
    this.blockingReason,
    this.blockingReasonKey,
    this.secondaryActions = const <Widget>[],
    this.icon,
  });

  /// Where this section stands right now, in a few words.
  final String currentState;

  /// What that means, or what happens next. Omitted when blank.
  final String? description;

  /// Why the primary action cannot run, shown in the error colour with an
  /// icon. Blank or null means nothing is blocking it.
  final String? blockingReason;

  /// A key for that reason, so tests can assert on the specific message.
  final Key? blockingReasonKey;

  /// The section's one primary action, rendered last so it reads as the end
  /// of the row.
  final Widget primaryAction;

  /// Lower-emphasis actions, placed before the primary one.
  final List<Widget> secondaryActions;

  /// An optional icon beside the state.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    final description = this.description?.trim();
    final blockingReason = this.blockingReason?.trim();
    final stateColumn = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 20),
          SizedBox(width: tokens.spaceSm),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                currentState,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (description != null && description.isNotEmpty) ...[
                SizedBox(height: tokens.spaceXs / 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final actionWrap = Wrap(
      spacing: tokens.spaceSm,
      runSpacing: tokens.spaceXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [...secondaryActions, primaryAction],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.38,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.all(tokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth <
                    AppWorkspaceBreakpoints.stackedActions) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      stateColumn,
                      SizedBox(height: tokens.spaceSm),
                      actionWrap,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: stateColumn),
                    SizedBox(width: tokens.spaceMd),
                    actionWrap,
                  ],
                );
              },
            ),
            if (blockingReason != null && blockingReason.isNotEmpty) ...[
              SizedBox(height: tokens.spaceSm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.error,
                  ),
                  SizedBox(width: tokens.spaceXs),
                  Expanded(
                    child: Text(
                      blockingReason,
                      key: blockingReasonKey,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The review-then-act layout: a summary, the action, then the detail.
///
/// Progressive disclosure as a widget. The user sees what is about to happen
/// and the button to do it, with the technical detail below where it can be
/// read but does not have to be.
class AppReviewWorkflowSection extends StatelessWidget {
  /// Creates a review-and-act section.
  const AppReviewWorkflowSection({
    super.key,
    required this.summary,
    required this.primaryActionPanel,
    this.details = const <Widget>[],
  });

  /// What is about to happen, in the user's terms.
  final Widget summary;

  /// The state-and-action panel -- see [AppPrimaryActionPanel].
  final Widget primaryActionPanel;

  /// The technical detail, below the action rather than before it.
  final List<Widget> details;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        summary,
        SizedBox(height: tokens.spaceMd),
        primaryActionPanel,
        for (final detail in details) ...[
          SizedBox(height: tokens.spaceMd),
          detail,
        ],
      ],
    );
  }
}
