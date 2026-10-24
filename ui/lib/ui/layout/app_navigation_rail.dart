import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:yaru/yaru.dart';

import '../../providers/recent_projects_provider.dart';
import '../../services/local_search_index.dart';
import '../system/app_actions.dart';
import '../system/app_search.dart';
import '../system/app_theme.dart';

const _localBuildVersionLabel = 'development';
const _releaseVersion = String.fromEnvironment('DEPLOYDASH_RELEASE_VERSION');

enum AppNavigationSection { none, home, server, project, settings }

class AppNavigationRail extends StatelessWidget {
  final bool extended;
  final VoidCallback? onOpenHome;
  final VoidCallback? onOpenServerManagement;
  final VoidCallback? onOpenAppSettings;
  final VoidCallback? onOpenUpdates;
  final bool updateAvailable;
  final AppNavigationSection selectedSection;

  /// Recently visited projects, newest first.
  final List<RecentProjectGroup> recentProjectGroups;

  /// Opens a specific screen inside a project.
  final void Function(String projectId, String destinationId)?
  onOpenProjectScreen;

  /// The project currently open, used to highlight its screen row.
  final String? currentProjectId;

  /// The screen currently open inside [currentProjectId].
  final String? currentDestinationId;

  /// Name of the server the current workspace belongs to.
  final String? currentServerName;

  /// Whether the contextual current-server row should be shown.
  final bool showCurrentServer;

  final FocusNode? searchFocusNode;
  final List<LocalSearchResult> Function(String query)? searchResultsBuilder;
  final ValueChanged<LocalSearchResult>? onSearchResultSelected;

  const AppNavigationRail({
    super.key,
    required this.extended,
    this.recentProjectGroups = const <RecentProjectGroup>[],
    this.onOpenProjectScreen,
    this.currentProjectId,
    this.currentDestinationId,
    this.currentServerName,
    this.showCurrentServer = false,
    this.searchFocusNode,
    this.searchResultsBuilder,
    this.onSearchResultSelected,
    this.onOpenHome,
    this.onOpenServerManagement,
    this.onOpenAppSettings,
    this.onOpenUpdates,
    this.updateAvailable = false,
    this.selectedSection = AppNavigationSection.none,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mutedForegroundColor = appSidebarMutedForegroundColor(theme);
    return Container(
      color: appSidebarColor(theme),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _BrandHeader(extended: extended),
          const SizedBox(height: 12),
          _HomeButton(
            extended: extended,
            selected: selectedSection == AppNavigationSection.home,
            onPressed: onOpenHome,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: extended ? 12 : 0),
            child: _RailSearch(
              extended: extended,
              focusNode: searchFocusNode,
              resultsBuilder: searchResultsBuilder,
              onSelected: onSearchResultSelected,
            ),
          ),
          if (showCurrentServer) ...[
            const SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: extended ? 12 : 0),
              child: _CurrentServerRow(
                extended: extended,
                serverName: currentServerName,
                selected: selectedSection == AppNavigationSection.server,
                onPressed: onOpenServerManagement,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (extended)
            _SidebarSectionLabel(
              key: const Key('left-rail-recent-projects-heading'),
              label: 'Recent projects',
              color: mutedForegroundColor,
            ),
          Expanded(
            child: recentProjectGroups.isEmpty
                ? _RecentProjectsEmptyState(
                    extended: extended,
                    color: mutedForegroundColor,
                  )
                : Scrollbar(
                    child: ListView(
                      key: const Key('left-rail-recent-projects-list'),
                      padding: EdgeInsets.fromLTRB(
                        extended ? 12 : 0,
                        0,
                        extended ? 12 : 0,
                        12,
                      ),
                      children: [
                        for (final group in recentProjectGroups)
                          _RecentProjectGroupTile(
                            group: group,
                            extended: extended,
                            currentProjectId: currentProjectId,
                            currentDestinationId: currentDestinationId,
                            onOpenProjectScreen: onOpenProjectScreen,
                          ),
                      ],
                    ),
                  ),
          ),
          _VersionFooter(
            extended: extended,
            updateAvailable: updateAvailable,
            onPressed: onOpenUpdates,
          ),
          _SettingsButton(
            extended: extended,
            selected: selectedSection == AppNavigationSection.settings,
            onPressed: onOpenAppSettings,
          ),
        ],
      ),
    );
  }
}

