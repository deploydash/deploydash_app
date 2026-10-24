import 'package:flutter/material.dart';

import 'app_context_navigation.dart';
import 'app_sections.dart';
import 'app_theme.dart';
import 'container_runtime_status.dart';

/// How much attention a status badge should draw.
///
/// Five levels rather than a colour, so the mapping from meaning to colour is
/// made once here and cannot drift between screens.
enum AppStatusTone {
  /// Nothing to report -- unknown, or not set up.
  neutral,

  /// Something is happening, and will settle on its own.
  info,

  /// Working as intended.
  positive,

  /// Not working, but recoverable by an ordinary action.
  warning,

  /// Failing, and needing the user to look.
  negative,
}

/// The tone a container's effective status should be shown in.
///
/// Keeps the mapping in one place, so a stopped container reads as a warning
/// and a missing one as neutral wherever it is drawn.
AppStatusTone appContainerRuntimeStatusTone(
  ContainerRuntimeEffectiveStatus status,
) {
  return switch (status) {
    ContainerRuntimeEffectiveStatus.ready => AppStatusTone.positive,
    ContainerRuntimeEffectiveStatus.starting ||
    ContainerRuntimeEffectiveStatus.provisioning => AppStatusTone.info,
    ContainerRuntimeEffectiveStatus.restarting ||
    ContainerRuntimeEffectiveStatus.stopped => AppStatusTone.warning,
    ContainerRuntimeEffectiveStatus.unhealthy => AppStatusTone.negative,
    ContainerRuntimeEffectiveStatus.missing ||
    ContainerRuntimeEffectiveStatus.notConfigured ||
    ContainerRuntimeEffectiveStatus.unknown => AppStatusTone.neutral,
  };
}

/// The shared status pill.
///
/// Colour comes from [AppStatusTone] and the theme, never from a literal, so
/// badges stay consistent and follow the user's scheme.
class AppStatusBadge extends StatelessWidget {
  /// Creates a status badge.
  const AppStatusBadge({
    super.key,
    required this.label,
    this.tone = AppStatusTone.neutral,
    this.icon,
    this.leading,
  });

  /// The status in a word or two, sentence case.
  final String label;

  /// How much attention it should draw.
  final AppStatusTone tone;

  /// An optional icon before the label.
  final IconData? icon;