String get deployDashVersionRailLabel {
  final version = _releaseVersion.trim();
  if (version.isEmpty) {
    return 'Deploy Dash $_localBuildVersionLabel';
  }
  return 'Deploy Dash v$version';
}

String get deployDashCollapsedVersionRailLabel {
  final version = _releaseVersion.trim();
  if (version.isEmpty) {
    return 'dev';
  }
  return 'v$version';
}

class _RailSearch extends StatefulWidget {
  const _RailSearch({
    required this.extended,
    required this.focusNode,
    required this.resultsBuilder,
    required this.onSelected,
  });

  final bool extended;
  final FocusNode? focusNode;
  final List<LocalSearchResult> Function(String query)? resultsBuilder;
  final ValueChanged<LocalSearchResult>? onSelected;

  @override
  State<_RailSearch> createState() => _RailSearchState();
}

class _RailSearchState extends State<_RailSearch> {
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode {
    final provided = widget.focusNode;
    if (provided != null) {
      return provided;
    }
    return _ownedFocusNode ??= FocusNode(debugLabel: 'app-search');
  }

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final resultsBuilder = widget.resultsBuilder;
    final onSelected = widget.onSelected;
    if (resultsBuilder == null || onSelected == null) {
      return const SizedBox.shrink();
    }
    return AppSearchOverlay(
      focusNode: _focusNode,
      collapsed: !widget.extended,
      resultsBuilder: resultsBuilder,
      onSelected: onSelected,
    );
  }
}

class _CurrentServerRow extends StatelessWidget {
  const _CurrentServerRow({
    required this.extended,
    required this.serverName,
    required this.selected,
    this.onPressed,
  });

  final bool extended;
  final String? serverName;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final name = serverName?.trim();
    final label = name == null || name.isEmpty ? 'Server' : name;
    return AppRailActionButton(
      key: const Key('left-rail-current-server'),
      extended: extended,
      icon: YaruIcons.server,
      label: label,
      tooltip: 'Manage $label',
      selected: selected,
      onPressed: onPressed,
    );
  }
}

class _RecentProjectsEmptyState extends StatelessWidget {
  const _RecentProjectsEmptyState({
    required this.extended,
    required this.color,
  });