  /// A widget before the label, overriding [icon] -- a small spinner while
  /// something is in progress, for instance.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    final colors = switch (tone) {
      AppStatusTone.neutral => (
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurfaceVariant,
      ),
      AppStatusTone.info => (
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      AppStatusTone.positive => (
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      AppStatusTone.warning => (
        theme.colorScheme.errorContainer.withValues(alpha: 0.55),
        theme.colorScheme.onErrorContainer,
      ),
      AppStatusTone.negative => (
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };
    final leading = this.leading;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.$1,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spaceXs,
          vertical: tokens.spaceXs / 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              leading,
              SizedBox(width: tokens.spaceXs / 2),
            ] else if (icon != null) ...[
              Icon(icon, size: 14, color: colors.$2),
              SizedBox(width: tokens.spaceXs / 2),
            ],
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: colors.$2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame every workspace is built in: contextual navigation beside or
/// above a width-limited content column.
///
/// Chooses the layout from the available width -- a side list above
/// [AppWorkspaceBreakpoints.contextualNavigation], a horizontal strip below --
/// so project, server and settings workspaces all reflow at the same point.
class AppWorkspaceScaffold extends StatelessWidget {
  /// Creates a workspace frame.
  const AppWorkspaceScaffold({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.navigationKeyNamespace,
    required this.child,
    this.banner,
    this.maxContentWidth = AppWorkspaceBreakpoints.maxContentWidth,
    this.fullWidth = false,
    this.contentPadding = const EdgeInsets.symmetric(horizontal: 16),
  });

  /// The workspace's destinations, in display order.
  final List<AppContextNavigationItem> destinations;

  /// Which destination is current.
  final int selectedIndex;

  /// Called with the destination the user chose.
  final ValueChanged<int> onSelected;

  /// Prefix for the navigation's widget keys -- see
  /// [AppContextNavigation.keyNamespace].
  final String navigationKeyNamespace;

  /// The current destination's content.
  final Widget child;

  /// A full-width strip above everything, for something that concerns the
  /// whole workspace rather than one destination.
  final Widget? banner;

  /// The widest the content column grows.
  final double maxContentWidth;

  /// Whether to ignore [maxContentWidth]. For content that genuinely needs the
  /// window -- a terminal, a wide table -- and nothing else.
  final bool fullWidth;

  /// Padding around the content column.
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?banner,
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final vertical =
                  constraints.maxWidth >=
                  AppWorkspaceBreakpoints.contextualNavigation;
              final navigation = AppContextNavigation(
                items: destinations,
                selectedIndex: selectedIndex,
                onSelected: onSelected,
                axis: vertical ? Axis.vertical : Axis.horizontal,
                keyNamespace: navigationKeyNamespace,
              );
              final content = _AppWorkspaceContentFrame(
                maxContentWidth: maxContentWidth,
                fullWidth: fullWidth,
                padding: contentPadding,
                child: child,
              );
              if (!vertical) {
                return Column(
                  children: [
                    navigation,
                    const Divider(height: 1),
                    Expanded(child: content),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  navigation,
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AppWorkspaceContentFrame extends StatelessWidget {
  const _AppWorkspaceContentFrame({
    required this.maxContentWidth,
    required this.fullWidth,
    required this.padding,
    required this.child,
  });

  final double maxContentWidth;
  final bool fullWidth;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = fullWidth
              ? constraints.maxWidth
              : constraints.maxWidth.clamp(0, maxContentWidth).toDouble();
          return Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              height: constraints.maxHeight,
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// A workspace's title block, with its actions.
///
/// Stacks the actions below the heading under
/// [AppWorkspaceBreakpoints.stackedActions] rather than letting them squeeze
/// the title.
class AppWorkspaceHeader extends StatelessWidget {
  /// Creates a workspace header.
  const AppWorkspaceHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.status,
    this.actions = const <Widget>[],
  });

  /// The screen's name, in sentence case.
  final String title;

  /// One line saying what the screen is for.
  final String? subtitle;

  /// A status badge under the heading, when the screen has an overall state.
  final Widget? status;

  /// The screen's actions, with at most one filled primary among them.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    // Hoisted so the `!= null` checks promote them; a widget field cannot be.
    final subtitle = this.subtitle?.trim();
    final status = this.status;
    return Padding(
      padding: EdgeInsets.only(top: tokens.spaceSm, bottom: tokens.spaceLg),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heading = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                SizedBox(height: tokens.spaceXs / 2),
                Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
              ],
              if (status != null) ...[SizedBox(height: tokens.spaceXs), status],
            ],
          );
          final actionWrap = Wrap(
            spacing: tokens.spaceSm,
            runSpacing: tokens.spaceXs,
            children: actions,
          );
          if (constraints.maxWidth < AppWorkspaceBreakpoints.stackedActions ||
              actions.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                if (actions.isNotEmpty) ...[
                  SizedBox(height: tokens.spaceMd),
                  actionWrap,
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: heading),
              SizedBox(width: tokens.spaceMd),
              actionWrap,
            ],
          );
        },
      ),
    );
  }
}

/// A row of filters and controls above a list, wrapping when it runs out of
/// width.
class AppWorkspaceToolbar extends StatelessWidget {
  /// Creates a toolbar.
  const AppWorkspaceToolbar({
    super.key,
    required this.children,
    this.trailing = const <Widget>[],
  });

  /// The main controls -- filters, search, a segmented control.
  final List<Widget> children;

  /// Controls placed after them, such as a refresh. A separate list so the
  /// two groups keep their order when the row wraps.
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spaceSm),
      child: Wrap(
        spacing: tokens.spaceSm,
        runSpacing: tokens.spaceXs,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [...children, ...trailing],
      ),
    );
  }
}