  final bool extended;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (!extended) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Align(
        alignment: Alignment.topLeft,
        child: Column(
          key: const Key('left-rail-recent-empty'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No recent projects',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
            const SizedBox(height: 4),
            Text(
              'Open a project from Home to see it here.',
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentProjectGroupTile extends StatelessWidget {
  const _RecentProjectGroupTile({
    required this.group,
    required this.extended,
    required this.currentProjectId,
    required this.currentDestinationId,
    required this.onOpenProjectScreen,
  });

  final RecentProjectGroup group;
  final bool extended;
  final String? currentProjectId;
  final String? currentDestinationId;
  final void Function(String projectId, String destinationId)?
  onOpenProjectScreen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = appSidebarForegroundColor(theme);
    final muted = appSidebarMutedForegroundColor(theme);
    final isCurrentProject = currentProjectId == group.projectId;
    // Hoisted so the `== null` checks promote them inside the callbacks;
    // neither a widget field nor a public final field is ever promoted.
    final onOpenProjectScreen = this.onOpenProjectScreen;
    final serverName = group.serverName;

    if (!extended) {
      final firstScreen = group.screens.first;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Semantics(
          selected: isCurrentProject,
          child: IconButton(
            key: Key('left-rail-recent-project-${group.projectId}'),
            tooltip: group.showServerName && serverName != null
                ? '${group.projectName} on $serverName'
                : group.projectName,
            onPressed: onOpenProjectScreen == null
                ? null
                : () => onOpenProjectScreen(
                    group.projectId,
                    firstScreen.destinationId,
                  ),
            style: IconButton.styleFrom(
              backgroundColor: isCurrentProject
                  ? foreground.withValues(alpha: 0.12)
                  : Colors.transparent,
            ),
            icon: Icon(
              YaruIcons.folder,
              color: isCurrentProject ? foreground : muted,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            key: Key('left-rail-recent-project-${group.projectId}'),
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            child: Row(
              children: [
                Icon(YaruIcons.folder, size: 16, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        group.projectName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (group.showServerName && serverName != null)
                        Text(
                          serverName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          for (final screen in group.screens)
            _RecentScreenRow(
              projectId: group.projectId,
              screen: screen,
              selected:
                  isCurrentProject &&
                  currentDestinationId == screen.destinationId,
              onPressed: onOpenProjectScreen == null
                  ? null
                  : () => onOpenProjectScreen(
                      group.projectId,
                      screen.destinationId,
                    ),
            ),
        ],
      ),
    );
  }
}

class _RecentScreenRow extends StatelessWidget {
  const _RecentScreenRow({
    required this.projectId,
    required this.screen,
    required this.selected,
    required this.onPressed,
  });

  final String projectId;
  final RecentProjectScreen screen;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = appSidebarForegroundColor(theme);
    final muted = appSidebarMutedForegroundColor(theme);
    return Semantics(
      selected: selected,
      child: Material(
        color: selected
            ? foreground.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: Key(
            'left-rail-recent-screen-$projectId-${screen.destinationId}',
          ),
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 10, 8),
            child: Text(
              screen.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected ? foreground : muted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({
    required this.extended,
    required this.selected,
    this.onPressed,
  });

  final bool extended;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (extended) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: AppRailActionButton(
          key: const Key('left-rail-home-button'),
          extended: true,
          icon: YaruIcons.home,
          label: 'Home',
          selected: selected,
          onPressed: onPressed,
        ),
      );
    }

    return AppRailActionButton(
      key: const Key('left-rail-home-button'),
      extended: false,
      icon: YaruIcons.home,
      label: 'Home',
      tooltip: 'Home',
      selected: selected,
      onPressed: onPressed,
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final bool extended;
  const _BrandHeader({required this.extended});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF111111),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: SvgPicture.asset(
              'assets/icons/app_icon.svg',
              width: 32,
              height: 32,
              fit: BoxFit.contain,
            ),
          ),
          if (extended) ...[
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Deploy Dash',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: appSidebarForegroundColor(Theme.of(context)),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _VersionFooter extends StatelessWidget {
  const _VersionFooter({
    required this.extended,
    required this.updateAvailable,
    this.onPressed,
  });

  final bool extended;
  final bool updateAvailable;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: appSidebarMutedForegroundColor(theme),
    );

    if (extended) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: InkWell(
          key: const Key('left-rail-version-label'),
          borderRadius: BorderRadius.circular(6),
          onTap: updateAvailable ? onPressed : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    deployDashVersionRailLabel,
                    textAlign: TextAlign.center,
                    style: style,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (updateAvailable) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.system_update_alt_outlined,
                    key: const Key('left-rail-update-badge'),
                    size: 15,
                    color: theme.colorScheme.tertiary,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Tooltip(
      message: updateAvailable
          ? '$deployDashVersionRailLabel. Update available.'
          : deployDashVersionRailLabel,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: InkWell(
          key: const Key('left-rail-version-label'),
          borderRadius: BorderRadius.circular(6),
          onTap: updateAvailable ? onPressed : null,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  deployDashCollapsedVersionRailLabel,
                  textAlign: TextAlign.center,
                  style: style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (updateAvailable)
                Positioned(
                  right: -5,
                  top: -3,
                  child: Icon(
                    Icons.circle,
                    key: const Key('left-rail-update-badge'),
                    size: 8,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton({
    required this.extended,
    required this.selected,
    this.onPressed,
  });

  final bool extended;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (extended) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: AppRailActionButton(
          key: const Key('left-rail-app-settings-button'),
          extended: true,
          icon: YaruIcons.settings,
          label: 'Settings',
          selected: selected,
          onPressed: onPressed,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AppRailActionButton(
        key: const Key('left-rail-app-settings-button'),
        extended: false,
        icon: YaruIcons.settings,
        label: 'Settings',
        tooltip: 'Settings',
        selected: selected,
        onPressed: onPressed,
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel({
    super.key,
    required this.label,
    required this.color,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