/// One item in a list of things: a server, a database, a worker.
///
/// The shared row shape, so lists across the app share their spacing,
/// truncation and selected state. Announces itself as selected and as a
/// button to assistive tech when it is tappable.
class AppResourceRow extends StatelessWidget {
  /// Creates a resource row.
  const AppResourceRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.status,
    this.actions = const <Widget>[],
    this.selected = false,
    this.onTap,
  });

  /// The item's name. Truncated to one line, so a long name cannot push the
  /// row's status and actions off the edge.
  final String title;

  /// A second line of detail, up to two lines before truncating.
  final String? subtitle;

  /// A widget before the title -- an icon, or a small avatar.
  final Widget? leading;

  /// A status badge after the text.
  final Widget? status;

  /// Row-level quick actions. Icon-only by default here: the item is already
  /// obvious, and each carries its verb in a tooltip.
  final List<Widget> actions;

  /// Whether this row is the current selection.
  final bool selected;

  /// What opening the row does. Null makes it a plain row rather than a
  /// button.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    final leading = this.leading;
    final subtitle = this.subtitle?.trim();
    final status = this.status;
    return Semantics(
      selected: selected,
      button: onTap != null,
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(tokens.radiusSm),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(tokens.radiusSm),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spaceSm,
              vertical: tokens.spaceSm,
            ),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading,
                  SizedBox(width: tokens.spaceSm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        SizedBox(height: tokens.spaceXs / 2),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                if (status != null) ...[
                  SizedBox(width: tokens.spaceSm),
                  status,
                ],
                if (actions.isNotEmpty) ...[
                  SizedBox(width: tokens.spaceSm),
                  Wrap(spacing: tokens.spaceXs / 2, children: actions),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The detail half of a master-detail layout.
///
/// A thin naming of [AppWorkspaceSection], so a detail pane reads as one at
/// the call site and gains its own shape later without touching callers.
class AppDetailPane extends StatelessWidget {
  /// Creates a detail pane.
  const AppDetailPane({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.actions,
  });

  /// What is being shown, in sentence case.
  final String title;

  /// One line of context under the title.
  final String? subtitle;

  /// The detail itself.
  final Widget child;

  /// A control in the header.
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    return AppWorkspaceSection(
      title: title,
      subtitle: subtitle,
      headerAction: actions,
      child: child,
    );
  }
}

/// A collapsible section, for content the user should be able to reach but
/// does not need on the primary path.
///
/// The general form of progressive disclosure; use [AppTechnicalDetails] for
/// the specific case of raw engine output.
class AppDisclosureSection extends StatelessWidget {
  /// Creates a collapsible section.
  const AppDisclosureSection({
    super.key,
    required this.child,
    required this.title,
    this.subtitle,
    this.icon,
    this.initiallyExpanded = false,
  });

  /// What is behind the reveal, in sentence case.
  final String title;

  /// A line of context, shown while collapsed.
  final String? subtitle;

  /// An optional icon before the title.
  final IconData? icon;

  /// The content, revealed when expanded.
  final Widget child;

  /// Whether it starts open. False by default -- the point is to keep detail
  /// off the primary path until asked for.
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return Material(
      color: Colors.transparent,
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.only(
          left: context.appThemeTokens.spaceMd,
          bottom: context.appThemeTokens.spaceSm,
        ),
        initiallyExpanded: initiallyExpanded,
        leading: icon == null ? null : Icon(icon, size: 18),
        title: Text(title, style: Theme.of(context).textTheme.titleSmall),
        subtitle: subtitle == null ? null : Text(subtitle),
        children: [Align(alignment: Alignment.centerLeft, child: child)],
      ),
    );
  }
}

/// The reveal that raw engine output, IDs and fingerprints belong behind.
///
/// Named rather than a bare [AppDisclosureSection] so the design rule -- calm
/// primary path, technical detail second -- has a widget that states it, and
/// so every such reveal is labelled the same way.
class AppTechnicalDetails extends StatelessWidget {
  /// Creates a technical-details reveal.
  const AppTechnicalDetails({
    super.key,
    required this.child,
    this.title = 'Technical details',
    this.subtitle,
    this.initiallyExpanded = false,
  });

  /// The reveal's label. `Technical details` by default, and rarely worth
  /// changing -- the consistency is the point.
  final String title;

  /// A line of context shown while collapsed.
  final String? subtitle;

  /// The raw detail.
  final Widget child;

  /// Whether it starts open.
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return AppDisclosureSection(
      title: title,
      subtitle: subtitle,
      initiallyExpanded: initiallyExpanded,
      child: child,
    );
  }
}

/// A list beside a detail pane, stacking into one column when narrow.
///
/// Falls back to a column below [AppWorkspaceBreakpoints.twoColumn], master
/// first, so the user still meets the list before the detail.
class AppMasterDetail extends StatelessWidget {
  /// Creates a master-detail layout.
  const AppMasterDetail({
    super.key,
    required this.master,
    required this.detail,
    this.masterFlex = 2,
    this.detailFlex = 3,
    this.spacing,
  });

  /// The list of things to choose from.
  final Widget master;

  /// The chosen thing.
  final Widget detail;

  /// The list's share of the width.
  final int masterFlex;

  /// The detail's share. Wider than the master by default: the list is names,
  /// the detail is content.
  final int detailFlex;

  /// The gap between them, or one large step by default.
  final double? spacing;

  @override
  Widget build(BuildContext context) {
    final gap = spacing ?? context.appThemeTokens.spaceLg;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppWorkspaceBreakpoints.twoColumn) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              master,
              SizedBox(height: gap),
              detail,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: masterFlex, child: master),
            SizedBox(width: gap),
            Expanded(flex: detailFlex, child: detail),
          ],
        );
      },
    );
  }
}

/// A centred, single-purpose screen with a fixed footer.
///
/// For flows that take over the window and have one job -- unlocking the
/// database, onboarding a server. Deliberately narrow and centred, with the
/// body scrolling between two rules so the actions stay reachable however long
/// the content grows.
class AppFocusedFlowScaffold extends StatelessWidget {
  /// Creates a focused-flow screen.
  const AppFocusedFlowScaffold({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
    this.subtitle,
    this.icon,
    this.productName,
    this.maxWidth = 640,
    this.padding = const EdgeInsets.all(24),
  });

  /// What this step is, in sentence case.
  final String title;

  /// What the user is being asked to do, or what happens next.
  final String? subtitle;

  /// An optional icon beside the title.
  final IconData? icon;

  /// The product name, shown above everything. For the first screen a user
  /// meets, where the app has not yet named itself anywhere else.
  final String? productName;

  /// The step's content, which scrolls.
  final Widget child;

  /// The footer actions, pinned below the scroll so they stay reachable.
  final List<Widget> actions;

  /// The widest the flow grows. Narrow by design: a focused step is a column.
  final double maxWidth;

  /// Padding around the whole flow.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = context.appThemeTokens;
    final productName = this.productName?.trim();
    final subtitle = this.subtitle?.trim();
    return SafeArea(
      child: Padding(
        padding: padding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (productName != null && productName.isNotEmpty) ...[
                  Text(
                    productName,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: tokens.spaceLg),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 24, color: theme.colorScheme.primary),
                      SizedBox(width: tokens.spaceSm),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: theme.textTheme.headlineSmall),
                          if (subtitle != null && subtitle.isNotEmpty) ...[
                            SizedBox(height: tokens.spaceXs / 2),
                            Text(subtitle, style: theme.textTheme.bodyMedium),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: tokens.spaceLg),
                Divider(height: 1, color: appBorderColor(theme)),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(vertical: tokens.spaceLg),
                    child: child,
                  ),
                ),
                Divider(height: 1, color: appBorderColor(theme)),
                Padding(
                  padding: EdgeInsets.only(top: tokens.spaceMd),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: tokens.spaceSm,
                      runSpacing: tokens.spaceXs,
                      children: actions,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
